use super::*;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;

const AS_NOBODY: &str = "MSL_TEST_NFS_LIST_AS_NOBODY";

/// Lists a directory the caller may read but not search, so `readdir` returns
/// every name and `stat` on each one fails with EACCES.
fn list_unsearchable(dir: &Path) {
    let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    let mut map = FSMap::new(dir.to_path_buf());
    rt.block_on(map.refresh_dir_list(0)).expect("listing fails instead of skipping the entries");
    assert_eq!(map.id_to_path[&0].children, Some(BTreeSet::new()));
}

#[test]
fn listing_skips_entries_that_cannot_be_statted() {
    if let Some(dir) = std::env::var_os(AS_NOBODY) {
        // Root can stat anything, so the re-run drops to nobody first.
        assert_eq!(unsafe { libc::setuid(65534) }, 0);
        return list_unsearchable(Path::new(&dir));
    }
    let outer = std::env::temp_dir().join(format!("msl-nfs-test-{}", std::process::id()));
    let dir = outer.join("d");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::set_permissions(&outer, std::fs::Permissions::from_mode(0o755)).unwrap();
    std::fs::write(dir.join("a"), b"").unwrap();
    std::fs::write(dir.join("b"), b"").unwrap();
    std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o444)).unwrap();

    let result = if unsafe { libc::geteuid() } == 0 {
        let out = std::process::Command::new(std::env::current_exe().unwrap())
            .args(["listing_skips_entries_that_cannot_be_statted", "--nocapture"])
            .env(AS_NOBODY, &dir)
            .output()
            .unwrap();
        if out.status.success() { Ok(()) } else { Err(String::from_utf8_lossy(&out.stderr).into_owned()) }
    } else {
        std::panic::catch_unwind(|| list_unsearchable(&dir)).map_err(|_| "listing panicked".to_string())
    };

    std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o755)).unwrap();
    std::fs::remove_dir_all(&outer).unwrap();
    result.unwrap();
}
