#[test]
fn parses_locale_files() {
    let got = super::parse_locale("# comment\nLANG=C.UTF-8\nexport LC_TIME=\"en_GB.UTF-8\"\nPATH=/x\nLC_ALL=\n");
    assert_eq!(got, vec![("LANG".into(), "C.UTF-8".into()), ("LC_TIME".into(), "en_GB.UTF-8".into())]);
}
