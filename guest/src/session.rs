// SPDX-License-Identifier: Apache-2.0
//! Agent `Run`: start a process in the distro with PTY or pipe stdio carried
//! over one-shot vsock data ports.

use crate::pb::{self, RunEvent, RunRequest, ShellType, run_event};
use crate::rpc::{DataPort, status};
use crate::{config, framed, reaper, users};
use std::collections::HashMap;
use std::fs::File;
use std::os::fd::{AsRawFd, OwnedFd};
use std::os::unix::process::CommandExt;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};
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
    let bind = |need: bool| -> Result<Option<DataPort>, Status> { if need { DataPort::bind().map(Some).map_err(status) } else { Ok(None) } };
    let tty_dp = bind(any_tty)?;
    let in_dp = bind(!req.stdin_tty)?;
    let out_dp = bind(!req.stdout_tty)?;
    let err_dp = bind(!req.stderr_tty)?;

    let id = NEXT_ID.fetch_add(1, Ordering::Relaxed);
    let port = |d: &Option<DataPort>| d.as_ref().map(|d| d.port).unwrap_or(0);
    let started = pb::Started { session_id: id, tty_port: port(&tty_dp), stdin_port: port(&in_dp), stdout_port: port(&out_dp), stderr_port: port(&err_dp) };
    tx.send(Ok(RunEvent { event: Some(run_event::Event::Started(started)) })).await.map_err(status)?;

    async fn accept(d: Option<DataPort>) -> Result<Option<File>, Status> {
        match d {
            Some(d) => d.accept().await.map(Some).map_err(status),
            None => Ok(None),
        }
    }
    let (tty_conn, in_conn, out_conn, err_conn) = tokio::try_join!(accept(tty_dp), accept(in_dp), accept(out_dp), accept(err_dp))?;

    // Child stdio: the PTY slave for tty fds, pipes for the others. Every stream
    // to the host goes through a flow-controlled bridge (see framed.rs).
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
    // Streams whose output we must deliver before reporting the exit.
    let mut outputs: Vec<framed::Bridge> = Vec::new();
    let mut master_for_map = None;
    if let (Some(p), Some(conn)) = (pty, tty_conn) {
        drop(p.slave);
        master_for_map = Some(p.master.try_clone().map_err(status)?);
        let m_in = File::from(p.master.try_clone().map_err(status)?);
        let m_out = File::from(p.master);
        outputs.push(framed::bridge(conn, Some(m_in), Some(m_out)).map_err(status)?);
    }
    if let (Some(conn), Some(sin)) = (in_conn, child.stdin.take()) {
        framed::bridge(conn, None, Some(file(sin))).map_err(status)?;
    }
    if let (Some(conn), Some(sout)) = (out_conn, child.stdout.take()) {
        outputs.push(framed::bridge(conn, Some(file(sout)), None).map_err(status)?);
    }
    if let (Some(conn), Some(serr)) = (err_conn, child.stderr.take()) {
        outputs.push(framed::bridge(conn, Some(file(serr)), None).map_err(status)?);
    }
    sessions().lock().unwrap().insert(id, Handle { pid, master: master_for_map });

    let code = exit_rx.await.unwrap_or(255);
    // Deliver all output first. Give up only on output a background process
    // keeps open: its sender has been waiting on an empty input for 2s.
    let drained = tokio::task::spawn_blocking(move || {
        for b in outputs {
            loop {
                match b.sent.recv_timeout(std::time::Duration::from_millis(50)) {
                    Ok(()) | Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
                    Err(_) if b.input_idle() > std::time::Duration::from_secs(2) => break,
                    Err(_) => {}
                }
            }
        }
    });
    let _ = drained.await;
    sessions().lock().unwrap().remove(&id);
    let _ = tx.send(Ok(RunEvent { event: Some(run_event::Event::Exited(pb::Exited { code })) })).await;
    Ok(())
}
