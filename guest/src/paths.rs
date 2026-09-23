//! macOS <-> Linux path translation, `mslpath` (the `wslpath` equivalent) and
//! `MSLENV` (the `WSLENV` equivalent, macOS -> Linux only).

use crate::config;
use std::collections::HashMap;
use std::path::{Component, PathBuf};

/// Where the Mac's `/` is mounted in the distro: `<automount.root>mac`
/// (default `/mnt/mac`). `root` is the distro root ("" from inside it).
pub fn mac_mount(root: &str) -> String {
    let conf = config::distro_conf(root);
    let base = conf.get("automount.root").unwrap_or("/mnt/").trim_end_matches('/').to_string();
    format!("{base}/mac")
}

/// macOS path -> Linux path. Relative paths are left as they are.
pub fn to_linux(mac: &str, mount: &str) -> String {
    if !mac.starts_with('/') {
        return mac.to_string();
    }
    if mac == "/" { mount.to_string() } else { format!("{mount}{mac}") }
}

/// Linux path -> macOS path. Paths under the Mac mount map back directly;
/// Linux-only paths map to the distro's view on the Mac (`<view>/<distro>/...`,
/// normally `~/MSL/<distro>/...`).
pub fn to_mac(linux: &str, mount: &str, view: &str, distro: &str) -> String {
    if linux == mount {
        return "/".to_string();
    }
    if let Some(rest) = linux.strip_prefix(mount).filter(|r| r.starts_with('/')) {
        return rest.to_string();
    }
    if !linux.starts_with('/') {
        return linux.to_string();
    }
    format!("{}/{distro}{linux}", view.trim_end_matches('/'))
}

/// Lexically normalise an absolute path (no filesystem access, like wslpath -a).
fn absolute(p: &str) -> String {
    let joined = if p.starts_with('/') {
        PathBuf::from(p)
    } else {
        std::env::current_dir().unwrap_or_else(|_| PathBuf::from("/")).join(p)
    };
    let mut out = PathBuf::from("/");
    for c in joined.components() {
        match c {
            Component::ParentDir => {
                out.pop();
            }
            Component::Normal(n) => out.push(n),
            _ => {}
        }
    }
    out.to_string_lossy().into_owned()
}

const USAGE: &str = "Usage:
    -a    force result to absolute path format
    -u    translate from a macOS path to a Linux path (default)
    -w    translate from a Linux path to a macOS path
    -m    same as -w (macOS paths already use '/')";

/// `mslpath [-a] [-u|-w|-m] path`
pub fn mslpath_main(args: &[String]) -> ! {
    let (mut abs, mut to_mac_dir) = (false, false);
    let mut path: Option<&str> = None;
    for a in args {
        match a.as_str() {
            "-a" => abs = true,
            "-u" => to_mac_dir = false,
            "-w" | "-m" => to_mac_dir = true,
            s if s.starts_with('-') && s.len() > 1 => {
                // combined flags, e.g. -wa
                for ch in s[1..].chars() {
                    match ch {
                        'a' => abs = true,
                        'u' => to_mac_dir = false,
                        'w' | 'm' => to_mac_dir = true,
                        _ => {
                            eprintln!("mslpath: Invalid argument\n{USAGE}");
                            std::process::exit(1);
                        }
                    }
                }
            }
            p if path.is_none() => path = Some(p),
            _ => {
                eprintln!("mslpath: Invalid argument\n{USAGE}");
                std::process::exit(1);
            }
        }
    }
    let Some(p) = path else {
        eprintln!("mslpath: Invalid argument\n{USAGE}");
        std::process::exit(1);
    };
    let mount = mac_mount("");
    let out = if to_mac_dir {
        let linux = if abs { absolute(p) } else { p.to_string() };
        let view = std::env::var("MSL_MAC_VIEW")
            .unwrap_or_else(|_| format!("{}/MSL", std::env::var("MSL_MAC_HOME").unwrap_or_else(|_| "~".into())));
        let distro = std::env::var("MSL_DISTRO_NAME").unwrap_or_default();
        to_mac(&linux, &mount, &view, &distro)
    } else {
        let linux = to_linux(p, &mount);
        if abs { absolute(&linux) } else { linux }
    };
    println!("{out}");
    std::process::exit(0)
}

/// Apply MSLENV: `VAR[/flags]:VAR2[/flags]...` with the macOS values supplied.
/// Flags: `p` = translate a path, `l` = translate a ':'-separated path list,
/// `u` = macOS -> Linux only (implied), `w` = Linux -> macOS only (so skipped).
pub fn apply_mslenv(spec: &str, values: &HashMap<String, String>, mount: &str, env: &mut HashMap<String, String>) {
    for item in spec.split(':').filter(|s| !s.is_empty()) {
        let (name, flags) = item.split_once('/').unwrap_or((item, ""));
        if flags.contains('w') && !flags.contains('u') {
            continue;
        }
        let Some(value) = values.get(name) else { continue };
        let translated = if flags.contains('l') {
            value.split(':').map(|p| to_linux(p, mount)).collect::<Vec<_>>().join(":")
        } else if flags.contains('p') {
            to_linux(value, mount)
        } else {
            value.clone()
        };
        env.insert(name.to_string(), translated);
    }
    env.insert("MSLENV".to_string(), spec.to_string());
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn translate_both_ways() {
        let m = "/mnt/mac";
        assert_eq!(to_linux("/Users/a/x y", m), "/mnt/mac/Users/a/x y");
        assert_eq!(to_linux("/", m), "/mnt/mac");
        assert_eq!(to_linux("rel/p", m), "rel/p");
        let v = "/Users/a/MSL";
        assert_eq!(to_mac("/mnt/mac/Users/a", m, v, "D"), "/Users/a");
        assert_eq!(to_mac("/mnt/mac", m, v, "D"), "/");
        assert_eq!(to_mac("/mnt/macfoo", m, v, "D"), "/Users/a/MSL/D/mnt/macfoo");
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
        apply_mslenv("A:P/p:L/l:W/w:MISSING", &values, "/mnt/mac", &mut env);
        assert_eq!(env["A"], "plain");
        assert_eq!(env["P"], "/mnt/mac/Users/a");
        assert_eq!(env["L"], "/mnt/mac/x:/mnt/mac/y");
        assert!(!env.contains_key("W") && !env.contains_key("MISSING"));
        assert_eq!(env["MSLENV"], "A:P/p:L/l:W/w:MISSING");
    }

    #[test]
    fn absolute_normalises() {
        assert_eq!(absolute("/a/b/../c/./d"), "/a/c/d");
    }
}
