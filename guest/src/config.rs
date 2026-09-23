//! Minimal INI reader for /etc/wsl.conf, /etc/msl.conf and /etc/wsl-distribution.conf.
//! Sections and keys are case-insensitive; `#`/`;` start comments.

use std::collections::HashMap;
use std::path::Path;

#[derive(Default, Debug, Clone)]
pub struct Ini(HashMap<String, String>); // "section.key" (lowercase) -> value

impl Ini {
    pub fn parse(text: &str) -> Self {
        let mut map = HashMap::new();
        let mut section = String::new();
        for raw in text.lines() {
            let line = raw.trim();
            if line.is_empty() || line.starts_with('#') || line.starts_with(';') {
                continue;
            }
            if let Some(s) = line.strip_prefix('[').and_then(|l| l.strip_suffix(']')) {
                section = s.trim().to_ascii_lowercase();
                continue;
            }
            if let Some((k, v)) = line.split_once('=') {
                let v = v.trim();
                let v = v.trim_matches('"');
                map.insert(format!("{section}.{}", k.trim().to_ascii_lowercase()), v.to_string());
            }
        }
        Ini(map)
    }

    pub fn load(path: impl AsRef<Path>) -> Self {
        std::fs::read_to_string(path).map(|t| Self::parse(&t)).unwrap_or_default()
    }

    /// `base` overlaid with `over` (msl.conf overrides wsl.conf).
    pub fn overlay(mut self, over: Ini) -> Self {
        self.0.extend(over.0);
        self
    }

    pub fn get(&self, key: &str) -> Option<&str> {
        self.0.get(&key.to_ascii_lowercase()).map(String::as_str)
    }

    pub fn bool(&self, key: &str, default: bool) -> bool {
        match self.get(key).map(|v| v.to_ascii_lowercase()) {
            Some(v) if v == "true" || v == "1" || v == "yes" => true,
            Some(v) if v == "false" || v == "0" || v == "no" => false,
            _ => default,
        }
    }
}

/// The distro's effective config, relative to its root (`/` from inside it).
pub fn distro_conf(root: &str) -> Ini {
    Ini::load(format!("{root}/etc/wsl.conf")).overlay(Ini::load(format!("{root}/etc/msl.conf")))
}

pub fn distribution_conf(root: &str) -> crate::pb::DistributionConf {
    let ini = Ini::load(format!("{root}/etc/wsl-distribution.conf"));
    crate::pb::DistributionConf {
        oobe_command: crate::compat::oobe_command(ini.get("oobe.command").unwrap_or_default()),
        oobe_default_uid: ini.get("oobe.defaultuid").and_then(|v| v.parse().ok()),
        oobe_default_name: ini.get("oobe.defaultname").unwrap_or_default().to_string(),
    }
}

#[cfg(test)]
mod tests {
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
}
