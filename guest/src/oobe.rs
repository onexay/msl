// SPDX-License-Identifier: Apache-2.0
//! msl's built-in first-run setup (`/run/msl/init msl-oobe`), used in place of
//! distro OOBE scripts that only differ by Windows-specific wording.
//! Same behaviour as Debian's oobe.sh: create UID 1000 in the usual admin groups.

use std::io::{BufRead, Write};
use std::process::Command;

const DEFAULT_UID: u32 = 1000;
const GROUPS: &[&str] = &["adm", "cdrom", "sudo", "wheel", "dip", "plugdev"];

fn valid(name: &str) -> bool {
    let mut chars = name.chars();
    matches!(chars.next(), Some(c) if c.is_ascii_lowercase() || c == '_')
        && chars.all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_' || c == '-')
        && name.len() <= 32
}

fn suggestion() -> String {
    let raw = std::env::var("MSL_MACOS_USER").unwrap_or_default().to_ascii_lowercase();
    let s: String = raw.chars().filter(|c| c.is_ascii_alphanumeric() || *c == '_' || *c == '-').collect();
    let s = s.trim_start_matches(|c: char| !(c.is_ascii_lowercase() || c == '_')).to_string();
    if valid(&s) { s } else { String::new() }
}

fn run(cmd: &mut Command) -> bool {
    cmd.status().map(|s| s.success()).unwrap_or(false)
}

pub fn main() -> ! {
    if crate::users::by_uid("", DEFAULT_UID).is_some() {
        println!("User account already exists, skipping creation");
        std::process::exit(0);
    }
    let default = suggestion();
    println!("Please create a default Linux user account. It does not need to match your macOS user name.");
    let stdin = std::io::stdin();
    loop {
        if default.is_empty() {
            print!("Enter new Linux username: ");
        } else {
            print!("Enter new Linux username [{default}]: ");
        }
        let _ = std::io::stdout().flush();
        let mut line = String::new();
        if stdin.lock().read_line(&mut line).unwrap_or(0) == 0 {
            std::process::exit(1); // EOF: no user created
        }
        let mut name = line.trim().to_string();
        if name.is_empty() {
            name = default.clone();
        }
        if !valid(&name) {
            println!("Invalid username. It must start with a lowercase letter or underscore, and contain only lowercase letters, digits, underscores and dashes.");
            continue;
        }
        let uid = DEFAULT_UID.to_string();
        let created = if std::path::Path::new("/usr/sbin/adduser").exists() && Command::new("/usr/sbin/adduser").arg("--help").output().map(|o| String::from_utf8_lossy(&o.stdout).contains("--gecos") || String::from_utf8_lossy(&o.stdout).contains("--comment")).unwrap_or(false) {
            // Debian-style adduser prompts for the password itself.
            run(Command::new("/usr/sbin/adduser").args(["--uid", &uid, "--quiet", "--gecos", "", &name]))
        } else {
            run(Command::new("useradd").args(["-m", "-u", &uid, "-s", "/bin/bash", &name])) && run(Command::new("passwd").arg(&name))
        };
        if !created {
            println!("Failed to create user '{name}'. Please choose a different name.");
            let _ = Command::new("userdel").args(["-r", &name]).status();
            continue;
        }
        let group_file = std::fs::read_to_string("/etc/group").unwrap_or_default();
        let present: Vec<&str> = GROUPS
            .iter()
            .copied()
            .filter(|g| group_file.lines().any(|l| l.split(':').next() == Some(*g)))
            .collect();
        if !present.is_empty() {
            let _ = Command::new("usermod").args(["-aG", &present.join(","), &name]).status();
        }
        std::process::exit(0);
    }
}
