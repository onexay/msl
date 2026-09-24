// SPDX-License-Identifier: Apache-2.0
//! Compatibility layer for unmodified WSL images (see docs/ARCHITECTURE.md, "Distro compatibility").
//! Nothing here writes to the distro image: masks live on the distro's /run tmpfs.

use std::path::Path;

/// Units that assume Windows or fight over the shared VM console.
pub const MASKED_UNITS: &[&str] = &[
    "wsl-pro-service.service", // Ubuntu Pro for WSL: talks to a Windows-side agent
    "console-getty.service",   // every distro shares the VM console (Debian goes `degraded`)
    "getty@tty1.service",
];

const UNIT_DIRS: &[&str] = &["/etc/systemd/system", "/usr/lib/systemd/system", "/lib/systemd/system"];

/// Runtime-mask the units above (`/run/systemd/system/<unit> -> /dev/null`).
/// Must run inside the distro root, before systemd starts.
pub fn mask_units() -> Vec<String> {
    let run = Path::new("/run/systemd/system");
    let _ = std::fs::create_dir_all(run);
    let mut masked = Vec::new();
    for unit in MASKED_UNITS {
        let template = unit.split_once('@').map(|(base, _)| format!("{base}@.service"));
        let exists = UNIT_DIRS.iter().any(|d| {
            Path::new(d).join(unit).exists() || template.as_ref().is_some_and(|t| Path::new(d).join(t).exists())
        });
        if exists && std::os::unix::fs::symlink("/dev/null", run.join(unit)).is_ok() {
            masked.push(unit.to_string());
        }
    }
    masked
}

/// systemd's catch-all `.link` file. It gives the NIC a "predictable" name
/// (`eth0` -> `enp0s1`). msl passes `net.ifnames=0` on the kernel command line,
/// but systemd 259+ sees the distro's pid namespace as a container and then
/// reads boot options from PID 1's arguments instead. Every distro's udev acts
/// on the one shared NIC, and WSL users and scripts expect `eth0`.
pub const MASKED_LINKS: &[&str] = &["99-default.link"];

/// Runtime-mask the `.link` files above (`/run/systemd/network/<file> -> /dev/null`),
/// unless the admin has their own copy in /etc. Must run before systemd starts.
pub fn mask_links() -> Vec<String> {
    let run = Path::new("/run/systemd/network");
    let mut masked = Vec::new();
    for link in MASKED_LINKS {
        let shipped = ["/usr/lib/systemd/network", "/lib/systemd/network"].iter().any(|d| Path::new(d).join(link).exists());
        if !shipped || Path::new("/etc/systemd/network").join(link).exists() {
            continue;
        }
        let _ = std::fs::create_dir_all(run);
        if std::os::unix::fs::symlink("/dev/null", run.join(link)).is_ok() {
            masked.push(link.to_string());
        }
    }
    masked
}

/// OOBE commands replaced by msl's own (`/run/msl/init msl-oobe`), because the
/// original only adds Windows-specific wording to an otherwise generic flow.
const OOBE_OVERRIDES: &[&str] = &["/usr/lib/wsl/oobe.sh"]; // Debian

pub const BUILTIN_OOBE: &str = "/run/msl/init msl-oobe";

pub fn oobe_command(original: &str) -> String {
    if OOBE_OVERRIDES.contains(&original.trim()) { BUILTIN_OOBE.to_string() } else { original.to_string() }
}

#[cfg(test)]
mod tests {
    #[test]
    fn debian_oobe_is_replaced() {
        assert_eq!(super::oobe_command("/usr/lib/wsl/oobe.sh"), super::BUILTIN_OOBE);
        assert_eq!(super::oobe_command("/usr/lib/wsl/wsl-setup"), "/usr/lib/wsl/wsl-setup");
    }
}
