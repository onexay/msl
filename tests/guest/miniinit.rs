use super::*;

#[test]
fn parses_machine_id() {
    let id = "0123456789abcdef0123456789abcdef";
    assert_eq!(parse_machine_id(&format!("console=hvc0 msl.machine_id={id} quiet\n")), Some(id));
    assert_eq!(parse_machine_id("console=hvc0"), None);
    assert_eq!(parse_machine_id("msl.machine_id=0123"), None);
    assert_eq!(parse_machine_id(&format!("msl.machine_id={}", id.to_uppercase())), None);
}

fn superblock(blocks: u32, log_block: u32, state: u16) -> Vec<u8> {
    let mut sb = vec![0u8; 1024];
    sb[0x04..0x08].copy_from_slice(&blocks.to_le_bytes());
    sb[0x18..0x1C].copy_from_slice(&log_block.to_le_bytes());
    sb[0x38..0x3A].copy_from_slice(&0xEF53u16.to_le_bytes());
    sb[0x3A..0x3C].copy_from_slice(&state.to_le_bytes());
    sb[0x68..0x78].copy_from_slice(&[0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0, 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef]);
    sb
}

#[test]
fn parses_superblock() {
    let sb = parse_superblock(&superblock(1 << 20, 2, 1)).unwrap(); // 1 Mi blocks of 4 KiB
    assert_eq!(sb.size, 4 << 30);
    assert_eq!(sb.uuid, "12345678-9abc-def0-0123-456789abcdef");
    assert!(sb.clean && !sb.errors);
    let dirty = parse_superblock(&superblock(1 << 20, 2, 2)).unwrap();
    assert!(!dirty.clean && dirty.errors);
    let mut big = superblock(0, 2, 1);
    big[0x60] = 0x80; // INCOMPAT_64BIT
    big[0x150..0x154].copy_from_slice(&1u32.to_le_bytes());
    assert_eq!(parse_superblock(&big).unwrap().size, 1u64 << 44); // 2^32 blocks of 4 KiB
    let mut bad = superblock(1, 2, 1);
    bad[0x38] = 0;
    assert!(parse_superblock(&bad).is_err());
    assert!(parse_superblock(&[0u8; 100]).is_err());
}

#[test]
fn finds_disk_by_serial() {
    let root = std::env::temp_dir().join(format!("msl-sysblock-{}", std::process::id()));
    for (dev, serial) in [("vda", "data"), ("vdb", "d0\n"), ("vdc", "d1\0\0"), ("sda", "d2")] {
        std::fs::create_dir_all(root.join(dev)).unwrap();
        std::fs::write(root.join(dev).join("serial"), serial).unwrap();
    }
    std::fs::create_dir_all(root.join("loop0")).unwrap();
    assert_eq!(find_by_serial(&root, "data").as_deref(), Some("vda"));
    assert_eq!(find_by_serial(&root, "d0").as_deref(), Some("vdb"));
    assert_eq!(find_by_serial(&root, "d1").as_deref(), Some("vdc"));
    assert_eq!(find_by_serial(&root, "d2"), None); // not a virtio disk
    assert_eq!(find_by_serial(&root, "d"), None);
    std::fs::remove_dir_all(&root).unwrap();
}

#[test]
fn maps_mac_paths_onto_the_share() {
    assert_eq!(mac_file("/Users/a/MSL/x/ext4.img").unwrap(), Path::new("/mnt/mac/Users/a/MSL/x/ext4.img"));
    assert_eq!(mac_file("/Volumes/T7/ext4.img").unwrap(), Path::new("/mnt/mac/Volumes/T7/ext4.img"));
    assert!(mac_file("relative/ext4.img").is_err());
    assert!(mac_file("/Users/a/../../etc/shadow").is_err());
}

#[test]
fn distro_dirs() {
    assert!(check_id("../etc").is_err() && check_id("").is_err());
    let id = "0f8e2a4c-1111-2222-3333-444455556666";
    assert_eq!(distro_dir(id).unwrap(), Path::new(DATA).join("distros").join(id));
    attached().lock().unwrap().insert(id.into(), "vdb".into());
    assert_eq!(distro_dir(id).unwrap(), Path::new(DISKS).join(id));
    attached().lock().unwrap().remove(id);
}
