use super::*;

#[test]
fn parses_sections_case_insensitively() {
    let ini = Ini::parse("[boot]\nsystemd=true\n# c\n[User]\nDefault = akshay\n");
    assert!(ini.bool("boot.systemd", false));
    assert_eq!(ini.get("user.default"), Some("akshay"));
    assert!(!ini.bool("boot.missing", false));
}

#[test]
fn overlay_prefers_later() {
    let a = Ini::parse("[boot]\nsystemd=true\n").overlay(Ini::parse("[boot]\nsystemd=false\n"));
    assert!(!a.bool("boot.systemd", true));
}
