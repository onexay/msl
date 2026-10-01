// SPDX-License-Identifier: Apache-2.0
//! A Unix socket inside a distro for `msl --connect` (VS Code's managed pipes,
//! #32; MiniInit.OpenStream).
//!
//! Only `<home>/.vscode-server/msl/<name>.sock` of the distro's default user is
//! allowed, so this can't become a proxy to docker.sock or systemd. The connect
//! itself runs on a throwaway thread that has joined the distro's mount
//! namespace and taken the user's uid/gids: symlinks resolve inside the distro
//! and the kernel checks permissions as that user.

use std::fs::File;
use std::os::fd::AsRawFd;
use std::os::unix::net::UnixStream;

/// The only sockets that may be reached: `<home>/.vscode-server/msl/<name>.sock`.
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

/// A Unix socket in a running distro, as `uid`, within the allowlist (OpenStream).
pub fn open_unix(uid: u32, id: &str, path: &str) -> Result<UnixStream, String> {
    let pid = crate::miniinit::distro_init_pid(id).ok_or("the distro is not running")?;
    let root = format!("/proc/{pid}/root");
    let passwd = std::fs::read_to_string(format!("{root}/etc/passwd")).map_err(|e| format!("/etc/passwd: {e}"))?;
    let (name, gid, home) = passwd_entry(&passwd, uid).ok_or(format!("no user with uid {uid}"))?;
    if !allowed(path, &home) {
        return Err(format!("{path}: not allowed (only {home}/.vscode-server/msl/*.sock)"));
    }
    let mut groups = groups_of(&std::fs::read_to_string(format!("{root}/etc/group")).unwrap_or_default(), &name);
    groups.push(gid);
    connect_as(pid, uid, gid, groups, path.to_string()).map_err(|e| format!("{path}: {e}"))
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
}
