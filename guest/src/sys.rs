// SPDX-License-Identifier: Apache-2.0
//! Thin syscall helpers shared by mini-init and distro-init.

use nix::mount::{MsFlags, mount};
use std::io::Write;
use std::os::fd::{FromRawFd, OwnedFd, RawFd};
use std::path::Path;

pub type Result<T> = std::result::Result<T, Box<dyn std::error::Error + Send + Sync>>;

pub fn log(msg: &str) {
    let _ = writeln!(std::io::stderr(), "[msl] {msg}");
}

pub fn mkdir_p(p: impl AsRef<Path>) -> Result<()> {
    std::fs::create_dir_all(p.as_ref())
        .map_err(|e| format!("mkdir {}: {e}", p.as_ref().display()).into())
}

/// mount(2) with the target directory created first.
pub fn mount_fs(
    source: &str,
    target: impl AsRef<Path>,
    fstype: &str,
    flags: MsFlags,
    data: Option<&str>,
) -> Result<()> {
    let target = target.as_ref();
    mkdir_p(target)?;
    mount(Some(source), target, Some(fstype), flags, data)
        .map_err(|e| format!("mount {fstype} {source} -> {}: {e}", target.display()).into())
}

pub fn bind(source: impl AsRef<Path>, target: impl AsRef<Path>, recursive: bool) -> Result<()> {
    let (s, t) = (source.as_ref(), target.as_ref());
    let mut flags = MsFlags::MS_BIND;
    if recursive {
        flags |= MsFlags::MS_REC;
    }
    mount(Some(s), t, None::<&str>, flags, None::<&str>)
        .map_err(|e| format!("bind {} -> {}: {e}", s.display(), t.display()).into())
}

pub fn write_file(p: impl AsRef<Path>, data: &str) -> Result<()> {
    std::fs::write(p.as_ref(), data)
        .map_err(|e| format!("write {}: {e}", p.as_ref().display()).into())
}

/// Bring an interface up with SIOCSIFFLAGS (used for `lo`).
pub fn link_up(ifname: &str) -> Result<()> {
    unsafe {
        let fd = libc::socket(libc::AF_INET, libc::SOCK_DGRAM | libc::SOCK_CLOEXEC, 0);
        if fd < 0 {
            return Err("socket for ioctl failed".into());
        }
        let _guard = OwnedFd::from_raw_fd(fd);
        let mut ifr: libc::ifreq = std::mem::zeroed();
        for (i, b) in ifname.bytes().enumerate().take(libc::IFNAMSIZ - 1) {
            ifr.ifr_name[i] = b as libc::c_char;
        }
        if libc::ioctl(fd, libc::SIOCGIFFLAGS as _, &mut ifr) < 0 {
            return Err(format!("SIOCGIFFLAGS {ifname}: {}", std::io::Error::last_os_error()).into());
        }
        ifr.ifr_ifru.ifru_flags |= libc::IFF_UP as libc::c_short;
        if libc::ioctl(fd, libc::SIOCSIFFLAGS as _, &ifr) < 0 {
            return Err(format!("SIOCSIFFLAGS {ifname}: {}", std::io::Error::last_os_error()).into());
        }
    }
    Ok(())
}

pub fn set_cloexec(fd: RawFd, on: bool) {
    unsafe {
        let flags = libc::fcntl(fd, libc::F_GETFD);
        let flags = if on { flags | libc::FD_CLOEXEC } else { flags & !libc::FD_CLOEXEC };
        libc::fcntl(fd, libc::F_SETFD, flags);
    }
}

/// Write a line to a raw fd we don't own (the distro-start ready pipe).
pub fn write_fd_line(fd: RawFd, line: &str) {
    let s = format!("{line}\n");
    unsafe {
        libc::write(fd, s.as_ptr().cast(), s.len());
    }
}

pub fn set_blocking(fd: RawFd) {
    unsafe {
        let flags = libc::fcntl(fd, libc::F_GETFL);
        libc::fcntl(fd, libc::F_SETFL, flags & !libc::O_NONBLOCK);
    }
}

/// FITRIM a mounted filesystem; returns the bytes trimmed.
pub fn fstrim(path: &str) -> std::io::Result<u64> {
    #[repr(C)]
    struct FstrimRange { start: u64, len: u64, minlen: u64 }
    const FITRIM: libc::c_ulong = 0xC0185879; // _IOWR('X', 121, struct fstrim_range)
    let f = std::fs::File::open(path)?;
    let mut r = FstrimRange { start: 0, len: u64::MAX, minlen: 0 };
    if unsafe { libc::ioctl(std::os::fd::AsRawFd::as_raw_fd(&f), FITRIM as _, &mut r) } < 0 {
        return Err(std::io::Error::last_os_error());
    }
    Ok(r.len)
}
