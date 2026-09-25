// SPDX-License-Identifier: Apache-2.0
//! Per-distro init (`msl-distro-init <json>`), a fresh single-threaded process
//! spawned by mini-init, so fork/unshare/pivot_root are safe here.
//!
//!   A (supervisor, root pidns): join cgroup, unshare(mnt|uts|ipc|cgroup|pid), fork B
//!   B (PID 1 of the distro pidns): mounts, pivot_root, then
//!       systemd: fork C = agent, exec /sbin/init
//!       else:    B becomes the agent itself (and reaps)

use crate::{agent, config, sys};
use nix::mount::{MntFlags, MsFlags, mount, umount2};
use nix::sched::{CloneFlags, unshare};
use nix::sys::wait::{WaitStatus, waitpid};
use nix::unistd::{ForkResult, chdir, fork, pivot_root};
use serde::Deserialize;
use std::ffi::CString;
use std::os::fd::RawFd;
use std::time::{Duration, Instant};

#[derive(Deserialize)]
pub struct Cfg {
    pub id: String,
    pub name: String,
    pub hostname: String,
    pub rootfs: String,
    pub port: u32,
    pub ready_fd: RawFd,
    pub nameservers: Vec<String>,
}

pub fn main(args: &[String]) -> sys::Result<()> {
    let cfg: Cfg = serde_json::from_str(args.first().ok_or("missing config")?)?;
    let fd = cfg.ready_fd;
    let fail = |e: &dyn std::fmt::Display| sys::write_fd_line(fd, &format!("error {e}"));

    // --- A: supervisor (stays outside the distro's cgroup) ---
    if let Err(e) = unshare(
        CloneFlags::CLONE_NEWNS | CloneFlags::CLONE_NEWUTS | CloneFlags::CLONE_NEWIPC | CloneFlags::CLONE_NEWPID,
    ) {
        fail(&e);
        return Err(e.into());
    }
    match unsafe { fork() }? {
        ForkResult::Parent { child } => {
            sys::write_fd_line(fd, &format!("pid {child}"));
            unsafe { libc::close(fd) };
            let code = match waitpid(child, None) {
                Ok(WaitStatus::Exited(_, c)) => c,
                Ok(WaitStatus::Signaled(_, s, _)) => 128 + s as i32,
                _ => 1,
            };
            sys::log(&format!("distro {} exited ({code})", cfg.name));
            std::process::exit(code);
        }
        ForkResult::Child => {}
    }

    // --- B: PID 1 of the distro ---
    // Join /msl/<name> and make it the cgroupns root before mounting cgroup2.
    let cg = format!("/sys/fs/cgroup/msl/{}", cfg.id);
    let joined = sys::mkdir_p(&cg)
        .and_then(|_| sys::write_file(format!("{cg}/cgroup.procs"), "0"))
        .and_then(|_| unshare(CloneFlags::CLONE_NEWCGROUP).map_err(Into::into));
    if let Err(e) = joined {
        fail(&e);
        return Err(e);
    }
    // [network] hostname, else the Mac's name (sanitised, as WSL does with the Windows name).
    let hostname = crate::net::sanitize_hostname(
        config::distro_conf(&cfg.rootfs).get("network.hostname").unwrap_or(&cfg.hostname),
    );
    if let Err(e) = setup_root(&cfg, &hostname) {
        fail(&e);
        return Err(e);
    }
    let _ = nix::unistd::sethostname(&hostname);
    // `mslpath` on PATH, like WSL's /usr/bin/wslpath -> /init.
    if std::fs::symlink_metadata("/usr/bin/mslpath").is_err() {
        let _ = std::os::unix::fs::symlink("/run/msl/init", "/usr/bin/mslpath");
    }
    let systemd = config::distro_conf("").bool("boot.systemd", false) && std::path::Path::new("/sbin/init").exists();
    sys::write_fd_line(fd, if systemd { "systemd 1" } else { "systemd 0" });

    if systemd {
        let mut masked = crate::compat::mask_units();
        masked.extend(crate::compat::mask_links());
        if !masked.is_empty() {
            sys::log(&format!("{}: masked {}", cfg.name, masked.join(", ")));
        }
        match unsafe { fork() }? {
            ForkResult::Child => run_agent(&cfg, true), // C
            ForkResult::Parent { .. } => {
                sys::set_cloexec(fd, true);
                let init = CString::new("/sbin/init")?;
                let env = [CString::new("PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")?];
                nix::unistd::execve(&init, &[init.clone()], &env)?;
                unreachable!()
            }
        }
    } else {
        run_agent(&cfg, false)
    }
}

fn setup_root(cfg: &Cfg, hostname: &str) -> sys::Result<()> {
    let r = cfg.rootfs.as_str();
    // Slave (not private): mounts made later under the VM's shared /mnt/msl
    // (`msl --mount`) propagate into running distros; nothing leaks back.
    mount(None::<&str>, "/", None::<&str>, MsFlags::MS_REC | MsFlags::MS_SLAVE, None::<&str>)?;
    sys::bind(r, r, true)?;

    let nosuid = MsFlags::MS_NOSUID | MsFlags::MS_NODEV | MsFlags::MS_NOEXEC;
    sys::mount_fs("proc", format!("{r}/proc"), "proc", nosuid, None)?;
    sys::mount_fs("sysfs", format!("{r}/sys"), "sysfs", nosuid, None)?;
    sys::mount_fs("cgroup2", format!("{r}/sys/fs/cgroup"), "cgroup2", nosuid, Some("nsdelegate"))?;
    sys::mount_fs("devtmpfs", format!("{r}/dev"), "devtmpfs", MsFlags::MS_NOSUID, Some("mode=0755"))?;
    sys::mount_fs("devpts", format!("{r}/dev/pts"), "devpts", MsFlags::MS_NOSUID | MsFlags::MS_NOEXEC,
        Some("newinstance,gid=5,mode=620,ptmxmode=666"))?;
    sys::bind(format!("{r}/dev/pts/ptmx"), format!("{r}/dev/ptmx"), false)?;
    sys::mount_fs("tmpfs", format!("{r}/dev/shm"), "tmpfs", MsFlags::MS_NOSUID | MsFlags::MS_NODEV, None)?;
    sys::mount_fs("tmpfs", format!("{r}/run"), "tmpfs", MsFlags::MS_NOSUID | MsFlags::MS_NODEV, Some("mode=0755"))?;

    // Our binary, without touching the image: /run/msl/init.
    sys::mkdir_p(format!("{r}/run/msl"))?;
    std::fs::write(format!("{r}/run/msl/init"), b"")?;
    sys::bind("/init", format!("{r}/run/msl/init"), false)?;

    let conf = config::distro_conf(r);

    // Host filesystem at <automount.root>/mac (default /mnt/mac). virtiofs reports
    // files as owned by the caller, so no uid mapping is needed.
    if conf.bool("automount.enabled", true) && std::path::Path::new("/mnt/mac").exists() {
        let root = conf.get("automount.root").unwrap_or("/mnt/").trim_end_matches('/').to_string();
        let target = format!("{r}{root}/mac");
        sys::mkdir_p(&target)?;
        sys::bind("/mnt/mac", &target, false)?;
    }

    // /mnt/msl: disks attached with `msl --mount`, shared by all distros.
    if std::path::Path::new("/mnt/msl").exists() {
        sys::mkdir_p(format!("{r}/mnt/msl"))?;
        sys::bind("/mnt/msl", format!("{r}/mnt/msl"), true)?;
    }

    // [network] generateHosts (default true): /etc/hosts and /etc/hostname, so
    // systemd keeps our hostname instead of the image's.
    if conf.bool("network.generatehosts", true) {
        let mac_hosts = std::fs::read_to_string("/mnt/mac/private/etc/hosts").unwrap_or_default();
        let hosts = crate::net::generate_hosts(hostname, crate::net::default_gateway().as_deref(), &mac_hosts);
        let _ = std::fs::remove_file(format!("{r}/etc/hosts"));
        std::fs::write(format!("{r}/etc/hosts"), hosts)?;
        let _ = std::fs::remove_file(format!("{r}/etc/hostname"));
        std::fs::write(format!("{r}/etc/hostname"), format!("{hostname}\n"))?;
    }

    // [network] generateResolvConf (default true): replace the file/symlink.
    if conf.bool("network.generateresolvconf", true) && !cfg.nameservers.is_empty() {
        let p = format!("{r}/etc/resolv.conf");
        let _ = std::fs::remove_file(&p);
        let body: String = cfg.nameservers.iter().map(|n| format!("nameserver {n}\n")).collect();
        std::fs::write(&p, format!("# Generated by msl. To stop this, set [network] generateResolvConf = false in /etc/wsl.conf\n{body}"))?;
    }

    chdir(r)?;
    pivot_root(".", ".")?;
    umount2(".", MntFlags::MNT_DETACH)?;
    chdir("/")?;
    Ok(())
}

// ---- agent (runs inside all distro namespaces) ----

fn run_agent(cfg: &Cfg, systemd: bool) -> ! {
    if systemd {
        // Leave the cgroupns root to systemd (move into a leaf) and reap our own
        // orphans instead of handing them to systemd.
        let _ = sys::mkdir_p("/sys/fs/cgroup/msl-agent");
        let _ = sys::write_file("/sys/fs/cgroup/msl-agent/cgroup.procs", "0");
        unsafe { libc::prctl(libc::PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0) };
    }
    // Without systemd we are the distro's PID 1 and reap everything.
    crate::reaper::spawn_thread();
    let fd = cfg.ready_fd;
    agent::serve(cfg.port, cfg.name.clone(), move || {
        // Readiness: systemd must have created its bus socket.
        if systemd {
            let t0 = Instant::now();
            while !std::path::Path::new("/run/systemd/private").exists() && t0.elapsed() < Duration::from_secs(30) {
                std::thread::sleep(Duration::from_millis(20));
            }
        }
        let conf = config::distro_conf("");
        if !systemd && conf.bool("automount.mountfstab", true) {
            let _ = std::process::Command::new("/bin/mount").arg("-a").status();
        }
        if let Some(cmd) = conf.get("boot.command").filter(|c| !c.is_empty()) {
            // Run as root at distro start, detached (the reaper collects it).
            let _ = std::process::Command::new("/bin/sh").args(["-c", cmd]).spawn();
        }
        sys::write_fd_line(fd, "ready");
        unsafe { libc::close(fd) };
    })
}
