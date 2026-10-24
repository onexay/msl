use super::*;

fn states(list: &[&str]) -> impl FnMut() -> String {
    let mut it = list.iter().map(|s| s.to_string()).collect::<Vec<_>>().into_iter();
    move || it.next().unwrap_or_default()
}

#[test]
fn waits_until_systemd_is_running() {
    let s = wait_systemd(Duration::from_secs(5), Duration::ZERO, states(&["", "initializing", "starting", "running"]));
    assert_eq!(s, "running");
}

#[test]
fn degraded_counts_as_ready() {
    let s = wait_systemd(Duration::from_secs(5), Duration::ZERO, states(&["starting", "degraded"]));
    assert_eq!(s, "degraded");
}

#[test]
fn gives_up_at_the_timeout() {
    let s = wait_systemd(Duration::from_millis(30), Duration::from_millis(1), || "initializing".into());
    assert_eq!(s, "initializing");
}
