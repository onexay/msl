#[cfg(test)]
mod tests {
    #[test]
    fn debian_oobe_is_replaced() {
        assert_eq!(super::oobe_command("/usr/lib/wsl/oobe.sh"), super::BUILTIN_OOBE);
        assert_eq!(super::oobe_command("/usr/lib/wsl/wsl-setup"), "/usr/lib/wsl/wsl-setup");
    }
}
