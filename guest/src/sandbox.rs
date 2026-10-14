// SPDX-License-Identifier: Apache-2.0
//! Per-session cgroup supervision for Bubblewrap workloads.

use std::fs;
use std::path::{Path, PathBuf};
use tonic::Status;

const ROOT: &str = "/sys/fs/cgroup";

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Limits {
    pub cpu_max: String,
    pub memory_max: String,
    pub pids_max: String,
    pub io_max: Vec<String>,
    pub deny_network: bool,
}

impl Limits {
    /// Read an opt-in policy from `[sandbox]` in `/etc/msl.conf`.
    pub fn configured() -> Result<Option<Self>, Status> {
        let conf = crate::config::distro_conf("");
        if !conf.bool("sandbox.enabled", false) {
            return Ok(None);
        }
        let required = |key: &str| -> Result<String, Status> {
            conf.get(key)
                .filter(|v| !v.trim().is_empty())
                .map(str::to_owned)
                .ok_or_else(|| Status::failed_precondition(format!("missing [sandbox] {key}")))
        };
        let io_max = conf
            .get("sandbox.io_max")
            .unwrap_or_default()
            .split(';')
            .map(str::trim)
            .filter(|line| !line.is_empty())
            .map(str::to_owned)
            .collect();
        let limits = Self {
            cpu_max: required("sandbox.cpu_max")?,
            memory_max: required("sandbox.memory_max")?,
            pids_max: required("sandbox.pids_max")?,
            io_max,
            deny_network: conf.bool("sandbox.deny_network", false),
        };
        limits.validate()?;
        Ok(Some(limits))
    }

    fn validate(&self) -> Result<(), Status> {
        if self.io_max.is_empty() {
            return Err(Status::failed_precondition(
                "sandbox.io_max needs at least one device limit",
            ));
        }
        let pair: Vec<_> = self.cpu_max.split_whitespace().collect();
        if pair.len() != 2
            || (pair[0] != "max" && pair[0].parse::<u64>().is_err())
            || pair[1].parse::<u64>().map_or(true, |n| n == 0)
        {
            return Err(Status::invalid_argument(
                "sandbox.cpu_max must be '<quota|max> <period>'",
            ));
        }
        if self.memory_max != "max" && self.memory_max.parse::<u64>().map_or(true, |n| n == 0) {
            return Err(Status::invalid_argument(
                "sandbox.memory_max must be a positive byte count or max",
            ));
        }
        if self.pids_max != "max" && self.pids_max.parse::<u64>().map_or(true, |n| n == 0) {
            return Err(Status::invalid_argument(
                "sandbox.pids_max must be a positive count or max",
            ));
        }
        for line in &self.io_max {
            let mut fields = line.split_whitespace();
            let dev = fields.next().unwrap_or_default();
            let Some((major, minor)) = dev.split_once(':') else {
                return Err(Status::invalid_argument(
                    "sandbox.io_max entries must start with major:minor",
                ));
            };
            if major.parse::<u32>().is_err()
                || minor.parse::<u32>().is_err()
                || fields.next().is_none()
                || fields.any(|f| {
                    !["rbps=", "wbps=", "riops=", "wiops="].iter().any(|prefix| {
                        f.starts_with(prefix) && f[prefix.len()..].parse::<u64>().is_ok()
                    })
                })
            {
                return Err(Status::invalid_argument("invalid sandbox.io_max entry"));
            }
        }
        Ok(())
    }
}

/// A cgroup placed directly under the distro cgroup namespace root. It owns
/// only this session's process tree; the agent and systemd remain in msl-agent.
pub struct Sandbox {
    path: PathBuf,
}

impl Sandbox {
    pub fn create(id: u64, limits: &Limits) -> Result<Self, Status> {
        let path = Path::new(ROOT).join(format!("msl-session-{id}"));
        fs::create_dir(&path)
            .map_err(|e| Status::failed_precondition(format!("create sandbox cgroup: {e}")))?;
        let result = (|| {
            write(&path, "cpu.max", &limits.cpu_max)?;
            write(&path, "memory.max", &limits.memory_max)?;
            write(&path, "pids.max", &limits.pids_max)?;
            for line in &limits.io_max {
                write(&path, "io.max", line)?;
            }
            if limits.deny_network {
                attach_egress_deny(&path)?;
            }
            Ok::<(), Status>(())
        })();
        if let Err(e) = result {
            let _ = fs::remove_dir(&path);
            return Err(e);
        }
        Ok(Self { path })
    }

    /// Move a blocked pre-exec child before it can execute Bubblewrap.
    pub fn attach(&self, pid: i32) -> Result<(), Status> {
        write(&self.path, "cgroup.procs", &pid.to_string())
    }

    /// Kill descendants that outlive the session, then remove its cgroup.
    fn teardown(&self) {
        let _ = write(&self.path, "cgroup.kill", "1");
        for _ in 0..100 {
            if fs::remove_dir(&self.path).is_ok() || !self.path.exists() {
                return;
            }
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
        crate::sys::log(&format!(
            "sandbox cgroup {} remains busy",
            self.path.display()
        ));
    }
}

/// Attach a cgroup-skb egress filter which rejects every packet. This uses
/// `BPF_CGROUP_INET_EGRESS`, available with CONFIG_CGROUP_BPF; no JIT is needed.
fn attach_egress_deny(path: &Path) -> Result<(), Status> {
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
    #[repr(C)]
    struct Insn {
        code: u8,
        regs: u8,
        off: i16,
        imm: i32,
    }
    #[repr(C)]
    struct LoadAttr {
        prog_type: u32,
        insn_cnt: u32,
        insns: u64,
        license: u64,
        log_level: u32,
        log_size: u32,
        log_buf: u64,
        kern_version: u32,
        prog_flags: u32,
        prog_name: [u8; 16],
        prog_ifindex: u32,
        expected_attach_type: u32,
    }
    #[repr(C)]
    struct AttachAttr {
        target_fd: u32,
        attach_bpf_fd: u32,
        attach_type: u32,
        attach_flags: u32,
        replace_bpf_fd: u32,
    }

    const BPF_PROG_LOAD: libc::c_uint = 5;
    const BPF_PROG_ATTACH: libc::c_uint = 8;
    const BPF_PROG_TYPE_CGROUP_SKB: u32 = 8;
    const BPF_CGROUP_INET_EGRESS: u32 = 1;
    // mov r0, 0; exit. Returning zero drops the packet.
    let insns = [
        Insn {
            code: 0xb7,
            regs: 0x00,
            off: 0,
            imm: 0,
        },
        Insn {
            code: 0x95,
            regs: 0x00,
            off: 0,
            imm: 0,
        },
    ];
    let license = b"GPL\0";
    let mut attr = LoadAttr {
        prog_type: BPF_PROG_TYPE_CGROUP_SKB,
        insn_cnt: insns.len() as u32,
        insns: insns.as_ptr() as u64,
        license: license.as_ptr() as u64,
        log_level: 0,
        log_size: 0,
        log_buf: 0,
        kern_version: 0,
        prog_flags: 0,
        prog_name: [0; 16],
        prog_ifindex: 0,
        expected_attach_type: BPF_CGROUP_INET_EGRESS,
    };
    let attr_size = std::mem::size_of::<LoadAttr>();
    let prog = unsafe { libc::syscall(libc::SYS_bpf, BPF_PROG_LOAD, &mut attr, attr_size) as i32 };
    if prog < 0 {
        return Err(Status::failed_precondition(format!(
            "load cgroup egress filter: {}",
            std::io::Error::last_os_error()
        )));
    }
    let prog = unsafe { OwnedFd::from_raw_fd(prog) };
    let cgroup = fs::File::open(path)
        .map_err(|e| Status::failed_precondition(format!("open sandbox cgroup: {e}")))?;
    let mut attach = AttachAttr {
        target_fd: cgroup.as_raw_fd() as u32,
        attach_bpf_fd: prog.as_raw_fd() as u32,
        attach_type: BPF_CGROUP_INET_EGRESS,
        attach_flags: 0,
        replace_bpf_fd: 0,
    };
    let attach_size = std::mem::size_of::<AttachAttr>();
    let result = unsafe { libc::syscall(libc::SYS_bpf, BPF_PROG_ATTACH, &mut attach, attach_size) };
    if result < 0 {
        return Err(Status::failed_precondition(format!(
            "attach cgroup egress filter: {}",
            std::io::Error::last_os_error()
        )));
    }
    Ok(())
}

impl Drop for Sandbox {
    fn drop(&mut self) {
        self.teardown();
    }
}

fn write(dir: &Path, name: &str, value: &str) -> Result<(), Status> {
    fs::write(dir.join(name), value)
        .map_err(|e| Status::failed_precondition(format!("set sandbox {}: {e}", name)))
}

#[cfg(test)]
#[path = "../../tests/guest/sandbox.rs"]
mod tests;
