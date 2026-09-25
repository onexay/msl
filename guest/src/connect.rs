// SPDX-License-Identifier: Apache-2.0
//! vsock:1026: connections to a Unix socket inside a distro, for msld's
//! connect socket (VS Code managed pipes, #32).
//!
//! Request: [version u8 = 1][uid u32 BE][id len u16 BE][id][path len u16 BE][path].
//! Reply: [status u8] (0 = ok) and, on error, [len u16 BE][message]; after an
//! ok the connection is a flow-controlled bridge (framed.rs).
//!
//! Only `<home>/.vscode-server/msl/<name>.sock` of the requesting user is
//! allowed, so this can't become a proxy to docker.sock or systemd. The connect
//! itself runs on a throwaway thread that has joined the distro's mount
//! namespace and taken the user's uid/gids: symlinks resolve inside the distro
//! and the kernel checks permissions as that user.

use std::fs::File;
use std::io::{Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::net::UnixStream;

pub const CONNECT_PORT: u32 = 1026;
const VERSION: u8 = 1;

struct Request {
    uid: u32,
    id: String,
    path: String,
}

fn read_request(r: &mut impl Read) -> std::io::Result<Request> {
    let mut b1 = [0u8; 1];
    r.read_exact(&mut b1)?;
    if b1[0] != VERSION {
        return Err(std::io::Error::other("unsupported request version"));
    }
    let mut b4 = [0u8; 4];
    r.read_exact(&mut b4)?;
    let uid = u32::from_be_bytes(b4);
    let mut string = || -> std::io::Result<String> {
        let mut b2 = [0u8; 2];
        r.read_exact(&mut b2)?;
        let n = u16::from_be_bytes(b2) as usize;
        if n > 4096 {
            return Err(std::io::Error::other("field too long"));
        }
        let mut v = vec![0u8; n];
        r.read_exact(&mut v)?;
        String::from_utf8(v).map_err(|_| std::io::Error::other("not UTF-8"))
    };
    let id = string()?;
    let path = string()?;
    Ok(Request { uid, id, path })
}

/// The only sockets msld may reach: `<home>/.vscode-server/msl/<name>.sock`.
pub fn allowed(path: &str, home: &str) -> bool {
    let home = home.trim_end_matches('/');
    let Some(name) = path.strip_prefix(&format!("{home}/.vscode-server/msl/")) else { return false };
    !home.is_empty()
        && home.starts_with('/')
        && !home.split('/').any(|c| c == ".." || c == ".")
        && name.len() > ".sock".len()
        && name.ends_with(".sock")
        && !name.starts_with('.')
        && name.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
}

/// (name, primary gid, home) of `uid` from the distro's /etc/passwd.
fn passwd_entry(passwd: &str, uid: u32) -> Option<(String, u32, String)> {
    passwd.lines().find_map(|l| {
        let f: Vec<&str> = l.split(':').collect();
        (f.len() >= 7 && f[2].parse() == Ok(uid)).then(|| Some((f[0].to_string(), f[3].parse().ok()?, f[5].to_string())))?
    })
}

/// Supplementary groups of the user named `name` in the distro's /etc/group.
fn groups_of(group: &str, name: &str) -> Vec<u32> {
    group
        .lines()
        .filter_map(|l| {
            let f: Vec<&str> = l.split(':').collect();
            (f.len() >= 4 && f[3].split(',').any(|m| m == name)).then(|| f[2].parse().ok())?
        })
        .collect()
}

/// Connect to `path` as `uid` inside the mount namespace of `pid`, on a
/// thread that exits afterwards (its fs and credentials are its own).
fn connect_as(pid: i32, uid: u32, gid: u32, groups: Vec<u32>, path: String) -> std::io::Result<UnixStream> {
    let ns = File::open(format!("/proc/{pid}/ns/mnt"))?;
    std::thread::spawn(move || -> std::io::Result<UnixStream> {
        let err = std::io::Error::last_os_error;
        unsafe {
            // Own fs struct, so setns(CLONE_NEWNS) affects only this thread.
            if libc::unshare(libc::CLONE_FS) != 0 || libc::setns(ns.as_raw_fd(), libc::CLONE_NEWNS) != 0 {
                return Err(err());
            }
            // Raw syscalls: per-thread credentials (libc wrappers change every thread).
            if libc::syscall(libc::SYS_setgroups, groups.len(), groups.as_ptr()) != 0
                || libc::syscall(libc::SYS_setresgid, gid, gid, gid) != 0
                || libc::syscall(libc::SYS_setresuid, uid, uid, uid) != 0
            {
                return Err(err());
            }
        }
        UnixStream::connect(&path)
    })
    .join()
    .map_err(|_| std::io::Error::other("connect thread panicked"))?
}

fn open(req: &Request) -> Result<UnixStream, String> {
    let pid = crate::miniinit::distro_init_pid(&req.id).ok_or("the distro is not running")?;
    let root = format!("/proc/{pid}/root");
    let passwd = std::fs::read_to_string(format!("{root}/etc/passwd")).map_err(|e| format!("/etc/passwd: {e}"))?;
    let (name, gid, home) = passwd_entry(&passwd, req.uid).ok_or(format!("no user with uid {}", req.uid))?;
    if !allowed(&req.path, &home) {
        return Err(format!("{}: not allowed (only {home}/.vscode-server/msl/*.sock)", req.path));
    }
    let mut groups = groups_of(&std::fs::read_to_string(format!("{root}/etc/group")).unwrap_or_default(), &name);
    groups.push(gid);
    connect_as(pid, req.uid, gid, groups, req.path.clone()).map_err(|e| format!("{}: {e}", req.path))
}

fn handle(mut conn: File) {
    let req = match read_request(&mut conn) {
        Ok(r) => r,
        Err(e) => return reply_err(&mut conn, &e.to_string()),
    };
    let stream = match open(&req) {
        Ok(s) => s,
        Err(e) => {
            crate::sys::log(&format!("connect: {e}"));
            return reply_err(&mut conn, &e);
        }
    };
    if conn.write_all(&[0]).is_err() {
        return;
    }
    let (Ok(a), Ok(b)) = (stream.try_clone(), stream.try_clone()) else { return };
    let to_file = |s: UnixStream| File::from(OwnedFd::from(s));
    let _ = crate::framed::bridge(conn, Some(to_file(a)), Some(to_file(b)));
    drop(stream);
}

fn reply_err(conn: &mut File, msg: &str) {
    let m = &msg.as_bytes()[..msg.len().min(1024)];
    let mut out = vec![1u8];
    out.extend_from_slice(&(m.len() as u16).to_be_bytes());
    out.extend_from_slice(m);
    let _ = conn.write_all(&out);
}

pub fn spawn_listener() -> std::io::Result<()> {
    let listener = tokio_vsock::VsockListener::bind(tokio_vsock::VsockAddr::new(tokio_vsock::VMADDR_CID_ANY, CONNECT_PORT))?;
    tokio::spawn(async move {
        loop {
            let Ok((conn, _)) = listener.accept().await else { continue };
            let fd = unsafe { libc::dup(conn.as_raw_fd()) };
            drop(conn);
            if fd < 0 {
                continue;
            }
            crate::sys::set_blocking(fd);
            crate::sys::set_cloexec(fd, true);
            let conn = unsafe { File::from_raw_fd(fd) };
            std::thread::spawn(move || handle(conn));
        }
    });
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn allowlist() {
        let h = "/home/akshay";
        assert!(allowed("/home/akshay/.vscode-server/msl/7debcd0e.sock", h));
        assert!(allowed("/home/akshay/.vscode-server/msl/abc-1_2.sock", "/home/akshay/"));
        for bad in [
            "/var/run/docker.sock",
            "/run/systemd/private",
            "/home/akshay/.vscode-server/msl/../x.sock",
            "/home/akshay/.vscode-server/msl/sub/x.sock",
            "/home/akshay/.vscode-server/msl/.sock",
            "/home/akshay/.vscode-server/msl/.hidden.sock",
            "/home/akshay/.vscode-server/msl/x.socket",
            "/home/other/.vscode-server/msl/x.sock",
            "/home/akshay/.vscode-server/msl/x.sock/",
            "home/akshay/.vscode-server/msl/x.sock",
        ] {
            assert!(!allowed(bad, h), "{bad}");
        }
        assert!(!allowed("/.vscode-server/msl/x.sock", ""));
        assert!(!allowed("/a/../.vscode-server/msl/x.sock", "/a/.."));
    }

    #[test]
    fn passwd_and_groups() {
        let passwd = "root:x:0:0:root:/root:/bin/bash\nakshay:x:1000:1000:,,,:/home/akshay:/bin/bash\n";
        assert_eq!(passwd_entry(passwd, 1000), Some(("akshay".into(), 1000, "/home/akshay".into())));
        assert_eq!(passwd_entry(passwd, 1001), None);
        let group = "sudo:x:27:akshay\ndocker:x:999:bob,akshay\nadm:x:4:syslog\n";
        assert_eq!(groups_of(group, "akshay"), vec![27, 999]);
    }

    #[test]
    fn parses_request() {
        let mut b = vec![1u8];
        b.extend_from_slice(&1000u32.to_be_bytes());
        for s in ["6dcf52f2-09a6", "/home/a/.vscode-server/msl/x.sock"] {
            b.extend_from_slice(&(s.len() as u16).to_be_bytes());
            b.extend_from_slice(s.as_bytes());
        }
        let r = read_request(&mut &b[..]).unwrap();
        assert_eq!((r.uid, r.id.as_str(), r.path.as_str()), (1000, "6dcf52f2-09a6", "/home/a/.vscode-server/msl/x.sock"));
        b[0] = 2;
        assert!(read_request(&mut &b[..]).is_err());
    }
}
