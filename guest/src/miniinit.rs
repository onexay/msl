// SPDX-License-Identifier: Apache-2.0
//! Utility-VM PID 1 (the `mini_init` equivalent).
//!
//! Stage 1 (initramfs): move to a tmpfs root so child mount namespaces can
//! `pivot_root` (the initramfs `rootfs` mount can never be pivoted away).
//! Stage 2: base mounts, host shares, data disk, Rosetta binfmt, MiniInit gRPC.

use crate::pb::{self, mini_init_server::MiniInit};
use crate::rpc::status;
use crate::{archive, config, reaper, sys};
use nix::mount::MsFlags;
use nix::unistd::{chdir, chroot};
use std::collections::HashMap;
use std::ffi::CString;
use std::io::{BufRead, BufReader};
use std::os::fd::{AsRawFd, FromRawFd, IntoRawFd};
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};
use tokio_stream::wrappers::ReceiverStream;
use tonic::{Request, Response, Status};

const CONTROL_PORT: u32 = 1024;
const FIRST_AGENT_PORT: u32 = 2000;
const DATA: &str = "/var/lib/msl";
/// The distros' own disks (#50): each is mounted at `/run/msl-disks/<id>/rootfs`,
/// so its filesystem root is the distro's root, as in WSL's ext4.vhdx.
const DISKS: &str = "/run/msl-disks";
const SYS_BLOCK: &str = "/sys/block";
/// NFS export root for ~/.msl/distros: one bind mount of each distro's rootfs, by name.
const VIEW: &str = "/run/msl-view";
const ROSETTA_MAGIC: &str = r":rosetta:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00:\xff\xff\xff\xff\xff\xfe\xfe\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/run/rosetta/rosetta:CF";

#[derive(Clone)]
struct Running {
    pid: i32,        // distro PID 1 (root pidns)
    supervisor: i32, // msl-distro-init supervisor (our child)
    port: u32,
    systemd: bool,
    /// Set by the watcher thread (the only waiter on `supervisor`) once it exits.
    exited: std::sync::Arc<(Mutex<bool>, std::sync::Condvar)>,
}

/// PID 1 of a running distro (root pidns), for connect.rs.
pub(crate) fn distro_init_pid(id: &str) -> Option<i32> {
    running().lock().unwrap().get(id).map(|r| r.pid)
}

fn running() -> &'static Mutex<HashMap<String, Running>> {
    static R: OnceLock<Mutex<HashMap<String, Running>>> = OnceLock::new();
    R.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Distros being stopped: out of `running()`, but their processes (and mount
/// namespace) may not be gone yet.
fn stopping() -> &'static Mutex<HashMap<String, Running>> {
    static S: OnceLock<Mutex<HashMap<String, Running>>> = OnceLock::new();
    S.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Distros on their own disk that are mounted now: id -> block device (vdX).
fn attached() -> &'static Mutex<HashMap<String, String>> {
    static A: OnceLock<Mutex<HashMap<String, String>>> = OnceLock::new();
    A.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Serializes attaching and detaching disks with the start of a distro, whose
/// new mount namespace briefly holds a copy of every mount (so of every other
/// distro's disk) until it pivots into its own root.
fn mount_lock() -> &'static Mutex<()> {
    static L: OnceLock<Mutex<()>> = OnceLock::new();
    L.get_or_init(|| Mutex::new(()))
}

fn check_id(id: &str) -> Result<(), Status> {
    // ids are GUIDs chosen by msld; refuse anything path-like.
    if id.is_empty() || !id.chars().all(|c| c.is_ascii_hexdigit() || c == '-') {
        return Err(Status::invalid_argument("bad distro id"));
    }
    Ok(())
}

/// A distro's directory: its own disk's mount point when attached, else its
/// directory on data.img (distros from before #50).
fn distro_dir(id: &str) -> Result<PathBuf, Status> {
    check_id(id)?;
    if attached().lock().unwrap().contains_key(id) {
        return Ok(Path::new(DISKS).join(id));
    }
    Ok(legacy_dir(id))
}

fn legacy_dir(id: &str) -> PathBuf {
    Path::new(DATA).join("distros").join(id)
}

/// Where an own disk is mounted: the distro's root filesystem.
fn own_root(id: &str) -> PathBuf {
    Path::new(DISKS).join(id).join("rootfs")
}

/// A freshly formatted disk holds only lost+found.
fn is_empty_root(dir: &Path) -> bool {
    std::fs::read_dir(dir).map(|d| d.flatten().all(|e| e.file_name() == "lost+found")).unwrap_or(true)
}

/// Remove everything in `dir` (a mount point) except lost+found.
fn clear_root(dir: &Path) {
    if let Ok(d) = std::fs::read_dir(dir) {
        for e in d.flatten().filter(|e| e.file_name() != "lost+found") {
            let p = e.path();
            let _ = if e.file_type().map(|t| t.is_dir()).unwrap_or(false) { std::fs::remove_dir_all(&p) } else { std::fs::remove_file(&p) };
        }
    }
}

/// What was checked or grown on data.img at this boot, for PingReply.
static GROW: OnceLock<String> = OnceLock::new();

/// What mini-init needs from an ext4 superblock.
#[derive(Debug, PartialEq)]
struct Superblock {
    size: u64,    // bytes
    uuid: String, // lowercase, hyphenated
    clean: bool,  // EXT4_VALID_FS
    errors: bool, // EXT4_ERROR_FS
    error_count: u32, // errors recorded since the last fsck
}

/// Parse the 1024-byte superblock (the bytes at offset 1024 of the device).
fn parse_superblock(sb: &[u8]) -> std::io::Result<Superblock> {
    if sb.len() < 1024 || u16::from_le_bytes([sb[0x38], sb[0x39]]) != 0xEF53 {
        return Err(std::io::Error::other("no ext4 superblock"));
    }
    let u32at = |o: usize| u32::from_le_bytes(sb[o..o + 4].try_into().unwrap()) as u64;
    let hi = if u32at(0x60) & 0x80 != 0 { u32at(0x150) } else { 0 }; // INCOMPAT_64BIT
    let state = u16::from_le_bytes([sb[0x3A], sb[0x3B]]);
    let hex: String = sb[0x68..0x78].iter().map(|b| format!("{b:02x}")).collect();
    Ok(Superblock {
        size: ((hi << 32) | u32at(0x04)) << (10 + u32at(0x18)),
        uuid: format!("{}-{}-{}-{}-{}", &hex[0..8], &hex[8..12], &hex[12..16], &hex[16..20], &hex[20..32]),
        clean: state & 1 != 0,
        errors: state & 2 != 0,
        error_count: u32::from_le_bytes(sb[0x194..0x198].try_into().unwrap()),
    })
}

fn read_superblock(f: &std::fs::File) -> std::io::Result<Superblock> {
    use std::os::unix::fs::FileExt;
    let mut sb = [0u8; 1024];
    f.read_exact_at(&mut sb, 1024)?;
    parse_superblock(&sb)
}

/// Size of the ext4 filesystem on `dev` in bytes, from its superblock.
fn ext4_size(dev: &str) -> std::io::Result<u64> {
    read_superblock(&std::fs::File::open(dev)?).map(|s| s.size)
}

/// The virtio block device (vdX) whose serial is `serial`, under `sys_block`.
fn find_by_serial(sys_block: &Path, serial: &str) -> Option<String> {
    let mut names: Vec<String> = std::fs::read_dir(sys_block)
        .ok()?
        .flatten()
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .filter(|n| n.starts_with("vd"))
        .collect();
    names.sort();
    names.into_iter().find(|n| {
        std::fs::read_to_string(sys_block.join(n).join("serial"))
            .map(|s| s.trim_end_matches(['\0', '\n', ' ']) == serial)
            .unwrap_or(false)
    })
}

/// Run a tool (e2fsck, resize2fs) after the reaper started, which owns
/// waitpid: its exit code (-1 if unknown) and combined output.
fn run_tool(tool: &str, args: &[&str]) -> Result<(i32, String), String> {
    use std::io::Read;
    let (mut rd, wr) = std::io::pipe().map_err(|e| format!("pipe: {e}"))?;
    let wr2 = wr.try_clone().map_err(|e| format!("pipe: {e}"))?;
    let mut cmd = Command::new(tool);
    cmd.args(args).stdin(std::process::Stdio::null()).stdout(wr).stderr(wr2);
    let pid = cmd.spawn().map_err(|e| format!("{tool}: {e}"))?.id() as i32;
    drop(cmd); // our copies of the write end, so the read below ends
    let mut out = Vec::new();
    let _ = rd.read_to_end(&mut out);
    let code = reaper::wait(pid, Some(Duration::from_secs(3600))).unwrap_or(-1);
    Ok((code, String::from_utf8_lossy(&out).into_owned()))
}

/// Grow the ext4 filesystem on `dev` from `fs` to `target` bytes. Offline only:
/// the formatter's sparse_super2 rules out online resize. e2fsck -f first
/// (resize2fs requires a checked filesystem; it also replays the journal).
/// `run` runs a tool and returns its exit code.
fn grow_fs(dev: &str, fs: u64, target: u64, run: &dyn Fn(&str, &[&str]) -> Result<i32, String>) -> Result<String, String> {
    let gib = |b: u64| b as f64 / (1u64 << 30) as f64;
    let t0 = Instant::now();
    let size = format!("{}K", target / 1024);
    // e2fsck: 0 clean; 1 or 2 means errors fixed. Other results stop the mount.
    match run("/bin/e2fsck", &["-f", "-p", dev]) {
        Ok(0 | 1 | 2) => match run("/bin/resize2fs", &[dev, &size]) {
            Ok(0) => match ext4_size(dev) {
                Ok(new) => Ok(format!("grew {:.1} GiB → {:.1} GiB in {:.1} s", gib(fs), gib(new), t0.elapsed().as_secs_f64())),
                Err(e) => Ok(format!("resize2fs finished but the superblock can't be read: {e}")),
            },
            Ok(c) => Ok(format!("resize2fs failed (exit {c}); size unchanged at {:.1} GiB", gib(fs))),
            Err(e) => Ok(format!("{e}; size unchanged")),
        },
        Ok(c) => Err(format!("e2fsck found problems it didn't fix (exit {c})")),
        Err(e) => Err(e),
    }
}

/// Check data.img for ext4 errors and grow it to fill its disk before mounting.
/// `msl --manage --resize` only makes the image larger; resizing happens here.
fn grow_data_disk(name: &str) -> sys::Result<()> {
    let dev = format!("/dev/{name}");
    let size = std::fs::read_to_string(format!("{SYS_BLOCK}/{name}/size"))
        .ok()
        .and_then(|s| s.trim().parse::<u64>().ok())
        .map(|sectors| sectors * 512);
    let Ok(sb) = read_superblock(&std::fs::File::open(&dev)?) else { return Ok(()) };
    // Before the reaper starts, so waiting on the tool ourselves is safe.
    let run = |tool: &str, args: &[&str]| -> Result<i32, String> {
        let out = Command::new(tool).args(args).output().map_err(|e| format!("{tool}: {e}"))?;
        let code = out.status.code().unwrap_or(-1);
        let text = String::from_utf8_lossy(&out.stdout).to_string() + &String::from_utf8_lossy(&out.stderr);
        sys::log(&format!("{tool} {}: exit {code}\n{}", args.join(" "), text.trim()));
        Ok(code)
    };
    let grow_to = size.filter(|n| *n >= sb.size + (64 << 20));
    let result = if let Some(size) = grow_to {
        grow_fs(&dev, sb.size, size, &run).map_err(std::io::Error::other)?
    } else if sb.errors || !sb.clean || sb.error_count > 0 {
        match run("/bin/e2fsck", &["-f", "-p", &dev]).map_err(std::io::Error::other)? {
            0 => "checked filesystem".to_string(),
            c @ (1 | 2) => format!("e2fsck repaired filesystem (exit {c})"),
            c => return Err(std::io::Error::other(format!("e2fsck could not safely repair data disk (exit {c})")).into()),
        }
    } else {
        return Ok(());
    };
    sys::log(&format!("data disk: {result}"));
    let _ = GROW.set(result);
    Ok(())
}

/// /etc/machine-id from `msl.machine_id=` (the VM's VZGenericMachineIdentifier
/// UUID, 32 lowercase hex digits), so the utility VM keeps one ID across boots.
fn write_machine_id() {
    let cmdline = std::fs::read_to_string("/proc/cmdline").unwrap_or_default();
    let Some(id) = parse_machine_id(&cmdline) else { return };
    if let Err(e) = std::fs::write("/etc/machine-id", format!("{id}\n")) {
        sys::log(&format!("machine-id: {e}"));
    }
}

fn parse_machine_id(cmdline: &str) -> Option<&str> {
    cmdline
        .split_whitespace()
        .find_map(|a| a.strip_prefix("msl.machine_id="))
        .filter(|id| id.len() == 32 && id.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f')))
}

pub fn main() -> sys::Result<()> {
    if std::env::var_os("MSL_STAGE").is_none() {
        return stage1();
    }
    let t0 = Instant::now();
    base_mounts()?;
    let _ = nix::unistd::sethostname("msl");
    write_machine_id();
    if let Err(e) = sys::link_up("lo") {
        sys::log(&format!("lo: {e}"));
    }
    for (tag, target) in [("mac", "/mnt/mac"), ("rosetta", "/run/rosetta")] {
        if let Err(e) = sys::mount_fs(tag, target, "virtiofs", MsFlags::empty(), None) {
            sys::log(&format!("virtiofs {tag}: {e}"));
        }
    }
    // data.img has the serial "data" (the distros' own disks follow it: d0, d1, ...).
    let data = find_by_serial(Path::new(SYS_BLOCK), "data").unwrap_or_else(|| "vda".into());
    grow_data_disk(&data)?;
    sys::mount_fs(&format!("/dev/{data}"), DATA, "ext4", MsFlags::MS_NOATIME, None)?;
    sys::mkdir_p(format!("{DATA}/distros"))?;
    if Path::new("/run/rosetta/rosetta").exists() {
        let r = sys::mount_fs("binfmt_misc", "/proc/sys/fs/binfmt_misc", "binfmt_misc", MsFlags::empty(), None)
            .and_then(|_| sys::write_file("/proc/sys/fs/binfmt_misc/register", ROSETTA_MAGIC));
        if let Err(e) = r {
            sys::log(&format!("rosetta binfmt: {e}"));
        }
    }
    // /mnt/msl: shared with every distro (as a slave mount), for `msl --mount`
    // (the /mnt/wsl equivalent).
    sys::mount_fs("tmpfs", "/mnt/msl", "tmpfs", MsFlags::MS_NOSUID | MsFlags::MS_NODEV, Some("mode=0755"))?;
    nix::mount::mount(None::<&str>, "/mnt/msl", None::<&str>, MsFlags::MS_SHARED, None::<&str>)?;

    // cgroup v2: delegate controllers to /msl/<distro>.
    let _ = sys::write_file("/sys/fs/cgroup/cgroup.subtree_control", "+cpu +memory +pids +io");
    let _ = sys::mkdir_p("/sys/fs/cgroup/msl");
    let _ = sys::write_file("/sys/fs/cgroup/msl/cgroup.subtree_control", "+cpu +memory +pids +io");

    // BusyBox applets for `msl --debug-shell` (the VM root namespace has no distro).
    if Path::new("/bin/busybox").exists() {
        let _ = Command::new("/bin/busybox").args(["--install", "-s"]).status();
    }

    reaper::spawn_thread();
    let rt = tokio::runtime::Builder::new_current_thread().enable_all().build()?;
    rt.block_on(async {
        if let Err(e) = crate::dns::spawn() {
            sys::log(&format!("dns stub: {e}"));
        }
        let ports = crate::net::spawn_port_watcher();
        let _ = sys::mkdir_p(VIEW);
        tokio::spawn(async {
            if let Err(e) = crate::nfs::serve(PathBuf::from(VIEW), crate::net::NFS_PORT).await {
                sys::log(&format!("nfs: {e}"));
            }
        });
        if let Err(e) = crate::net::spawn_forwarder() {
            sys::log(&format!("forwarder: {e}"));
        }
        let incoming = crate::rpc::incoming(CONTROL_PORT)?;
        sys::log(&format!("mini-init ready on vsock:{CONTROL_PORT} ({:?})", t0.elapsed()));
        tonic::transport::Server::builder()
            .add_service(pb::mini_init_server::MiniInitServer::new(MiniInitService { ports }))
            // The Agent service in the VM's root namespace: `msl --debug-shell`.
            .add_service(pb::agent_server::AgentServer::new(crate::agent::AgentService { distro: "(debug-shell)".into() }))
            .serve_with_incoming(incoming)
            .await?;
        Ok::<(), Box<dyn std::error::Error + Send + Sync>>(())
    })
}

fn stage1() -> sys::Result<()> {
    let nr = "/newroot";
    sys::mount_fs("tmpfs", nr, "tmpfs", MsFlags::empty(), Some("mode=0755"))?;
    std::fs::copy("/init", format!("{nr}/init"))?;
    // Static tools from the initramfs: busybox, e2fsck, resize2fs.
    if let Ok(tools) = std::fs::read_dir("/bin") {
        sys::mkdir_p(format!("{nr}/bin"))?;
        for t in tools.flatten() {
            std::fs::copy(t.path(), Path::new(nr).join("bin").join(t.file_name()))?;
        }
    }
    for d in ["dev", "proc", "sys", "run", "tmp", "mnt", "var/lib/msl", "etc", "sbin", "usr/bin", "usr/sbin", "root"] {
        sys::mkdir_p(format!("{nr}/{d}"))?;
    }
    chdir(nr)?;
    nix::mount::mount(Some("."), "/", None::<&str>, MsFlags::MS_MOVE, None::<&str>)?;
    chroot(".")?;
    chdir("/")?;
    let prog = CString::new("/init")?;
    let env: Vec<CString> = std::env::vars()
        .map(|(k, v)| CString::new(format!("{k}={v}")).unwrap())
        .chain([CString::new("MSL_STAGE=2")?])
        .collect();
    nix::unistd::execve(&prog, &[prog.clone()], &env)?;
    unreachable!()
}

fn base_mounts() -> sys::Result<()> {
    let nosuid = MsFlags::MS_NOSUID | MsFlags::MS_NODEV | MsFlags::MS_NOEXEC;
    sys::mount_fs("proc", "/proc", "proc", nosuid, None)?;
    sys::mount_fs("sysfs", "/sys", "sysfs", nosuid, None)?;
    sys::mount_fs("devtmpfs", "/dev", "devtmpfs", MsFlags::MS_NOSUID, Some("mode=0755"))?;
    sys::mount_fs("devpts", "/dev/pts", "devpts", MsFlags::MS_NOSUID | MsFlags::MS_NOEXEC, Some("gid=5,mode=620,ptmxmode=666"))?;
    sys::mount_fs("tmpfs", "/dev/shm", "tmpfs", MsFlags::MS_NOSUID | MsFlags::MS_NODEV, None)?;
    sys::mount_fs("tmpfs", "/run", "tmpfs", MsFlags::MS_NOSUID | MsFlags::MS_NODEV, Some("mode=0755"))?;
    sys::mount_fs("tmpfs", "/tmp", "tmpfs", MsFlags::MS_NOSUID | MsFlags::MS_NODEV, None)?;
    sys::mount_fs("cgroup2", "/sys/fs/cgroup", "cgroup2", nosuid, Some("nsdelegate"))?;
    Ok(())
}

fn view_state() -> &'static Mutex<HashMap<String, String>> {
    static V: OnceLock<Mutex<HashMap<String, String>>> = OnceLock::new();
    V.get_or_init(|| Mutex::new(HashMap::new()))
}

/// The view msld asked for (name -> id). Distros whose disk isn't attached are
/// left out of /run/msl-view until it is.
fn view_want() -> &'static Mutex<HashMap<String, String>> {
    static W: OnceLock<Mutex<HashMap<String, String>>> = OnceLock::new();
    W.get_or_init(|| Mutex::new(HashMap::new()))
}

/// The requested view without distro `id`.
fn view_without(id: &str) -> HashMap<String, String> {
    view_want().lock().unwrap().iter().filter(|(_, v)| *v != id).map(|(k, v)| (k.clone(), v.clone())).collect()
}

/// Make /run/msl-view contain exactly `want` (name -> id), as bind mounts.
fn set_view(want: &HashMap<String, String>) {
    let mut cur = view_state().lock().unwrap();
    let stale: Vec<String> = cur.iter().filter(|(n, id)| want.get(*n) != Some(*id)).map(|(n, _)| n.clone()).collect();
    for name in stale {
        let p = format!("{VIEW}/{name}");
        let _ = nix::mount::umount2(p.as_str(), nix::mount::MntFlags::MNT_DETACH);
        let _ = std::fs::remove_dir(&p);
        cur.remove(&name);
    }
    for (name, id) in want {
        if cur.get(name) == Some(id) || name.is_empty() || name.contains('/') || name.starts_with('.') {
            continue;
        }
        let (Ok(dir), p) = (distro_dir(id), format!("{VIEW}/{name}")) else { continue };
        let rootfs = dir.join("rootfs");
        if !rootfs.is_dir() || sys::mkdir_p(&p).is_err() {
            continue;
        }
        match sys::bind(&rootfs, &p, false) {
            Ok(()) => {
                cur.insert(name.clone(), id.clone());
            }
            Err(e) => sys::log(&format!("file view {name}: {e}")),
        }
    }
}

/// Hot-pluggable disks (USB mass storage shows up as sdX; vda is the data disk),
/// as "name:diskseq". The kernel's diskseq is never reused, so a re-attached
/// disk that gets the same name (sda) is still recognised as new.
fn disks() -> Vec<String> {
    let mut v: Vec<String> = std::fs::read_dir("/sys/block")
        .map(|d| {
            d.flatten()
                .map(|e| e.file_name().to_string_lossy().into_owned())
                .filter(|n| n.starts_with("sd"))
                .map(|n| {
                    let seq = std::fs::read_to_string(format!("/sys/block/{n}/diskseq")).unwrap_or_default();
                    format!("{n}:{}", seq.trim())
                })
                .collect()
        })
        .unwrap_or_default();
    v.sort();
    v
}

fn nameservers() -> Vec<String> {
    std::fs::read_to_string("/proc/net/pnp")
        .unwrap_or_default()
        .lines()
        .filter_map(|l| l.strip_prefix("nameserver ").map(|s| s.trim().to_string()))
        .filter(|s| s != "0.0.0.0")
        .collect()
}

/// rmdir a cgroup subtree bottom-up (cgroup dirs can only be removed when empty).
fn remove_cgroup_tree(dir: &Path) -> bool {
    if !dir.is_dir() {
        return true;
    }
    if let Ok(entries) = std::fs::read_dir(dir) {
        for e in entries.flatten() {
            if e.file_type().map(|t| t.is_dir()).unwrap_or(false) {
                remove_cgroup_tree(&e.path());
            }
        }
    }
    for _ in 0..100 {
        if std::fs::remove_dir(dir).is_ok() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    sys::log(&format!("cgroup {} not removed", dir.display()));
    false
}

fn cgroup_of(id: &str) -> PathBuf {
    Path::new("/sys/fs/cgroup/msl").join(id)
}

/// Blocking: launch msl-distro-init and wait for its agent to be ready.
fn start_blocking(req: pb::StartDistroRequest) -> Result<pb::StartDistroReply, Status> {
    let t0 = Instant::now();
    if let Some(r) = running().lock().unwrap().get(&req.id) {
        return Ok(pb::StartDistroReply { agent_port: r.port, systemd: r.systemd, start_seconds: 0.0 });
    }
    if req.own_disk && !attached().lock().unwrap().contains_key(&req.id) {
        return Err(Status::failed_precondition("the distribution's disk is not attached"));
    }
    let dir = distro_dir(&req.id)?;
    let rootfs = dir.join("rootfs");
    if !rootfs.is_dir() {
        return Err(Status::not_found("distribution root filesystem not found"));
    }
    // Until the distro has pivoted into its root (it reports `systemd` after
    // that), its mount namespace holds every other distro's disk too.
    let mut mount_guard = Some(mount_lock().lock().unwrap());
    remove_cgroup_tree(&cgroup_of(&req.id));
    let port = {
        let map = running().lock().unwrap();
        (FIRST_AGENT_PORT..).find(|p| !map.values().any(|r| r.port == *p)).unwrap()
    };
    let (rd, wr) = nix::unistd::pipe().map_err(status)?;
    sys::set_cloexec(rd.as_raw_fd(), true);
    sys::set_cloexec(wr.as_raw_fd(), false);
    let cfg = serde_json::json!({
        "id": req.id, "name": req.name, "hostname": req.hostname,
        "rootfs": rootfs, "port": port, "ready_fd": wr.as_raw_fd(),
        "nameservers": if req.dns_tunneling {
            vec![crate::dns::STUB_ADDR.to_string()]
        } else if !req.dns_proxy && !req.host_dns_servers.is_empty() {
            req.host_dns_servers
        } else {
            nameservers()
        },
    });
    let mut cmd = Command::new("/init");
    std::os::unix::process::CommandExt::arg0(&mut cmd, "msl-distro-init");
    let child = cmd.arg(cfg.to_string()).spawn().map_err(|e| status(format!("spawn distro-init: {e}")))?;
    let supervisor = child.id() as i32;
    drop(cmd);
    drop(wr);

    let (tx, rx) = std::sync::mpsc::channel();
    let rd = rd.into_raw_fd();
    std::thread::spawn(move || {
        let f = unsafe { std::fs::File::from_raw_fd(rd) };
        for line in BufReader::new(f).lines().map_while(Result::ok) {
            if tx.send(line).is_err() {
                break;
            }
        }
    });
    let (mut pid, mut systemd) = (0, false);
    let deadline = Instant::now() + Duration::from_secs(60);
    loop {
        match rx.recv_timeout(deadline.saturating_duration_since(Instant::now())) {
            Ok(l) if l.starts_with("pid ") => pid = l[4..].trim().parse().unwrap_or(0),
            Ok(l) if l.starts_with("systemd ") => {
                systemd = l.ends_with('1');
                mount_guard.take();
            }
            Ok(l) if l == "ready" => break,
            Ok(l) => return Err(Status::internal(format!("distro init: {l}"))),
            Err(_) => return Err(Status::deadline_exceeded("distro init did not become ready")),
        }
    }
    let exited = std::sync::Arc::new((Mutex::new(false), std::sync::Condvar::new()));
    running().lock().unwrap().insert(req.id.clone(), Running { pid, supervisor, port, systemd, exited: exited.clone() });

    // The only waiter on the supervisor: forgets the distro when it goes away
    // (stopped, or e.g. `poweroff` inside it) and wakes stop_blocking.
    let id = req.id.clone();
    std::thread::spawn(move || {
        reaper::wait(supervisor, None);
        let mut map = running().lock().unwrap();
        if map.get(&id).map(|r| r.supervisor) == Some(supervisor) {
            map.remove(&id);
        }
        drop(map);
        remove_cgroup_tree(&cgroup_of(&id));
        let (lock, cv) = &*exited;
        *lock.lock().unwrap() = true;
        cv.notify_all();
    });
    Ok(pb::StartDistroReply { agent_port: port, systemd, start_seconds: t0.elapsed().as_secs_f64() })
}

/// How long a distro gets to shut down cleanly before it is killed.
const STOP_GRACE: Duration = Duration::from_secs(10);

fn stop_blocking(id: &str) {
    stop_many(&[id.to_string()], STOP_GRACE);
}

/// Stop distros cleanly, all at once: a systemd distro gets SIGRTMIN+4 (systemd
/// powers off, so services and journald flush and close their files); any
/// other distro gets SIGTERM for every process in its cgroup. Whatever is still
/// running after `grace` is killed with its pid namespace.
fn stop_many(ids: &[String], grace: Duration) {
    let stopping: Vec<(String, Running)> = {
        let mut map = running().lock().unwrap();
        ids.iter().filter_map(|id| map.remove(id).map(|r| (id.clone(), r))).collect()
    };
    self::stopping().lock().unwrap().extend(stopping.iter().cloned());
    for (id, r) in &stopping {
        if r.systemd {
            unsafe { libc::kill(r.pid, libc::SIGRTMIN() + 4) };
        } else {
            for pid in user_pids(&cgroup_of(id)) {
                unsafe { libc::kill(pid, libc::SIGTERM) };
            }
        }
    }
    let deadline = Instant::now() + grace;
    for (id, r) in &stopping {
        if !r.systemd {
            // Without systemd, msl's own init never exits by itself: wait for
            // the user's processes, then end the namespace.
            while !user_pids(&cgroup_of(id)).is_empty() && Instant::now() < deadline {
                std::thread::sleep(Duration::from_millis(50));
            }
            if user_pids(&cgroup_of(id)).is_empty() {
                unsafe { libc::kill(r.pid, libc::SIGKILL) };
            }
        }
        if !wait_exited(r, deadline.saturating_duration_since(Instant::now())) {
            sys::log(&format!("distro {id} did not stop within {:.1}s; killing it", grace.as_secs_f64()));
            // Killing the pidns init tears down the whole namespace.
            unsafe { libc::kill(r.pid, libc::SIGKILL) };
            wait_exited(r, Duration::from_secs(10));
        }
        self::stopping().lock().unwrap().remove(id);
    }
}

/// Wait for a stop of `id` that another caller started (e.g. the idle monitor).
fn wait_stopped(id: &str) {
    let r = stopping().lock().unwrap().get(id).cloned();
    if let Some(r) = r {
        wait_exited(&r, STOP_GRACE + Duration::from_secs(15));
    }
}

/// Mount a distro's own disk (AttachDisk).
fn attach_blocking(req: pb::AttachDiskRequest) -> Result<pb::AttachDiskReply, Status> {
    check_id(&req.id)?;
    let _g = mount_lock().lock().unwrap();
    if running().lock().unwrap().contains_key(&req.id) || stopping().lock().unwrap().contains_key(&req.id) {
        return Err(Status::failed_precondition("the distribution is running"));
    }
    let serial_dev = || {
        find_by_serial(Path::new(SYS_BLOCK), &req.serial).ok_or_else(|| Status::not_found(format!("no disk with serial {}", req.serial)))
    };
    if let Some(d) = attached().lock().unwrap().get(&req.id).cloned() {
        let same = if req.mac_path.is_empty() { serial_dev()? == d } else { d.starts_with("loop") };
        return if same {
            Ok(pb::AttachDiskReply { device: format!("/dev/{d}"), repaired: String::new() })
        } else {
            Err(Status::failed_precondition(format!("the distribution's disk is already attached as /dev/{d}")))
        };
    }
    // The disk attached at boot, or (added since) a loop device over the image
    // on the Mac share. The loop device goes away with its last user: keep
    // `_loop` open until the filesystem is mounted.
    let (name, _loop) = if req.mac_path.is_empty() {
        (serial_dev()?, None)
    } else {
        let file = mac_file(&req.mac_path)?;
        let (n, f) = sys::loop_attach(&file).map_err(|e| Status::failed_precondition(format!("loop device for {}: {e}", file.display())))?;
        (n, Some(f))
    };
    let dev = format!("/dev/{name}");
    if attached().lock().unwrap().values().any(|d| *d == name) {
        return Err(Status::failed_precondition(format!("{dev} is in use by another distribution")));
    }
    // Drop any blocks cached from an earlier mount: the file may have been
    // replaced on the Mac since (an import of a disk image).
    let sb = {
        let f = sys::open_excl(&dev).map_err(|e| Status::failed_precondition(format!("{dev}: {e}")))?;
        sys::blkflsbuf(&f).map_err(|e| status(format!("{dev}: {e}")))?;
        read_superblock(&f).map_err(|e| Status::invalid_argument(format!("{dev}: {e}")))?
    };
    if !sb.uuid.eq_ignore_ascii_case(&req.uuid) {
        return Err(Status::failed_precondition(format!("{dev} holds filesystem {}, not {}", sb.uuid, req.uuid)));
    }
    let run = |tool: &str, args: &[&str]| -> Result<i32, String> {
        let (code, out) = run_tool(tool, args)?;
        sys::log(&format!("{tool} {}: exit {code}\n{}", args.join(" "), out.trim()));
        Ok(code)
    };
    let mut repaired = Vec::new();
    if sb.errors || !sb.clean || sb.error_count > 0 {
        // e2fsck -f -p: 0 clean, 1 fixed, 2 fixed (reboot advised: not for us).
        match run("/bin/e2fsck", &["-f", "-p", &dev]) {
            Ok(0) => repaired.push("checked".to_string()),
            Ok(c @ (1 | 2)) => repaired.push(format!("e2fsck fixed errors (exit {c})")),
            Ok(c) => {
                return Err(Status::failed_precondition(format!(
                    "e2fsck found errors it can't fix safely (exit {c}); repair the disk image with e2fsck -f"
                )));
            }
            Err(e) => return Err(status(e)),
        }
    }
    if req.size_bytes >= sb.size + (64 << 20) {
        repaired.push(grow_fs(&dev, sb.size, req.size_bytes, &run).map_err(Status::failed_precondition)?);
    }
    let dir = own_root(&req.id);
    sys::mount_fs(&dev, &dir, "ext4", MsFlags::MS_NOATIME, None).map_err(status)?;
    // Never propagate into (or out of) distro namespaces.
    if let Err(e) = nix::mount::mount(None::<&str>, &dir, None::<&str>, MsFlags::MS_PRIVATE, None::<&str>) {
        let _ = nix::mount::umount2(&dir, nix::mount::MntFlags::empty());
        return Err(status(e));
    }
    attached().lock().unwrap().insert(req.id.clone(), name);
    drop(_g);
    let want = view_want().lock().unwrap().clone();
    set_view(&want);
    sys::log(&format!("disk {dev} attached for {}{}", req.id, if repaired.is_empty() { String::new() } else { format!(" ({})", repaired.join("; ")) }));
    Ok(pb::AttachDiskReply { device: dev, repaired: repaired.join("; ") })
}

/// A writer that counts the bytes it passes on (an export's length, see pb::Exited).
struct Counter {
    inner: std::fs::File,
    n: Arc<AtomicU64>,
}

impl std::io::Write for Counter {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        let k = self.inner.write(buf)?;
        self.n.fetch_add(k as u64, Ordering::Release);
        Ok(k)
    }
    fn flush(&mut self) -> std::io::Result<()> {
        self.inner.flush()
    }
}

/// A dial-back stream from a request, if it has a usable one.
fn req_stream(s: Option<pb::HostStream>) -> Option<pb::HostStream> {
    s.filter(|s| !s.token.is_empty() && s.port != 0)
}

/// A Mac path as seen through the virtiofs share of the Mac's `/`.
fn mac_file(mac_path: &str) -> Result<PathBuf, Status> {
    let p = Path::new(mac_path);
    if !p.is_absolute() || p.components().any(|c| matches!(c, std::path::Component::ParentDir)) {
        return Err(Status::invalid_argument(format!("not an absolute path: {mac_path}")));
    }
    Ok(Path::new("/mnt/mac").join(p.strip_prefix("/").unwrap_or(p)))
}

/// Stop a distro and unmount its own disk (DetachDisk). Returns once nothing in
/// the VM holds the device (a loop device is then released), so the host can
/// copy, move or delete the file.
fn detach_blocking(id: &str) -> Result<(), Status> {
    check_id(id)?;
    stop_blocking(id);
    wait_stopped(id);
    let _g = mount_lock().lock().unwrap();
    let Some(name) = attached().lock().unwrap().get(id).cloned() else { return Ok(()) };
    set_view(&view_without(id)); // its bind pins the filesystem
    let dir = own_root(id);
    nix::unistd::sync();
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        match nix::mount::umount2(&dir, nix::mount::MntFlags::empty()) {
            Ok(()) | Err(nix::errno::Errno::EINVAL) => break, // EINVAL: not mounted
            Err(nix::errno::Errno::EBUSY) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(100)),
            Err(e) => {
                drop(_g);
                set_view(&view_want().lock().unwrap().clone());
                return Err(Status::failed_precondition(format!("unmount {}: {e}", dir.display())));
            }
        }
    }
    // The filesystem can outlive the mount (a lazily detached bind still in use,
    // a distro namespace being set up): wait until the device is free.
    let dev = format!("/dev/{name}");
    let deadline = Instant::now() + Duration::from_secs(10);
    let f = loop {
        match sys::open_excl(&dev) {
            Ok(f) => break f,
            Err(e) if e.raw_os_error() == Some(libc::EBUSY) && Instant::now() < deadline => std::thread::sleep(Duration::from_millis(100)),
            Err(e) => return Err(Status::failed_precondition(format!("{dev} is still in use: {e}"))),
        }
    };
    let _ = f.sync_all();
    let _ = sys::blkflsbuf(&f);
    drop(f);
    let _ = std::fs::remove_dir(&dir);
    let _ = std::fs::remove_dir(Path::new(DISKS).join(id));
    attached().lock().unwrap().remove(id);
    sys::log(&format!("disk {dev} detached from {id}"));
    Ok(())
}

/// Copy a distro kept on data.img onto its attached disk, then delete it from
/// data.img (MigrateDistro).
fn migrate_blocking(id: &str) -> Result<pb::MigrateDistroReply, Status> {
    check_id(id)?;
    stop_blocking(id);
    wait_stopped(id);
    let old = legacy_dir(id);
    let (src, dest) = (old.join("rootfs"), own_root(id));
    if !attached().lock().unwrap().contains_key(id) {
        return Err(Status::failed_precondition("the distribution's disk is not attached"));
    }
    if !src.is_dir() {
        return Err(Status::not_found("distribution root filesystem not found on the shared disk"));
    }
    if !is_empty_root(&dest) {
        return Err(Status::already_exists("the distribution's disk is not empty"));
    }
    set_view(&view_without(id));
    // The same tar path as export + import, through a pipe.
    let (rd, wr) = std::io::pipe().map_err(status)?;
    let from = src.clone();
    let packer = std::thread::spawn(move || archive::pack(&from, pb::ExportFormat::Tar, wr));
    let unpacked = archive::unpack(rd, &dest);
    let packed = packer.join().unwrap_or_else(|_| Err("tar writer panicked".into()));
    let res = match (packed, unpacked) {
        (Ok(_), Ok(n)) => {
            nix::unistd::sync();
            std::fs::remove_dir_all(&old).map_err(status)?;
            nix::unistd::sync();
            Ok(pb::MigrateDistroReply { entries: n })
        }
        (Err(e), _) | (_, Err(e)) => {
            clear_root(&dest);
            Err(Status::internal(format!("copy to the distribution's disk: {e}")))
        }
    };
    set_view(&view_want().lock().unwrap().clone());
    res
}

fn wait_exited(r: &Running, timeout: Duration) -> bool {
    let (lock, cv) = &*r.exited;
    let guard = lock.lock().unwrap();
    *cv.wait_timeout_while(guard, timeout, |done| !*done).unwrap().0
}

/// The distro's own processes: everything in its cgroup except msl's
/// (msl-distro-init and the agent run this same binary).
fn user_pids(dir: &Path) -> Vec<i32> {
    use std::os::unix::fs::MetadataExt;
    let me = std::fs::metadata("/proc/self/exe").map(|m| (m.dev(), m.ino())).ok();
    cgroup_pids(dir)
        .into_iter()
        .filter(|pid| std::fs::metadata(format!("/proc/{pid}/exe")).map(|m| (m.dev(), m.ino())).ok() != me)
        .collect()
}

/// Every process in a cgroup subtree.
fn cgroup_pids(dir: &Path) -> Vec<i32> {
    let mut pids: Vec<i32> = std::fs::read_to_string(dir.join("cgroup.procs"))
        .unwrap_or_default()
        .lines()
        .filter_map(|l| l.trim().parse().ok())
        .collect();
    if let Ok(entries) = std::fs::read_dir(dir) {
        for e in entries.flatten() {
            if e.file_type().map(|t| t.is_dir()).unwrap_or(false) {
                pids.extend(cgroup_pids(&e.path()));
            }
        }
    }
    pids
}

type EventStream<T> = Pin<Box<dyn futures_util::Stream<Item = Result<T, Status>> + Send>>;

struct MiniInitService {
    ports: tokio::sync::watch::Receiver<Vec<u32>>,
}

async fn blocking<T: Send + 'static>(f: impl FnOnce() -> Result<T, Status> + Send + 'static) -> Result<T, Status> {
    tokio::task::spawn_blocking(f).await.map_err(status)?
}

#[tonic::async_trait]
impl MiniInit for MiniInitService {
    async fn ping(&self, _: Request<pb::Empty>) -> Result<Response<pb::PingReply>, Status> {
        let up = std::fs::read_to_string("/proc/uptime").unwrap_or_default();
        let (total, free) = nix::sys::statvfs::statvfs(DATA)
            .map(|s| (s.blocks() as u64 * s.fragment_size() as u64, s.blocks_available() as u64 * s.fragment_size() as u64))
            .unwrap_or((0, 0));
        Ok(Response::new(pb::PingReply {
            kernel_release: std::fs::read_to_string("/proc/sys/kernel/osrelease").unwrap_or_default().trim().to_string(),
            uptime_seconds: up.split_whitespace().next().and_then(|v| v.parse().ok()).unwrap_or(0.0),
            data_total_bytes: total,
            data_free_bytes: free,
            data_grow: GROW.get().cloned().unwrap_or_default(),
        }))
    }

    type ImportDistroStream = EventStream<pb::ImportDistroEvent>;

    async fn import_distro(&self, req: Request<pb::ImportDistroRequest>) -> Result<Response<Self::ImportDistroStream>, Status> {
        use pb::import_distro_event::Event;
        let req_import = req.into_inner();
        let id = req_import.id.clone();
        let dir = distro_dir(&id)?;
        // An own disk is attached (its mount point exists) before the import.
        let own = attached().lock().unwrap().contains_key(&id);
        if if own { !is_empty_root(&dir.join("rootfs")) } else { dir.exists() } {
            return Err(Status::already_exists("distribution directory already exists"));
        }
        let stream = req_stream(req_import.stream).ok_or_else(|| Status::invalid_argument("no stream"))?;
        let (tx, rx) = tokio::sync::mpsc::channel(2);
        tokio::spawn(async move {
            let res = async {
                let conn = crate::rpc::dial_host(stream.port, &stream.token).await.map_err(status)?;
                let rootfs = dir.join("rootfs");
                let d2 = dir.clone();
                blocking(move || {
                    let n = archive::unpack(conn, &rootfs).map_err(|e| {
                        if own { clear_root(&rootfs) } else { let _ = std::fs::remove_dir_all(&d2); }
                        Status::invalid_argument(e)
                    })?;
                    nix::unistd::sync();
                    let conf = config::distribution_conf(&rootfs.to_string_lossy());
                    Ok(pb::ImportDistroDone { entries: n, distribution_conf: Some(conf) })
                })
                .await
            }
            .await;
            let _ = tx.send(res.map(|d| pb::ImportDistroEvent { event: Some(Event::Done(d)) })).await;
        });
        Ok(Response::new(Box::pin(ReceiverStream::new(rx))))
    }

    type ExportDistroStream = EventStream<pb::ExportDistroEvent>;

    async fn export_distro(&self, req: Request<pb::ExportDistroRequest>) -> Result<Response<Self::ExportDistroStream>, Status> {
        use pb::export_distro_event::Event;
        let req = req.into_inner();
        let rootfs = distro_dir(&req.id)?.join("rootfs");
        if !rootfs.is_dir() {
            return Err(Status::not_found("distribution root filesystem not found"));
        }
        let format = pb::ExportFormat::try_from(req.format).unwrap_or(pb::ExportFormat::Tar);
        let stream = req_stream(req.stream).ok_or_else(|| Status::invalid_argument("no stream"))?;
        let (tx, rx) = tokio::sync::mpsc::channel(2);
        tokio::spawn(async move {
            let res = async {
                let conn = crate::rpc::dial_host(stream.port, &stream.token).await.map_err(status)?;
                blocking(move || {
                    let counter = Counter { inner: conn.try_clone().map_err(status)?, n: Arc::new(AtomicU64::new(0)) };
                    let bytes = counter.n.clone();
                    let n = archive::pack(&rootfs, format, counter).map_err(status)?;
                    // msl reads exactly `bytes`, then closes; close ours only after that.
                    std::thread::spawn(move || crate::rpc::wait_for_host_close(conn));
                    Ok(pb::ExportDistroDone { entries: n, bytes: bytes.load(Ordering::Acquire) })
                })
                .await
            }
            .await;
            let _ = tx.send(res.map(|d| pb::ExportDistroEvent { event: Some(Event::Done(d)) })).await;
        });
        Ok(Response::new(Box::pin(ReceiverStream::new(rx))))
    }

    type OpenStreamStream = EventStream<pb::OpenStreamEvent>;

    async fn open_stream(&self, req: Request<pb::OpenStreamRequest>) -> Result<Response<Self::OpenStreamStream>, Status> {
        use pb::open_stream_event::Event;
        let req = req.into_inner();
        check_id(&req.distro_id)?;
        let to_host = req_stream(req.stream).ok_or_else(|| Status::invalid_argument("no stream"))?;
        let from_host = req_stream(req.from_host).ok_or_else(|| Status::invalid_argument("no stream from the host"))?;
        // The target first, so a refusal reaches the host as an error.
        let (uid, id, path, port) = (req.uid, req.distro_id.clone(), req.unix_path.clone(), req.tcp_port);
        let target: std::fs::File = blocking(move || {
            use std::os::fd::OwnedFd;
            if !path.is_empty() {
                let s = crate::connect::open_unix(uid, &id, &path).map_err(Status::permission_denied)?;
                return Ok(std::fs::File::from(OwnedFd::from(s)));
            }
            let port = u16::try_from(port).ok().filter(|p| *p > 0).ok_or_else(|| Status::invalid_argument("no target"))?;
            let s = std::net::TcpStream::connect(("127.0.0.1", port))
                .or_else(|_| std::net::TcpStream::connect(("::1", port)))
                .map_err(|e| Status::unavailable(format!("localhost:{port}: {e}")))?;
            let _ = s.set_nodelay(true);
            Ok(std::fs::File::from(OwnedFd::from(s)))
        })
        .await?;
        let (out, inp) = tokio::try_join!(
            crate::rpc::dial_host(to_host.port, &to_host.token),
            crate::rpc::dial_host(from_host.port, &from_host.token)
        )
        .map_err(status)?;
        let (done_tx, done_rx) = tokio::sync::oneshot::channel();
        crate::rpc::relay(target, inp, out, done_tx).map_err(status)?;
        let (tx, rx) = tokio::sync::mpsc::channel(2);
        tx.send(Ok(pb::OpenStreamEvent { event: Some(Event::Opened(pb::Empty {})) })).await.map_err(status)?;
        tokio::spawn(async move {
            if let Ok(n) = done_rx.await {
                let _ = tx.send(Ok(pb::OpenStreamEvent { event: Some(Event::Done(n)) })).await;
            }
        });
        Ok(Response::new(Box::pin(ReceiverStream::new(rx))))
    }

    async fn delete_distro(&self, req: Request<pb::DistroRef>) -> Result<Response<pb::Empty>, Status> {
        let id = req.into_inner().id;
        check_id(&id)?;
        blocking(move || {
            if attached().lock().unwrap().contains_key(&id) {
                // Its own disk: unmount it; msld deletes the image.
                detach_blocking(&id)?;
            } else {
                stop_blocking(&id);
                wait_stopped(&id);
                // Drop it from the ~/.msl/distros view first (its bind mount pins the rootfs).
                set_view(&view_without(&id));
            }
            let legacy = legacy_dir(&id);
            if legacy.exists() {
                std::fs::remove_dir_all(&legacy).map_err(status)?;
            }
            nix::unistd::sync();
            Ok(())
        })
        .await?;
        Ok(Response::new(pb::Empty {}))
    }

    async fn start_distro(&self, req: Request<pb::StartDistroRequest>) -> Result<Response<pb::StartDistroReply>, Status> {
        let req = req.into_inner();
        distro_dir(&req.id)?;
        blocking(move || start_blocking(req)).await.map(Response::new)
    }

    async fn stop_distro(&self, req: Request<pb::DistroRef>) -> Result<Response<pb::Empty>, Status> {
        let id = req.into_inner().id;
        blocking(move || {
            stop_blocking(&id);
            Ok(())
        })
        .await?;
        Ok(Response::new(pb::Empty {}))
    }

    async fn list_running(&self, _: Request<pb::Empty>) -> Result<Response<pb::ListRunningReply>, Status> {
        let ids = running().lock().unwrap().keys().cloned().collect();
        Ok(Response::new(pb::ListRunningReply { ids }))
    }

    type WatchPortsStream = EventStream<pb::ListeningPorts>;

    async fn watch_ports(&self, _: Request<pb::Empty>) -> Result<Response<Self::WatchPortsStream>, Status> {
        let mut rx = self.ports.clone();
        let (tx, out) = tokio::sync::mpsc::channel(4);
        tokio::spawn(async move {
            loop {
                let ports = rx.borrow_and_update().clone();
                if tx.send(Ok(pb::ListeningPorts { ports })).await.is_err() {
                    break;
                }
                if rx.changed().await.is_err() {
                    break;
                }
            }
        });
        Ok(Response::new(Box::pin(ReceiverStream::new(out))))
    }

    async fn list_disks(&self, _: Request<pb::Empty>) -> Result<Response<pb::DiskList>, Status> {
        Ok(Response::new(pb::DiskList { names: disks() }))
    }

    async fn mount_disk(&self, req: Request<pb::MountDiskRequest>) -> Result<Response<pb::MountDiskReply>, Status> {
        let r = req.into_inner();
        if r.name.is_empty() || r.name == "." || r.name == ".." || r.name.contains('/') {
            return Err(Status::invalid_argument("The mount name cannot be empty, '.', '..', or contain '/'. Please retry with a valid mount name."));
        }
        blocking(move || {
            // Wait for the hot-plugged disk to appear.
            let deadline = Instant::now() + Duration::from_secs(20);
            let disk = loop {
                if let Some(d) = disks().into_iter().find(|d| !r.before.contains(d)) {
                    break d.split(':').next().unwrap_or_default().to_string();
                }
                if Instant::now() > deadline {
                    return Err(Status::deadline_exceeded("the attached disk did not appear in the VM"));
                }
                std::thread::sleep(Duration::from_millis(100));
            };
            let device = if r.partition > 0 { format!("/dev/{disk}{}", r.partition) } else { format!("/dev/{disk}") };
            let deadline = Instant::now() + Duration::from_secs(10);
            while !Path::new(&device).exists() {
                if Instant::now() > deadline {
                    return Err(Status::not_found(format!("{device} does not exist")));
                }
                std::thread::sleep(Duration::from_millis(50));
            }
            if r.bare {
                return Ok(pb::MountDiskReply { device, mount_point: String::new() });
            }
            let target = format!("/mnt/msl/{}", r.name);
            if Path::new(&target).exists() {
                return Err(Status::already_exists("A disk with that name is already mounted; please unmount the disk or choose a new name and try again."));
            }
            sys::mkdir_p(&target).map_err(status)?;
            let fstype = if r.fstype.is_empty() { "ext4".to_string() } else { r.fstype.clone() };
            let data = if r.options.is_empty() { None } else { Some(r.options.as_str()) };
            if let Err(e) = nix::mount::mount(Some(device.as_str()), target.as_str(), Some(fstype.as_str()), MsFlags::empty(), data) {
                let _ = std::fs::remove_dir(&target);
                return Err(Status::failed_precondition(format!("{e}")));
            }
            Ok(pb::MountDiskReply { device, mount_point: target })
        })
        .await
        .map(Response::new)
    }

    async fn unmount_disk(&self, req: Request<pb::UnmountDiskRequest>) -> Result<Response<pb::Empty>, Status> {
        let name = req.into_inner().name;
        blocking(move || {
            let target = format!("/mnt/msl/{name}");
            if !name.is_empty() && !name.contains('/') && Path::new(&target).exists() {
                nix::unistd::sync();
                let _ = nix::mount::umount2(target.as_str(), nix::mount::MntFlags::MNT_DETACH);
                let _ = std::fs::remove_dir(&target);
            }
            Ok(())
        })
        .await?;
        Ok(Response::new(pb::Empty {}))
    }

    async fn compact_disk(&self, _: Request<pb::Empty>) -> Result<Response<pb::CompactDiskReply>, Status> {
        let trimmed = blocking(|| {
            nix::unistd::sync();
            let mut n = sys::fstrim(DATA).map_err(status)?;
            let ids: Vec<String> = attached().lock().unwrap().keys().cloned().collect();
            for id in ids {
                n += sys::fstrim(&own_root(&id).to_string_lossy()).unwrap_or(0);
            }
            Ok(n)
        })
        .await?;
        Ok(Response::new(pb::CompactDiskReply { trimmed_bytes: trimmed }))
    }

    async fn set_file_view(&self, req: Request<pb::FileViewRequest>) -> Result<Response<pb::Empty>, Status> {
        let want = req.into_inner().distros;
        blocking(move || {
            *view_want().lock().unwrap() = want.clone();
            set_view(&want);
            Ok(())
        })
        .await?;
        Ok(Response::new(pb::Empty {}))
    }

    async fn attach_disk(&self, req: Request<pb::AttachDiskRequest>) -> Result<Response<pb::AttachDiskReply>, Status> {
        let req = req.into_inner();
        blocking(move || attach_blocking(req)).await.map(Response::new)
    }

    async fn detach_disk(&self, req: Request<pb::DistroRef>) -> Result<Response<pb::Empty>, Status> {
        let id = req.into_inner().id;
        blocking(move || detach_blocking(&id)).await?;
        Ok(Response::new(pb::Empty {}))
    }

    async fn migrate_distro(&self, req: Request<pb::DistroRef>) -> Result<Response<pb::MigrateDistroReply>, Status> {
        let id = req.into_inner().id;
        blocking(move || migrate_blocking(&id)).await.map(Response::new)
    }

    async fn distro_conf(&self, req: Request<pb::DistroRef>) -> Result<Response<pb::DistributionConf>, Status> {
        let rootfs = distro_dir(&req.into_inner().id)?.join("rootfs");
        if !rootfs.is_dir() {
            return Err(Status::not_found("distribution root filesystem not found"));
        }
        Ok(Response::new(config::distribution_conf(&rootfs.to_string_lossy())))
    }

    async fn shutdown(&self, req: Request<pb::ShutdownRequest>) -> Result<Response<pb::Empty>, Status> {
        let grace = match req.into_inner().grace_ms {
            0 => STOP_GRACE,
            ms => Duration::from_millis(ms as u64),
        };
        blocking(move || {
            let ids: Vec<String> = running().lock().unwrap().keys().cloned().collect();
            stop_many(&ids, grace);
            nix::unistd::sync();
            // Own disks: trim, then unmount (ext4 commits the journal and marks
            // them clean); msld flushes each image when the VM has stopped.
            let own: Vec<String> = attached().lock().unwrap().keys().cloned().collect();
            for id in own {
                let _ = sys::fstrim(&own_root(&id).to_string_lossy());
                if let Err(e) = detach_blocking(&id) {
                    sys::log(&format!("disk of {id}: {}", e.message()));
                }
            }
            // Keep data.img compact: hand freed blocks back to the Mac.
            let _ = sys::fstrim(DATA);
            // Read-only remount: ext4 commits the journal and marks the filesystem
            // clean, so the next boot doesn't replay it. (A sync alone leaves
            // needs_recovery set.) The per-distro binds share the superblock.
            match nix::mount::mount(None::<&str>, DATA, None::<&str>, MsFlags::MS_REMOUNT | MsFlags::MS_RDONLY, None::<&str>) {
                Ok(()) => sys::log("data disk: clean (read-only) for power-off"),
                Err(e) => sys::log(&format!("data disk: read-only remount failed: {e}; synced only")),
            }
            Ok(())
        })
        .await?;
        std::thread::spawn(|| {
            std::thread::sleep(Duration::from_millis(100));
            nix::unistd::sync();
            let _ = nix::sys::reboot::reboot(nix::sys::reboot::RebootMode::RB_POWER_OFF);
        });
        Ok(Response::new(pb::Empty {}))
    }
}

#[cfg(test)]
#[path = "../../tests/guest/miniinit.rs"]
mod tests;
