use super::Limits;

fn limits() -> Limits {
    Limits {
        cpu_max: "200000 100000".into(),
        memory_max: "1073741824".into(),
        pids_max: "256".into(),
        io_max: vec!["252:0 rbps=104857600 wbps=52428800".into()],
        deny_network: false,
    }
}

#[test]
fn accepts_complete_resource_policy() {
    assert!(limits().validate().is_ok());
}

#[test]
fn rejects_missing_io_limit() {
    let mut policy = limits();
    policy.io_max.clear();
    assert!(policy.validate().is_err());
}

#[test]
fn rejects_malformed_cpu_limit() {
    let mut policy = limits();
    policy.cpu_max = "200000".into();
    assert!(policy.validate().is_err());
}

#[test]
fn accepts_unlimited_cpu_and_memory_syntax() {
    let mut policy = limits();
    policy.cpu_max = "max 100000".into();
    policy.memory_max = "max".into();
    policy.pids_max = "max".into();
    assert!(policy.validate().is_ok());
}
