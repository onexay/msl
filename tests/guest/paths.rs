use super::*;

#[test]
fn translate_both_ways() {
    let m = "/mnt/macos";
    assert_eq!(to_linux("/Users/a/x y", m), "/mnt/macos/Users/a/x y");
    assert_eq!(to_linux("/", m), "/mnt/macos");
    assert_eq!(to_linux("rel/p", m), "rel/p");
    let v = "/Users/a/MSL";
    assert_eq!(to_mac("/mnt/macos/Users/a", m, v, "D"), "/Users/a");
    assert_eq!(to_mac("/mnt/macos", m, v, "D"), "/");
    assert_eq!(to_mac("/mnt/macosfoo", m, v, "D"), "/Users/a/MSL/D/mnt/macosfoo");
    assert_eq!(to_mac("/home/u", m, v, "Debian"), "/Users/a/MSL/Debian/home/u");
}

#[test]
fn mslenv_flags() {
    let values = HashMap::from([
        ("A".to_string(), "plain".to_string()),
        ("P".to_string(), "/Users/a".to_string()),
        ("L".to_string(), "/x:/y".to_string()),
        ("W".to_string(), "/z".to_string()),
    ]);
    let mut env = HashMap::new();
    apply_mslenv("A:P/p:L/l:W/w:MISSING", &values, "/mnt/macos", &mut env);
    assert_eq!(env["A"], "plain");
    assert_eq!(env["P"], "/mnt/macos/Users/a");
    assert_eq!(env["L"], "/mnt/macos/x:/mnt/macos/y");
    assert!(!env.contains_key("W") && !env.contains_key("MISSING"));
    assert_eq!(env["MSLENV"], "A:P/p:L/l:W/w:MISSING");
}

#[test]
fn absolute_normalises() {
    assert_eq!(absolute("/a/b/../c/./d"), "/a/c/d");
}
