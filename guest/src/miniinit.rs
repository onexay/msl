// SPDX-License-Identifier: Apache-2.0
//! Utility-VM PID 1 (the `mini_init` equivalent).
//!
//! Stage 1 (initramfs): move to a tmpfs root so child mount namespaces can
//! `pivot_root` (the initramfs `rootfs` mount can never be pivoted away).
//! Stage 2: base mounts, host shares, data disk, Rosetta binfmt, MiniInit gRPC.

use crate::pb::{self, mini_init_server::MiniInit};
use crate::rpc::{DataPort, status};
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
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};
use tokio_stream::wrappers::ReceiverStream;
use tonic::{Request, Response, Status};

const CONTROL_PORT: u32 = 1024;
const FIRST_AGENT_PORT: u32 = 2000;
const DATA: &str = "/var/lib/msl";
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

fn running() -> &'static Mutex<HashMap<String, Running>> {
    static R: OnceLock<Mutex<HashMap<String, Running>>> = OnceLock::new();
    R.get_or_init(|| Mutex::new(HashMap::new()))
}

fn distro_dir(id: &str) -> Result<PathBuf, Status> {
    // ids are GUIDs chosen by msld; refuse anything path-like.
    if id.is_empty() || !id.chars().all(|c| c.is_ascii_hexdigit() || c == '-') {
        return Err(Status::invalid_argument("bad distro id"));
    }
    Ok(Path::new(DATA).join("distros").join(id))
}

pub fn main() -> sys::Result<()> {
    if std::env::var_os("MSL_STAGE").is_none() {
        return stage1();
    }
    let t0 = Instant::now();
    base_mounts()?;
    let _ = nix::unistd::sethostname("msl");
    if let Err(e) = sys::link_up("lo") {
        sys::log(&format!("lo: {e}"));
    }
    for (tag, target) in [("mac", "/mnt/mac"), ("rosetta", "/run/rosetta")] {
        if let Err(e) = sys::mount_fs(tag, target, "virtiofs", MsFlags::empty(), None) {
            sys::log(&format!("virtiofs {tag}: {e}"));
        }
    }
    sys::mount_fs("/dev/vda", DATA, "ext4", MsFlags::MS_NOATIME, None)?;
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
    if Path::new("/bin/busybox").exists() {
        sys::mkdir_p(format!("{nr}/bin"))?;
        std::fs::copy("/bin/busybox", format!("{nr}/bin/busybox"))?;
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
    let dir = distro_dir(&req.id)?;
    let rootfs = dir.join("rootfs");
    if !rootfs.is_dir() {
        return Err(Status::not_found("distribution root filesystem not found"));
    }
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
        "nameservers": if req.dns_tunneling { vec![crate::dns::STUB_ADDR.to_string()] } else { nameservers() },
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
            Ok(l) if l.starts_with("systemd ") => systemd = l.ends_with('1'),
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
    stop_many(&[id.to_string()]);
}

/// Stop distros cleanly, all at once: a systemd distro gets SIGRTMIN+4 (systemd
/// powers off, so services and journald flush and close their files); any
/// other distro gets SIGTERM for every process in its cgroup. Whatever is still
/// running after STOP_GRACE is killed with its pid namespace.
fn stop_many(ids: &[String]) {
    let stopping: Vec<(String, Running)> = {
        let mut map = running().lock().unwrap();
        ids.iter().filter_map(|id| map.remove(id).map(|r| (id.clone(), r))).collect()
    };
    for (id, r) in &stopping {
        if r.systemd {
            unsafe { libc::kill(r.pid, libc::SIGRTMIN() + 4) };
        } else {
            for pid in user_pids(&cgroup_of(id)) {
                unsafe { libc::kill(pid, libc::SIGTERM) };
            }
        }
    }
    let deadline = Instant::now() + STOP_GRACE;
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
            sys::log(&format!("distro {id} did not stop within {}s; killing it", STOP_GRACE.as_secs()));
            // Killing the pidns init tears down the whole namespace.
            unsafe { libc::kill(r.pid, libc::SIGKILL) };
            wait_exited(r, Duration::from_secs(10));
        }
    }
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
        Ok(Response::new(pb::PingReply {
            kernel_release: std::fs::read_to_string("/proc/sys/kernel/osrelease").unwrap_or_default().trim().to_string(),
            uptime_seconds: up.split_whitespace().next().and_then(|v| v.parse().ok()).unwrap_or(0.0),
        }))
    }

    type ImportDistroStream = EventStream<pb::ImportDistroEvent>;

    async fn import_distro(&self, req: Request<pb::ImportDistroRequest>) -> Result<Response<Self::ImportDistroStream>, Status> {
        use pb::import_distro_event::Event;
        let dir = distro_dir(&req.into_inner().id)?;
        if dir.exists() {
            return Err(Status::already_exists("distribution directory already exists"));
        }
        let dp = DataPort::bind().map_err(status)?;
        let (tx, rx) = tokio::sync::mpsc::channel(2);
        tx.send(Ok(pb::ImportDistroEvent { event: Some(Event::DataPort(dp.port)) })).await.map_err(status)?;
        tokio::spawn(async move {
            let res = async {
                let conn = dp.accept().await.map_err(status)?;
                let rootfs = dir.join("rootfs");
                let d2 = dir.clone();
                blocking(move || {
                    let (source, _bridge) = crate::framed::receiver(conn).map_err(status)?;
                    let n = archive::unpack(source, &rootfs).map_err(|e| {
                        let _ = std::fs::remove_dir_all(&d2);
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
        let dp = DataPort::bind().map_err(status)?;
        let (tx, rx) = tokio::sync::mpsc::channel(2);
        tx.send(Ok(pb::ExportDistroEvent { event: Some(Event::DataPort(dp.port)) })).await.map_err(status)?;
        tokio::spawn(async move {
            let res = async {
                let conn = dp.accept().await.map_err(status)?;
                blocking(move || {
                    let (sink, bridge) = crate::framed::sender(conn).map_err(status)?;
                    let n = archive::pack(&rootfs, format, sink).map_err(status)?; // drops the sink
                    let _ = bridge.sent.recv(); // everything handed to the host
                    Ok(pb::ExportDistroDone { entries: n })
                })
                .await
            }
            .await;
            let _ = tx.send(res.map(|d| pb::ExportDistroEvent { event: Some(Event::Done(d)) })).await;
        });
        Ok(Response::new(Box::pin(ReceiverStream::new(rx))))
    }

    async fn delete_distro(&self, req: Request<pb::DistroRef>) -> Result<Response<pb::Empty>, Status> {
        let id = req.into_inner().id;
        let dir = distro_dir(&id)?;
        blocking(move || {
            stop_blocking(&id);
            // Drop it from the ~/.msl/distros view first (its bind mount pins the rootfs).
            let keep: HashMap<String, String> = view_state().lock().unwrap().iter().filter(|(_, v)| **v != id).map(|(k, v)| (k.clone(), v.clone())).collect();
            set_view(&keep);
            if dir.exists() {
                std::fs::remove_dir_all(&dir).map_err(status)?;
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
            sys::fstrim(DATA).map_err(status)
        })
        .await?;
        Ok(Response::new(pb::CompactDiskReply { trimmed_bytes: trimmed }))
    }

    async fn set_file_view(&self, req: Request<pb::FileViewRequest>) -> Result<Response<pb::Empty>, Status> {
        let want = req.into_inner().distros;
        blocking(move || {
            set_view(&want);
            Ok(())
        })
        .await?;
        Ok(Response::new(pb::Empty {}))
    }

    async fn shutdown(&self, _: Request<pb::Empty>) -> Result<Response<pb::Empty>, Status> {
        blocking(|| {
            let ids: Vec<String> = running().lock().unwrap().keys().cloned().collect();
            stop_many(&ids);
            nix::unistd::sync();
            // Keep data.img compact: hand freed blocks back to the Mac.
            let _ = sys::fstrim(DATA);
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
