// SPDX-License-Identifier: Apache-2.0
//! The ~/MSL NFS filesystem: `MirrorFS` plus an in-memory store for macOS
//! metadata files.
//!
//! macOS writes `.DS_Store` into folders Finder shows, and stores extended
//! attributes (quarantine flags, tags, resource forks) as AppleDouble `._name`
//! files, because NFSv3 has no named attributes. Refusing them breaks Finder
//! copies (`ditto`/copyfile fail); writing them litters Linux filesystems. So
//! they live here, in memory: macOS can create, read and delete them, Linux
//! never sees them, and they vanish when the VM stops.

use crate::nfs::{MirrorFS, is_mac_metadata};
use async_trait::async_trait;
use nfsserve::nfs::*;
use nfsserve::vfs::{NFSFileSystem, ReadDirResult, VFSCapabilities};
use std::collections::HashMap;
use tokio::sync::Mutex;

/// File ids at and above this are in-memory metadata files.
const VBASE: u64 = 1 << 62;
const MAX_FILE: usize = 16 << 20;
const MAX_TOTAL: usize = 256 << 20;

struct VFile {
    dir: fileid3,
    name: Vec<u8>,
    data: Vec<u8>,
    mode: u32,
    mtime: nfstime3,
}

#[derive(Default)]
struct Store {
    next: u64,
    files: HashMap<u64, VFile>,
    by_name: HashMap<(fileid3, Vec<u8>), u64>,
    total: usize,
}

pub struct MslFS {
    inner: MirrorFS,
    store: Mutex<Store>,
}

fn now() -> nfstime3 {
    let d = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default();
    nfstime3 { seconds: d.as_secs() as u32, nseconds: d.subsec_nanos() }
}

impl MslFS {
    pub fn new(inner: MirrorFS) -> Self {
        MslFS { inner, store: Mutex::new(Store { next: VBASE, ..Default::default() }) }
    }

    /// Attributes for a virtual file, borrowing owner/fsid from its directory.
    async fn attrs(&self, id: u64, f: &VFile) -> fattr3 {
        let dir = self.inner.getattr(f.dir).await.ok();
        fattr3 {
            ftype: ftype3::NF3REG,
            mode: f.mode,
            nlink: 1,
            uid: dir.as_ref().map(|d| d.uid).unwrap_or(0),
            gid: dir.as_ref().map(|d| d.gid).unwrap_or(0),
            size: f.data.len() as u64,
            used: f.data.len() as u64,
            rdev: specdata3 { specdata1: 0, specdata2: 0 },
            fsid: dir.as_ref().map(|d| d.fsid).unwrap_or(0),
            fileid: id,
            atime: f.mtime,
            mtime: f.mtime,
            ctime: f.mtime,
        }
    }

    async fn vattrs(&self, id: u64) -> Result<fattr3, nfsstat3> {
        let st = self.store.lock().await;
        let f = st.files.get(&id).ok_or(nfsstat3::NFS3ERR_STALE)?;
        let snapshot = VFile { dir: f.dir, name: f.name.clone(), data: Vec::new(), mode: f.mode, mtime: f.mtime };
        let size = f.data.len();
        drop(st);
        let mut a = self.attrs(id, &snapshot).await;
        a.size = size as u64;
        a.used = size as u64;
        Ok(a)
    }

    /// Create (or truncate) a metadata file in `dir`.
    async fn vcreate(&self, dir: fileid3, name: &[u8], mode: u32, exclusive: bool) -> Result<u64, nfsstat3> {
        // The directory must exist in the real filesystem.
        self.inner.getattr(dir).await?;
        let mut st = self.store.lock().await;
        if let Some(&id) = st.by_name.get(&(dir, name.to_vec())) {
            if exclusive {
                return Err(nfsstat3::NFS3ERR_EXIST);
            }
            let f = st.files.get_mut(&id).unwrap();
            let freed = f.data.len();
            f.data.clear();
            f.mtime = now();
            st.total -= freed;
            return Ok(id);
        }
        let id = st.next;
        st.next += 1;
        st.files.insert(id, VFile { dir, name: name.to_vec(), data: Vec::new(), mode, mtime: now() });
        st.by_name.insert((dir, name.to_vec()), id);
        Ok(id)
    }
}

fn mode_of(attr: &sattr3) -> u32 {
    match attr.mode {
        set_mode3::mode(m) => m,
        set_mode3::Void => 0o644,
    }
}

#[async_trait]
impl NFSFileSystem for MslFS {
    fn root_dir(&self) -> fileid3 {
        self.inner.root_dir()
    }

    fn capabilities(&self) -> VFSCapabilities {
        self.inner.capabilities()
    }

    async fn lookup(&self, dirid: fileid3, filename: &filename3) -> Result<fileid3, nfsstat3> {
        if is_mac_metadata(filename) {
            let st = self.store.lock().await;
            return st.by_name.get(&(dirid, filename.to_vec())).copied().ok_or(nfsstat3::NFS3ERR_NOENT);
        }
        self.inner.lookup(dirid, filename).await
    }

    async fn getattr(&self, id: fileid3) -> Result<fattr3, nfsstat3> {
        if id >= VBASE { self.vattrs(id).await } else { self.inner.getattr(id).await }
    }

    async fn setattr(&self, id: fileid3, setattr: sattr3) -> Result<fattr3, nfsstat3> {
        if id < VBASE {
            return self.inner.setattr(id, setattr).await;
        }
        {
            let mut st = self.store.lock().await;
            let st = &mut *st;
            let f = st.files.get_mut(&id).ok_or(nfsstat3::NFS3ERR_STALE)?;
            if let set_size3::size(n) = setattr.size {
                let n = n as usize;
                if n > MAX_FILE || st.total + n.saturating_sub(f.data.len()) > MAX_TOTAL {
                    return Err(nfsstat3::NFS3ERR_NOSPC);
                }
                st.total = st.total - f.data.len() + n;
                f.data.resize(n, 0);
            }
            if let set_mode3::mode(m) = setattr.mode {
                f.mode = m;
            }
            f.mtime = match setattr.mtime {
                set_mtime::SET_TO_CLIENT_TIME(t) => t,
                _ => now(),
            };
        }
        self.vattrs(id).await
    }

    async fn read(&self, id: fileid3, offset: u64, count: u32) -> Result<(Vec<u8>, bool), nfsstat3> {
        if id < VBASE {
            return self.inner.read(id, offset, count).await;
        }
        let st = self.store.lock().await;
        let f = st.files.get(&id).ok_or(nfsstat3::NFS3ERR_STALE)?;
        let start = (offset as usize).min(f.data.len());
        let end = (start + count as usize).min(f.data.len());
        Ok((f.data[start..end].to_vec(), end >= f.data.len()))
    }

    async fn write(&self, id: fileid3, offset: u64, data: &[u8]) -> Result<fattr3, nfsstat3> {
        if id < VBASE {
            return self.inner.write(id, offset, data).await;
        }
        {
            let mut st = self.store.lock().await;
            let st = &mut *st;
            let f = st.files.get_mut(&id).ok_or(nfsstat3::NFS3ERR_STALE)?;
            let end = offset as usize + data.len();
            let grow = end.saturating_sub(f.data.len());
            if end > MAX_FILE || st.total + grow > MAX_TOTAL {
                return Err(nfsstat3::NFS3ERR_NOSPC);
            }
            if end > f.data.len() {
                f.data.resize(end, 0);
            }
            f.data[offset as usize..end].copy_from_slice(data);
            f.mtime = now();
            st.total += grow;
        }
        self.vattrs(id).await
    }

    async fn create(&self, dirid: fileid3, filename: &filename3, attr: sattr3) -> Result<(fileid3, fattr3), nfsstat3> {
        if is_mac_metadata(filename) {
            let id = self.vcreate(dirid, filename, mode_of(&attr), false).await?;
            return Ok((id, self.vattrs(id).await?));
        }
        self.inner.create(dirid, filename, attr).await
    }

    async fn create_exclusive(&self, dirid: fileid3, filename: &filename3) -> Result<fileid3, nfsstat3> {
        if is_mac_metadata(filename) {
            return self.vcreate(dirid, filename, 0o644, true).await;
        }
        self.inner.create_exclusive(dirid, filename).await
    }

    async fn mkdir(&self, dirid: fileid3, dirname: &filename3) -> Result<(fileid3, fattr3), nfsstat3> {
        if is_mac_metadata(dirname) {
            return Err(nfsstat3::NFS3ERR_ACCES);
        }
        self.inner.mkdir(dirid, dirname).await
    }

    async fn remove(&self, dirid: fileid3, filename: &filename3) -> Result<(), nfsstat3> {
        if is_mac_metadata(filename) {
            let mut st = self.store.lock().await;
            let id = st.by_name.remove(&(dirid, filename.to_vec())).ok_or(nfsstat3::NFS3ERR_NOENT)?;
            if let Some(f) = st.files.remove(&id) {
                st.total -= f.data.len();
            }
            return Ok(());
        }
        self.inner.remove(dirid, filename).await
    }

    async fn rename(&self, from_dirid: fileid3, from_filename: &filename3, to_dirid: fileid3, to_filename: &filename3) -> Result<(), nfsstat3> {
        match (is_mac_metadata(from_filename), is_mac_metadata(to_filename)) {
            (false, false) => self.inner.rename(from_dirid, from_filename, to_dirid, to_filename).await,
            (true, true) => {
                let mut st = self.store.lock().await;
                let id = st.by_name.remove(&(from_dirid, from_filename.to_vec())).ok_or(nfsstat3::NFS3ERR_NOENT)?;
                if let Some(old) = st.by_name.insert((to_dirid, to_filename.to_vec()), id) {
                    if let Some(f) = st.files.remove(&old) {
                        st.total -= f.data.len();
                    }
                }
                if let Some(f) = st.files.get_mut(&id) {
                    f.dir = to_dirid;
                    f.name = to_filename.to_vec();
                }
                Ok(())
            }
            // Moving a real file to a metadata name (or back) isn't supported.
            _ => Err(nfsstat3::NFS3ERR_ACCES),
        }
    }

    async fn readdir(&self, dirid: fileid3, start_after: fileid3, max_entries: usize) -> Result<ReadDirResult, nfsstat3> {
        // Metadata files are reachable by name only; listings show Linux's view.
        self.inner.readdir(dirid, start_after, max_entries).await
    }

    async fn symlink(&self, dirid: fileid3, linkname: &filename3, symlink: &nfspath3, attr: &sattr3) -> Result<(fileid3, fattr3), nfsstat3> {
        if is_mac_metadata(linkname) {
            return Err(nfsstat3::NFS3ERR_ACCES);
        }
        self.inner.symlink(dirid, linkname, symlink, attr).await
    }

    async fn readlink(&self, id: fileid3) -> Result<nfspath3, nfsstat3> {
        if id >= VBASE {
            return Err(nfsstat3::NFS3ERR_INVAL);
        }
        self.inner.readlink(id).await
    }
}
