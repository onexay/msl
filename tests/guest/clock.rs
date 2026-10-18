use super::*;

#[test]
fn corrects_large_offsets_in_both_directions() {
    let now = libc::timespec { tv_sec: 1_792_321_200, tv_nsec: 500_000_000 };
    assert!(needs_correction(now.tv_sec + 88_468, now));
    assert!(needs_correction(now.tv_sec - 88_468, now));
}

#[test]
fn tolerates_rtc_quantization() {
    for ns in [0, 1, 500_000_000, 999_999_999] {
        let now = libc::timespec { tv_sec: 1_792_321_200, tv_nsec: ns };
        assert!(!needs_correction(now.tv_sec, now));
        assert!(!needs_correction(now.tv_sec + 1, now));
    }
    let now = libc::timespec { tv_sec: 1_792_321_200, tv_nsec: 0 };
    assert!(needs_correction(now.tv_sec + 2, now));
    assert!(needs_correction(now.tv_sec - 2, now));
}

#[test]
fn rejects_missing_or_invalid_rtc() {
    let path = std::env::temp_dir().join(format!("msl-rtc-{}", std::process::id()));
    let path = path.to_str().unwrap();
    assert_eq!(rtc_seconds(path).unwrap_err().kind(), io::ErrorKind::NotFound);
    for invalid in ["", "garbage", "0", "-1", "99999999999999999999999"] {
        std::fs::write(path, invalid).unwrap();
        assert_eq!(rtc_seconds(path).unwrap_err().kind(), io::ErrorKind::InvalidData);
    }
    std::fs::write(path, "1792321200\n").unwrap();
    assert_eq!(rtc_seconds(path).unwrap(), 1_792_321_200);
    std::fs::remove_file(path).unwrap();
}
