// SPDX-License-Identifier: Apache-2.0
//! Agent `Run`: start a process in the distro with PTY or pipe stdio carried
//! over one-shot vsock data ports.

use crate::pb::{self, RunEvent, RunRequest, ShellType, run_event};
use crate::rpc::{dial_host, status};
use crate::{config, reaper, users};
use std::collections::HashMap;
use std::fs::File;
use std::os::fd::{AsRawFd, OwnedFd};
use std::os::unix::process::CommandExt;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};
use tokio::sync::mpsc;
use tonic::Status;

const DEFAULT_PATH: &str = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games";

struct Handle {
    pid: i32,
    master: Option<OwnedFd>,
}

fn sessions() -> &'static Mutex<HashMap<u64, Handle>> {
    static S: OnceLock<Mutex<HashMap<u64, Handle>>> = OnceLock::new();
    S.get_or_init(|| Mutex::new(HashMap::new()))
}

static NEXT_ID: AtomicU64 = AtomicU64::new(1);

pub fn resize(id: u64, rows: u32, cols: u32) -> Result<(), Status> {
    let map = sessions().lock().unwrap();
    let h = map.get(&id).ok_or_else(|| Status::not_found("no such session"))?;
    if let Some(m) = &h.master {
        set_winsize(m.as_raw_fd(), rows, cols);
    }
    Ok(())
}

pub fn signal(id: u64, sig: i32) -> Result<(), Status> {
    let map = sessions().lock().unwrap();
    let h = map.get(&id).ok_or_else(|| Status::not_found("no such session"))?;
    // The session leader's pid is its process group id (setsid).
    unsafe { libc::kill(-h.pid, sig) };
    Ok(())
}

fn set_winsize(fd: i32, rows: u32, cols: u32) {
    let ws = libc::winsize { ws_row: rows as u16, ws_col: cols as u16, ws_xpixel: 0, ws_ypixel: 0 };
    unsafe { libc::ioctl(fd, libc::TIOCSWINSZ, &ws) };
}

/// Resolve who to run as: explicit user, else wsl.conf [user] default, else default_uid.
fn resolve_user(req: &RunRequest) -> Result<users::User, Status> {
    if !req.user.is_empty() {
        return users::by_name("", &req.user).ok_or_else(|| Status::not_found("User not found."));
    }
    let conf = config::distro_conf("");
    if let Some(name) = conf.get("user.default").filter(|n| !n.is_empty()) {
        if let Some(u) = users::by_name("", name) {
            return Ok(u);
        }
    }
    Ok(users::by_uid("", req.default_uid)
        .or_else(|| users::by_uid("", 0))
        .unwrap_or(users::User { name: "root".into(), uid: 0, gid: 0, home: "/root".into(), shell: "/bin/sh".into(), groups: vec![0] }))
}

pub async fn run(req: RunRequest, tx: mpsc::Sender<Result<RunEvent, Status>>, distro: String) -> Result<(), Status> {
    let user = resolve_user(&req)?;
    let shell = if std::path::Path::new(&user.shell).exists() { user.shell.clone() } else { "/bin/sh".into() };

    // argv / arg0
    let shell_type = ShellType::try_from(req.shell_type).unwrap_or(ShellType::Standard);
    let (argv, arg0): (Vec<String>, Option<String>) = if req.argv.is_empty() && req.command_line.is_empty() {
        let base = std::path::Path::new(&shell).file_name().unwrap().to_string_lossy().into_owned();
        (vec![shell.clone()], Some(format!("-{base}"))) // login shell
    } else if shell_type == ShellType::None {
        if req.argv.is_empty() {
            return Err(Status::invalid_argument("empty argv"));
        }
        (req.argv.clone(), None)
    } else {
        let mut v = vec![shell.clone()];
        if shell_type == ShellType::Login {
            v.push("-l".into());
        }
        v.push("-c".into());
        v.push(req.command_line.clone());
        (v, None)
    };

    let mount = crate::paths::mac_mount("");
    let cwd_req = if req.cwd.is_empty() && !req.mac_cwd.is_empty() {
        crate::paths::to_linux(&req.mac_cwd, &mount)
    } else {
        req.cwd.clone()
    };
    let cwd = match cwd_req.as_str() {
        "" | "~" => user.home.clone(),
        p if std::path::Path::new(p).is_dir() => p.to_string(),
        _ => user.home.clone(),
    };
    let cwd = if std::path::Path::new(&cwd).is_dir() { cwd } else { "/".into() };

    let mut env: HashMap<String, String> = HashMap::from([
        ("PATH".into(), DEFAULT_PATH.into()),
        ("HOME".into(), user.home.clone()),
        ("USER".into(), user.name.clone()),
        ("LOGNAME".into(), user.name.clone()),
        ("SHELL".into(), shell.clone()),
        ("MSL_DISTRO_NAME".into(), distro),
        ("TERM".into(), "xterm-256color".into()),
    ]);
    if !req.mac_home.is_empty() {
        env.insert("MSL_MACOS_HOME".into(), req.mac_home.clone());
    }
    // The distro's own locale, as a login shell (pam_env) and WSL set it. Without
    // LANG, VS Code's terminal picks one from its UI language (e.g. en_US.UTF-8)
    // that the distro may not have, and bash warns on every start.
    env.extend(distro_locale());
    env.extend(req.env.clone());
    if !req.mslenv.is_empty() {
        crate::paths::apply_mslenv(&req.mslenv, &req.mslenv_values, &mount, &mut env);
    }

    // stdio plumbing
    let any_tty = req.stdin_tty || req.stdout_tty || req.stderr_tty;
    let pty = if any_tty {
        let ws = nix::pty::Winsize { ws_row: req.rows.max(1) as u16, ws_col: req.cols.max(1) as u16, ws_xpixel: 0, ws_ypixel: 0 };
        Some(nix::pty::openpty(Some(&ws), None).map_err(status)?)
    } else {
        None
    };
    let id = NEXT_ID.fetch_add(1, Ordering::Relaxed);
    // The streams: the host ports to dial, one per stream (0 = not used).
    let d = req.dial_back.clone().filter(|d| !d.token.is_empty()).ok_or_else(|| Status::invalid_argument("no dial_back"))?;
    async fn dial(port: u32, token: &[u8]) -> Result<Option<File>, Status> {
        if port == 0 { Ok(None) } else { dial_host(port, token).await.map(Some).map_err(status) }
    }
    let t = &d.token;
    let (tty_conn, in_conn, out_conn, err_conn) =
        tokio::try_join!(dial(d.tty_port, t), dial(d.stdin_port, t), dial(d.stdout_port, t), dial(d.stderr_port, t))?;
    tx.send(Ok(RunEvent { event: Some(run_event::Event::Started(pb::Started { session_id: id })) })).await.map_err(status)?;

    // Child stdio: the PTY slave for tty fds, pipes for the others, each copied
    // to or from its stream.
    let slave_stdio = |p: &Option<nix::pty::OpenptyResult>| -> Result<Stdio, Status> {
        let s = p.as_ref().unwrap().slave.try_clone().map_err(status)?;
        Ok(Stdio::from(s))
    };
    let stdin = if req.stdin_tty { slave_stdio(&pty)? } else { Stdio::piped() };
    let stdout = if req.stdout_tty { slave_stdio(&pty)? } else { Stdio::piped() };
    let stderr = if req.stderr_tty { slave_stdio(&pty)? } else { Stdio::piped() };
    let ctty_fd: i32 = if req.stdin_tty { 0 } else if req.stdout_tty { 1 } else if req.stderr_tty { 2 } else { -1 };

    let mut cmd = Command::new(&argv[0]);
    if let Some(a0) = &arg0 {
        cmd.arg0(a0);
    }
    cmd.args(&argv[1..]).env_clear().envs(&env).current_dir(&cwd).stdin(stdin).stdout(stdout).stderr(stderr);
    let groups: Vec<libc::gid_t> = user.groups.clone();
    let (uid, gid) = (user.uid, user.gid);
    unsafe {
        cmd.pre_exec(move || {
            // Only async-signal-safe calls here.
            libc::setsid();
            if ctty_fd >= 0 && libc::ioctl(ctty_fd, libc::TIOCSCTTY as _, 0) != 0 {
                return Err(std::io::Error::last_os_error());
            }
            if libc::setgroups(groups.len(), groups.as_ptr()) != 0 || libc::setgid(gid) != 0 || libc::setuid(uid) != 0 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let mut child = cmd.spawn().map_err(|e| Status::failed_precondition(format!("{}: {e}", argv[0])))?;
    drop(cmd); // closes our copies of the slave dups
    let pid = child.id() as i32;
    let exit_rx = reaper::wait_async(pid);

    fn file<T: Into<OwnedFd>>(x: T) -> File {
        File::from(x.into())
    }
    // Output streams to deliver before reporting the exit: (kind, bridge),
    // kind 0 = tty, 1 = stdout, 2 = stderr.
    let mut outputs: Vec<(usize, RawBridge)> = Vec::new();
    let bridge = |conn: File, local_in: Option<File>, local_out: Option<File>| -> Result<RawBridge, Status> {
        raw_bridge(conn, local_in, local_out).map_err(status)
    };
    let mut master_for_map = None;
    if let (Some(p), Some(conn)) = (pty, tty_conn) {
        drop(p.slave);
        master_for_map = Some(p.master.try_clone().map_err(status)?);
        let m_in = File::from(p.master.try_clone().map_err(status)?);
        let m_out = File::from(p.master);
        outputs.push((0, bridge(conn, Some(m_in), Some(m_out))?));
    }
    if let (Some(conn), Some(sin)) = (in_conn, child.stdin.take()) {
        bridge(conn, None, Some(file(sin)))?;
    }
    if let (Some(conn), Some(sout)) = (out_conn, child.stdout.take()) {
        outputs.push((1, bridge(conn, Some(file(sout)), None)?));
    }
    if let (Some(conn), Some(serr)) = (err_conn, child.stderr.take()) {
        outputs.push((2, bridge(conn, Some(file(serr)), None)?));
    }
    sessions().lock().unwrap().insert(id, Handle { pid, master: master_for_map });

    let code = exit_rx.await.unwrap_or(255);
    // Deliver all output first. Give up only on output a background process
    // keeps open: its sender has been waiting on an empty input for 2s. Then
    // report how much each stream carried: the host reads exactly that much
    // (see pb::Exited), so nothing depends on how the vsock ends.
    let drained = tokio::task::spawn_blocking(move || {
        let mut bytes = [0u64; 3];
        for (kind, b) in outputs {
            loop {
                match b.sent.recv_timeout(Duration::from_millis(50)) {
                    Ok(()) | Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
                    Err(_) if b.input_idle() > Duration::from_secs(2) => break,
                    Err(_) => {}
                }
            }
            bytes[kind] = b.written.load(Ordering::Acquire);
        }
        bytes
    });
    let bytes = drained.await.unwrap_or_default();
    sessions().lock().unwrap().remove(&id);
    let exited = pb::Exited { code, tty_bytes: bytes[0], stdout_bytes: bytes[1], stderr_bytes: bytes[2] };
    let _ = tx.send(Ok(RunEvent { event: Some(run_event::Event::Exited(exited)) })).await;
    Ok(())
}

/// A raw (dial-back) stream: bytes from `local_in` go to the host, bytes from
/// the host go to `local_out`. No framing: the connection is guest-initiated,
/// which a stalled host reader can't freeze (#36), the host reads it directly,
/// and its end is reported on the control channel (pb::Exited).
struct RawBridge {
    sent: std::sync::mpsc::Receiver<()>,
    reading_since: Arc<Mutex<Option<Instant>>>,
    /// Bytes written to the host so far.
    written: Arc<std::sync::atomic::AtomicU64>,
}

impl RawBridge {
    fn input_idle(&self) -> Duration {
        self.reading_since.lock().unwrap().map(|t| t.elapsed()).unwrap_or_default()
    }
}

fn raw_bridge(sock: File, local_in: Option<File>, local_out: Option<File>) -> std::io::Result<RawBridge> {
    use std::io::{Read, Write};
    let reading_since = Arc::new(Mutex::new(None));
    let written = Arc::new(std::sync::atomic::AtomicU64::new(0));
    let (sent_tx, sent) = std::sync::mpsc::channel();
    // A stream that only carries output stays open until the host has read
    // what Exited reports and closed its end (rpc::wait_for_host_close). One
    // that also carries input (the tty) stays open until then anyway.
    let output_only = local_out.is_none();
    if let Some(mut input) = local_in {
        let (mut to_host, since, count) = (sock.try_clone()?, reading_since.clone(), written.clone());
        std::thread::spawn(move || {
            let mut buf = vec![0u8; 256 * 1024];
            loop {
                *since.lock().unwrap() = Some(Instant::now());
                let n = input.read(&mut buf);
                *since.lock().unwrap() = None;
                // EIO from a PTY master: the slave side is closed.
                let Ok(n) = n else { break };
                if n == 0 || to_host.write_all(&buf[..n]).is_err() {
                    break;
                }
                count.fetch_add(n as u64, Ordering::Release);
            }
            let _ = sent_tx.send(());
            if output_only {
                crate::rpc::wait_for_host_close(to_host);
            }
        });
    } else {
        let _ = sent_tx.send(());
    }
    if let Some(output) = local_out {
        let from_host = sock.try_clone()?;
        std::thread::spawn(move || {
            crate::rpc::copy_plain(from_host, &output);
            // Dropping `output` closes the child's stdin (eof).
        });
    }
    Ok(RawBridge { sent, reading_since, written })
}

/// LANG, LANGUAGE and LC_* from /etc/default/locale (Debian, Ubuntu) or
/// /etc/locale.conf (Arch, Fedora, SUSE), read inside the distro's mount namespace.
fn distro_locale() -> Vec<(String, String)> {
    ["/etc/default/locale", "/etc/locale.conf"]
        .iter()
        .find_map(|p| std::fs::read_to_string(p).ok())
        .map(|text| parse_locale(&text))
        .unwrap_or_default()
}

fn parse_locale(text: &str) -> Vec<(String, String)> {
    text.lines()
        .filter_map(|l| {
            let l = l.trim();
            let (k, v) = l.strip_prefix("export ").unwrap_or(l).split_once('=')?;
            let v = v.trim().trim_matches(|c| c == '"' || c == '\'');
            let wanted = k == "LANG" || k == "LANGUAGE" || k.starts_with("LC_");
            (wanted && !v.is_empty() && !l.starts_with('#')).then(|| (k.to_string(), v.to_string()))
        })
        .collect()
}

#[cfg(test)]
#[path = "../../tests/guest/session.rs"]
mod locale_tests;
