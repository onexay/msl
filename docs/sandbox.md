# Distro cgroup delegation

MSL delegates the CPU, memory, PID, and I/O controllers to each running distro
under `/sys/fs/cgroup/msl/<distro-id>`. The distro cgroup namespace is rooted
at that directory. MSL keeps its ordinary agent and system services beneath
`msl-agent`, leaving the delegated root available to a protected manager
installed inside the distro. MSL publishes the registered distro UUID at
`/run/msl/distro-id` for the manager's backend-scope report.

The distro-local manager owns sandbox policy and creates one cgroup per
workload before starting it. It is responsible for applying and reading back
the resolved limits, enforcing the requested network policy, and cleaning up
the workload. An ordinary MSL `Agent.Run` is not a manager operation and does
not apply sandbox policy.

MSL fails distro startup if required controller delegation or cgroup namespace
setup fails. This confirms setup only; workload enforcement and network-filter
behavior still require runtime validation by the manager's backend profile.
