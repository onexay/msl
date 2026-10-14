# Per-session sandbox policy

Set this in a distro's `/etc/msl.conf` to put each MSL `Run` session and its
descendants in a cgroup at the distro cgroup namespace root:

```ini
[sandbox]
enabled = true
cpu_max = 200000 100000
memory_max = 2147483648
pids_max = 512
io_max = 252:0 rbps=104857600 wbps=52428800
deny_network = true
```

`cpu_max` uses cgroup v2's quota and period in microseconds. `memory_max` is a
byte count, and `pids_max` is the maximum number of processes. Each `io_max`
entry uses the device major and minor number from `/sys/block/<device>/dev`,
followed by one or more cgroup v2 I/O limits. Separate device entries with
semicolons and add each block device the session can use. Resource values are
required when sandboxing is enabled; missing or rejected controls stop launch.

When `deny_network` is true, a cgroup BPF egress program drops outbound IP
packets for the session and its descendants. It requires the kernel's cgroup
BPF support. This setting denies all egress; it does not support destination
allowlists yet.

The policy is disabled by default. When enabled, it applies to every MSL Agent
`Run` in that distro. A command that invokes Bubblewrap starts inside the
limited cgroup, before Bubblewrap can create its workload processes. At session
exit, MSL kills remaining processes in the cgroup and removes it.
