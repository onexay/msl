#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_listeners() {
        let tcp = "  sl  local_address rem_address   st\n\
                   0: 0100007F:1F90 00000000:0000 0A\n\
                   1: 00000000:0016 00000000:0000 0A\n\
                   2: 0200A8C0:0050 00000000:0000 0A\n\
                   3: 0100007F:1F91 0100007F:9999 01\n";
        let tcp6 = "  sl  local_address remote st\n\
                    0: 00000000000000000000000000000000:1F40 00000000000000000000000000000000:0000 0A\n";
        assert_eq!(listening_ports(tcp, tcp6).into_iter().collect::<Vec<_>>(), vec![22, 8000, 8080]);
    }

    #[test]
    fn hosts_file() {
        let h = generate_hosts("mac", Some("192.168.64.1"), "127.0.0.1 localhost\n10.0.0.5 nas nas.lan # home\n::1 localhost\n");
        assert!(h.contains("127.0.1.1\tmac.\tmac\n"));
        assert!(h.contains("192.168.64.1\thost.internal\n"));
        assert!(h.contains("10.0.0.5\tnas nas.lan\n"));
        assert_eq!(h.matches("localhost\n").count(), 1);
    }

    #[test]
    fn hostnames() {
        assert_eq!(sanitize_hostname("Akshays-MacBook-Pro.local"), "Akshays-MacBook-Pro");
        assert_eq!(sanitize_hostname("my mac_1"), "my-mac-1");
        assert_eq!(sanitize_hostname(""), "msl");
    }
}
