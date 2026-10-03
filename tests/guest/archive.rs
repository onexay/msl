use super::*;

#[test]
fn roundtrip_all_formats() {
    let tmp = std::env::temp_dir().join(format!("msl-archive-{}", std::process::id()));
    let src = tmp.join("src");
    std::fs::create_dir_all(src.join("etc")).unwrap();
    std::fs::write(src.join("etc/hostname"), "x\n").unwrap();
    std::os::unix::fs::symlink("hostname", src.join("etc/link")).unwrap();
    for (i, fmt) in [ExportFormat::Tar, ExportFormat::TarGz, ExportFormat::TarXz].into_iter().enumerate() {
        let file = tmp.join(format!("out{i}"));
        pack(&src, fmt, std::fs::File::create(&file).unwrap()).unwrap();
        let dst = tmp.join(format!("dst{i}"));
        let n = unpack(std::fs::File::open(&file).unwrap(), &dst).unwrap();
        assert_eq!(n, 4, "{fmt:?}");
        assert_eq!(std::fs::read_to_string(dst.join("etc/hostname")).unwrap(), "x\n");
        assert_eq!(std::fs::read_link(dst.join("etc/link")).unwrap(), Path::new("hostname"));
    }
    let _ = std::fs::remove_dir_all(&tmp);
}
