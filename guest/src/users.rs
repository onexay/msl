//! /etc/passwd and /etc/group lookups by file parsing (no NSS; see PLAN.md).

#[derive(Debug, Clone)]
pub struct User {
    pub name: String,
    pub uid: u32,
    pub gid: u32,
    pub home: String,
    pub shell: String,
    pub groups: Vec<u32>,
}

fn passwd_entries(root: &str) -> Vec<Vec<String>> {
    std::fs::read_to_string(format!("{root}/etc/passwd"))
        .unwrap_or_default()
        .lines()
        .map(|l| l.split(':').map(String::from).collect::<Vec<_>>())
        .filter(|f| f.len() >= 7)
        .collect()
}

fn with_groups(root: &str, f: &[String]) -> User {
    let name = f[0].clone();
    let gid = f[3].parse().unwrap_or(0);
    let mut groups = vec![gid];
    for g in std::fs::read_to_string(format!("{root}/etc/group")).unwrap_or_default().lines() {
        let gf: Vec<&str> = g.split(':').collect();
        if gf.len() >= 4 && gf[3].split(',').any(|m| m == name) {
            if let Ok(id) = gf[2].parse() {
                if !groups.contains(&id) {
                    groups.push(id);
                }
            }
        }
    }
    let shell = if f[6].is_empty() { "/bin/sh".to_string() } else { f[6].clone() };
    User { name, uid: f[2].parse().unwrap_or(0), gid, home: f[5].clone(), shell, groups }
}

pub fn by_name(root: &str, name: &str) -> Option<User> {
    passwd_entries(root).iter().find(|f| f[0] == name).map(|f| with_groups(root, f))
}

pub fn by_uid(root: &str, uid: u32) -> Option<User> {
    passwd_entries(root).iter().find(|f| f[2].parse() == Ok(uid)).map(|f| with_groups(root, f))
}
