#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn allowlist() {
        let h = "/home/akshay";
        assert!(allowed("/home/akshay/.vscode-server/msl/7debcd0e.sock", h));
        assert!(allowed("/home/akshay/.vscode-server/msl/abc-1_2.sock", "/home/akshay/"));
        for bad in [
            "/var/run/docker.sock",
            "/run/systemd/private",
            "/home/akshay/.vscode-server/msl/../x.sock",
            "/home/akshay/.vscode-server/msl/sub/x.sock",
            "/home/akshay/.vscode-server/msl/.sock",
            "/home/akshay/.vscode-server/msl/.hidden.sock",
            "/home/akshay/.vscode-server/msl/x.socket",
            "/home/other/.vscode-server/msl/x.sock",
            "/home/akshay/.vscode-server/msl/x.sock/",
            "home/akshay/.vscode-server/msl/x.sock",
        ] {
            assert!(!allowed(bad, h), "{bad}");
        }
        assert!(!allowed("/.vscode-server/msl/x.sock", ""));
        assert!(!allowed("/a/../.vscode-server/msl/x.sock", "/a/.."));
    }

    #[test]
    fn passwd_and_groups() {
        let passwd = "root:x:0:0:root:/root:/bin/bash\nakshay:x:1000:1000:,,,:/home/akshay:/bin/bash\n";
        assert_eq!(passwd_entry(passwd, 1000), Some(("akshay".into(), 1000, "/home/akshay".into())));
        assert_eq!(passwd_entry(passwd, 1001), None);
        let group = "sudo:x:27:akshay\ndocker:x:999:bob,akshay\nadm:x:4:syslog\n";
        assert_eq!(groups_of(group, "akshay"), vec![27, 999]);
    }
}
