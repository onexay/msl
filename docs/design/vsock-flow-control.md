# vsock flow control on Virtualization.framework

Status: fixed in the Boron milestone (2026-09-24).
Code: `guest/src/framed.rs` and `Sources/MSLService/FramedBridge.swift`.
Regression checks: `Tests/e2e/boron.sh`, "Flow control" section.

## Summary

The Virtualization.framework (VZ) vsock device does not tolerate a host that stops reading a **host-initiated** connection (`VZVirtioSocketDevice.connect(toPort:)`). When the host-side reader of one guest→host vsock stream stalls, the whole VM freezes:
- every vsock connection stops, including the gRPC control channel, DNS and other sessions;
- then the guest kernel reports RCU stalls on a vCPU.

The VM stays frozen even after the slow reader resumes.

Guest-initiated connections, accepted through a `VZVirtioSocketListener`, do **not** have this problem (see "Connection direction matters" below). msl opened all its data streams host-side, so it hit the bug. msl therefore never relies on vsock for flow control. Every guest↔host byte stream uses its own credit-based framing, which guarantees that the receiving side can always drain its vsock socket immediately.

## How it showed up

The Boron end-to-end test (`Tests/e2e/boron.sh`) hung partway through, at `msl --export Ubuntu-24.04 - | msl --import Second <dir> -`.

What we saw:
- **msld:** every request (`--status`, `-l`, run, import) blocked. A stack sample showed each thread waiting on a gRPC reply from the guest's mini-init.
- **Guest console:** systemd jobs stuck for minutes (`Job ldconfig.service/start running (7min)`). In the first occurrence, repeated kernel stall reports appeared:
  ```
  rcu: INFO: rcu_sched detected stalls on CPUs/tasks:
  rcu:   0-...!: (11 GPs behind) idle=06d4/1/0x4000000000000002 softirq=476/476
  rcu: rcu_sched kthread timer wakeup didn't happen for 6208 jiffies!
  rcu:   Possible timer handling issue on cpu=0
  ```
  vCPU 0 had stopped making progress, even on timer interrupts.

## Isolating it

| Experiment | Result |
|---|---|
| Idle boot, DNS tunneling on/off, liveness probe every 5 s for 90 s | Healthy |
| Ubuntu export alone (1.3 GB, guest→host) | Healthy, 2 s |
| Import alone (host→guest, every `--install`) | Healthy |
| Export piped into import (both directions, and export outruns import) | **Frozen** |
| `msl -e sh -c 'head -c 200000000 /dev/zero' \| (sleep 30; cat >/dev/null)` | **Frozen** from t+3 s, **still frozen after the reader drained** |

The last row is the minimal reproduction. The only ingredient is a host-side consumer that stops reading a guest→host stream for a while. That happens routinely (`msl cat bigfile | less`, a terminal paused with Ctrl-S, a slow network client behind localhost forwarding), so this was a latent bug from the Helium milestone onwards.

## Connection direction matters (verified 2026-09-24)

Apple's Containerization wires process stdio the same naive way: `LinuxProcess.swift` reads each vsock handle in a `readabilityHandler` and writes to the consumer synchronously, with no credit. But its guest (vminitd) **dials back** to host listeners. So we tested both directions:

| Experiment | Direction | Framing | Host reader paused 20–30 s | Result |
|---|---|---|---|---|
| msl before the fix: `msl -e … \| (sleep 30; cat)` | host → guest `connect(toPort:)` | none | yes | **VM frozen**, never recovers |
| Apple `container exec … \| (sleep 30; cat)` (container 1.1.0) | guest dials host listener | none | yes | responsive throughout; guest producer blocked until the reader resumed (finished at 21 s); host RSS +27 MB for 200 MB, so real backpressure, not buffering |
| msl with an experimental host listener that doesn't read for 20 s; guest sends 200 MB with Python `AF_VSOCK` | guest dials host listener | none | yes | **responsive throughout**; guest sender blocked until the host read (finished at 20 s); no RCU stalls |

The problem is therefore specific to **host-initiated** vsock connections. On guest-initiated connections, VZ applies virtio-vsock credit correctly and the guest's writes block, as they should.

## Mechanism (inferred)

We can't see inside VZ, so this is inferred from the behaviour above:

1. msld used to copy each vsock connection to its destination with a plain read/write loop. When the destination blocks (a full pipe, a paused terminal), msld stops reading that vsock socket.
2. The host-side socket buffer fills up. For host-initiated connections, VZ's vsock device then appears to **block on that socket** instead of withholding credit from the guest as virtio-vsock allows. That stalls the device's processing for *all* connections. The other direction is fine: host→guest backpressure (a slow guest) never froze anything.
3. With the device stuck, guest→host traffic stops. A vCPU that notifies the device, or handles its interrupts, apparently waits too, which gives the RCU stall on vCPU 0.
4. The export→import pipe then deadlocks for good. Export data can't drain because import doesn't consume, and import data can't arrive because the device is blocked behind the export connection.

Takeaway: with VZ, **the host must never let the receive side of a host-initiated vsock connection back up.**

## The fix: credit-based framing

Every guest↔host *byte stream* is framed:

```
frame  = kind:u8  len:u32be  payload[len]
kind 0 = data     (≤ 64 KiB)
kind 1 = credit   (payload: u32be bytes delivered to the local consumer)
kind 2 = eof      (this direction is finished; half-close)
```

- **Window.** Each direction starts with 1 MiB of credit. A sender never has more than 1 MiB that the receiver hasn't *delivered* (written to its local consumer).
- **Three threads per bridge, on both host and guest:**
  - **receiver:** reads frames from the vsock socket and queues data. It never blocks on the local consumer, and the queue can't exceed the window.
  - **local writer:** writes queued data to the consumer, then grants credit, batched at 128 KiB or whenever the queue empties.
  - **sender:** reads the local producer and sends data within the available credit, then `eof`.
- **Where backpressure lands.** When the consumer is slow, credit stops, the peer's sender waits, and the producer blocks on its own pipe, PTY or TCP socket. Neither side ever stops reading vsock, so VZ never blocks.
- **Session stdio.** A child's stdin/stdout/stderr is now a pipe (or the PTY) relayed by the agent through a bridge. Before this, the vsock socket itself was handed to the child, which bypassed any flow control.
- **Finishing a session.** The guest reports `Exited` only after all output has been sent. There is one exception: output that a background process keeps open. The sender gives up on it after sitting on an *empty* input for 2 s, which is never while it is waiting for credit, so a slow reader is never cut off.

What uses it:

| Stream | Host side | Guest side |
|---|---|---|
| Session stdout/stderr/stdin, tty | `Service.session` | `session.rs` |
| `--export` / `--import` tar streams | `Service.export` / `importDistro` | `miniinit.rs` via `framed::sender/receiver` |
| Localhost forwarding | `PortForwarder` | `net.rs` forwarder |
| `~/.msl/distros` NFS bridge | `FileView` | `net.rs` forwarder |

What doesn't use it, and why that's safe:
- **gRPC control channels** (msld ↔ mini-init/agents): the host reader is SwiftNIO and the guest reader is tonic, and both always read eagerly.
- **DNS tunneling:** tiny request/response messages, one per connection.

**Rule for new code:** any new vsock byte stream must either use the framing, or have a reader that provably never stops reading.

### A second bug found while fixing this

Stress-testing the bridges (`msl cat /etc/hosts` 60 times) showed 10 runs with **empty output**. Both implementations called `shutdown()` on an fd *number* after the object that owned it had closed it. When the number had been reused, `shutdown()` hit an unrelated connection, often the session's stdout.

Fixed as follows:
- **Rust:** the socket `File` stays owned until the bridge finishes.
- **Swift:** the fd is closed exactly once, after all three threads are done, and `shutdown()` only runs while it is still open.

Result: 0 of 60 runs empty or short. "no lost output across 30 short sessions" is now a permanent check in `boron.sh`.

### Results

| Check | Before | After |
|---|---|---|
| VM liveness while a reader is paused | frozen, never recovers | responsive throughout |
| 1.3 GB `--export … - \| --import … -` | deadlock and VM freeze | 4 s |
| Every byte delivered to a paused reader (50 MB) | n/a | ✅ |
| `msl cat` output complete (60 runs) | 50/60 (fd-reuse bug) | 60/60 |

## Alternatives considered

| Option | How it would work | Why we didn't choose it |
|---|---|---|
| **Reverse the connection direction** (the guest dials a host `VZVirtioSocketListener` for every stream, as Containerization does) | Verified to give correct backpressure with no framing and no extra copy | **The strongest alternative, and a candidate for a later optimisation.** We didn't switch because: it's a VZ behaviour we observed rather than one Apple documents (framing is transport-agnostic and also protects against the same flaw in any other path); it needs per-stream host listeners and port allocation plus a "guest didn't dial back" timeout (Containerization has `VsockPortAllocator` for this); and framing was already implemented and verified. Framing and dial-back also combine safely. |
| **Unbounded host-side buffering** | Always read vsock eagerly into memory (or spill to disk) in msld | Memory is bounded only by the guest's output. `msl cat 20GB.img \| slow` would buffer gigabytes in msld. Spilling to disk adds I/O and cleanup work and still doesn't create real backpressure. |
| **A larger `SO_RCVBUF` on the host socket** | Give the host socket more buffer before it fills | It only delays the freeze. Any consumer that pauses longer than the buffer lasts still hangs the VM. |
| **Pausing the producer with `SIGSTOP`/`SIGCONT`** | msld stops the guest process group at a high watermark and resumes it at a low one | Visible job-control side effects: shells notice, and handlers run on `SIGCONT`. It doesn't cover producers that aren't a user process (export tar, the forwarder, the NFS server), and it races with the process's own job control. |
| **TCP over the vmnet interface for data streams** | The guest listens on its vmnet IP and msld connects to it; kernel TCP provides flow control | A real option, and the strongest fallback. We didn't choose it because: the guest address changes per boot, so it needs discovery; the listeners need an auth token so other local software on the shared network can't connect; streams would depend on the guest network being up and on distros not reconfiguring `eth0`; and it bypasses vsock's natural host-only isolation. Framing kept a single transport. |
| **virtio-console ports (`VZVirtioConsoleDevice`)** | Multiplex streams over console ports | A fixed number of ports set at VM creation, lower throughput, and the same class of VZ-managed buffering, so there's no evidence it behaves better. |
| **File-based bulk transfer over virtiofs** | Export/import write or read the tarball directly through `/mnt/mac` | FUSE/virtiofs has real request-level flow control, which suits file targets. But it can't serve `-` (stdin/stdout), sessions, forwarding or NFS, so framing would still be needed. It remains a possible fast path for file-to-file export/import. |
| **A custom paravirtual device (`VZCustomVirtioDevice`, macOS 27)** | A purpose-built virtio stream device with explicit backpressure | Needs a guest kernel driver plus a host device model, and raises the minimum to macOS 27. Worth revisiting if framing overhead ever matters. |
| **libkrun (TSI or its own vsock)** | A different VMM with its own vsock implementation | Rejected at planning time: the Apple-only virtualization requirement. |
| **Waiting for an Apple fix** | Rely on VZ applying virtio-vsock credit on host-initiated connections | We can't depend on it. We should still file a Feedback Assistant report (open item). The repro is now precise: host-initiated vs guest-initiated, same payload. |

Cost of the chosen approach:
- a 5-byte header per frame (≤ 64 KiB) plus a credit frame per 128 KiB delivered;
- one extra copy through a guest-side pipe or PTY for session stdio;
- three threads per bridge.

In practice the 1.3 GB export went from 2 s (unframed, alone) to 4 s when piped into a concurrent import. That's acceptable for correctness.

## Open items

- File an Apple Feedback report: host-initiated `connect(toPort:)` connections freeze the VM when the host stops reading, while guest-initiated connections apply backpressure correctly. Attach both reproductions above.
- ~~Check whether Apple's Containerization has the same latent issue.~~ Done: it doesn't, because its guest dials back (see "Connection direction matters").
- Consider moving data streams to guest dial-back, which would remove the frame headers and the extra stdio copy. Keep framing on at least one side as defence in depth.
- If throughput ever matters more, measure larger windows and frames, a splice-based relay in the guest, or the virtiofs fast path for file-to-file export/import.
