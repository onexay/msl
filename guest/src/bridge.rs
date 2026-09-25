// SPDX-License-Identifier: Apache-2.0
//! `/run/msl/init msl-bridge <target>`: relay stdin/stdout to a Unix socket or
//! a localhost TCP port inside the distro. The VS Code extension uses it as a
//! managed pipe (`msl -d X -e /run/msl/init msl-bridge unix:<path>`) until
//! msld has its own connect socket.
//!
//! Both directions half-close: stdin EOF shuts down the socket's write side,
//! and socket EOF closes stdout. It exits when both directions are done.

use std::fs::File;
use std::io::{Read, Write};
use std::net::{Shutdown, TcpStream};
use std::os::fd::FromRawFd;
use std::os::unix::net::UnixStream;

const USAGE: &str = "usage: msl-bridge unix:<path> | tcp:<port>";

#[derive(Debug, PartialEq)]
enum Target {
    Unix(String),
    Tcp(u16),
}

fn parse(arg: &str) -> Option<Target> {
    if let Some(p) = arg.strip_prefix("unix:") {
        return (!p.is_empty()).then(|| Target::Unix(p.to_string()));
    }
    arg.strip_prefix("tcp:")?.parse().ok().filter(|p| *p > 0).map(Target::Tcp)
}

/// A connected socket that can be read, written and half-closed.
trait Conn: Read + Write + Send + 'static {
    fn split(&self) -> std::io::Result<Box<dyn Conn>>;
    fn shutdown_write(&self);
}

impl Conn for UnixStream {
    fn split(&self) -> std::io::Result<Box<dyn Conn>> {
        Ok(Box::new(self.try_clone()?))
    }
    fn shutdown_write(&self) {
        let _ = self.shutdown(Shutdown::Write);
    }
}

impl Conn for TcpStream {
    fn split(&self) -> std::io::Result<Box<dyn Conn>> {
        Ok(Box::new(self.try_clone()?))
    }
    fn shutdown_write(&self) {
        let _ = self.shutdown(Shutdown::Write);
    }
}

fn connect(t: &Target) -> std::io::Result<Box<dyn Conn>> {
    Ok(match t {
        Target::Unix(p) => Box::new(UnixStream::connect(p)?),
        Target::Tcp(port) => {
            let s = TcpStream::connect(("127.0.0.1", *port)).or_else(|_| TcpStream::connect(("::1", *port)))?;
            let _ = s.set_nodelay(true);
            Box::new(s)
        }
    })
}

/// Copy until EOF or an error; unbuffered, so every chunk is written at once.
fn pump(from: &mut dyn Read, to: &mut dyn Write) {
    let mut buf = vec![0u8; 64 << 10];
    loop {
        match from.read(&mut buf) {
            Ok(0) => return,
            Ok(n) => {
                if to.write_all(&buf[..n]).is_err() {
                    return;
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => {}
            Err(_) => return,
        }
    }
}

/// Relay `input` -> `conn` and `conn` -> `output` until both directions end.
fn relay(conn: Box<dyn Conn>, mut input: impl Read + Send + 'static, output: impl Write) -> std::io::Result<()> {
    let mut up = conn.split()?;
    let t = std::thread::spawn(move || {
        pump(&mut input, &mut up);
        up.shutdown_write();
    });
    let mut down = conn;
    let mut output = output;
    pump(&mut down, &mut output);
    drop(output); // EOF for the reader of our stdout
    let _ = t.join();
    Ok(())
}

pub fn main(args: &[String]) -> ! {
    let Some(target) = args.first().and_then(|a| parse(a)).filter(|_| args.len() == 1) else {
        eprintln!("{USAGE}");
        std::process::exit(2);
    };
    let conn = match connect(&target) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("msl-bridge: {}: {e}", args[0]);
            std::process::exit(1);
        }
    };
    // Raw fds 0 and 1: std's stdout is line-buffered and its handles never close.
    let stdin = unsafe { File::from_raw_fd(0) };
    let stdout = unsafe { File::from_raw_fd(1) };
    let code = if relay(conn, stdin, stdout).is_ok() { 0 } else { 1 };
    std::process::exit(code);
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::net::UnixListener;

    #[test]
    fn parses_targets() {
        assert_eq!(parse("unix:/run/user/1000/vscode-x.sock"), Some(Target::Unix("/run/user/1000/vscode-x.sock".into())));
        assert_eq!(parse("tcp:8080"), Some(Target::Tcp(8080)));
        assert_eq!(parse("tcp:0"), None);
        assert_eq!(parse("tcp:70000"), None);
        assert_eq!(parse("unix:"), None);
        assert_eq!(parse("/tmp/x"), None);
    }

    /// Echo server; the client half-closes, and the reply still arrives in full.
    #[test]
    fn relays_both_ways_with_half_close() {
        let dir = std::env::temp_dir().join(format!("msl-bridge-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        let path = dir.join("s.sock");
        let _ = std::fs::remove_file(&path);
        let l = UnixListener::bind(&path).unwrap();
        let server = std::thread::spawn(move || {
            let (mut s, _) = l.accept().unwrap();
            let mut got = Vec::new();
            s.read_to_end(&mut got).unwrap(); // needs the bridge's shutdown(SHUT_WR)
            s.write_all(&got).unwrap();
        });
        let data: Vec<u8> = (0..3_000_000u32).map(|i| (i * 7 % 251) as u8).collect();
        let conn = connect(&Target::Unix(path.to_string_lossy().into())).unwrap();
        let (tx_r, tx_w) = std::io::pipe().unwrap();
        let writer = {
            let data = data.clone();
            std::thread::spawn(move || {
                let mut w = tx_w;
                w.write_all(&data).unwrap();
            })
        };
        let mut out = Vec::new();
        relay(conn, tx_r, &mut out).unwrap();
        writer.join().unwrap();
        server.join().unwrap();
        assert_eq!(out, data);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
