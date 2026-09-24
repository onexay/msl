# Memory reclaim on Virtualization.framework

Status: investigated in the Carbon milestone (2026-09-24). **`autoMemoryReclaim` has no effect on macOS.** Memory goes back to macOS when the VM exits (`vmIdleTimeout`).

## The problem

Once the guest has touched memory, macOS keeps it assigned to the VM, even after the guest frees it:

| Step (Ubuntu running, VM configured with 18 GB) | Host `phys_footprint` of the VM process |
|---|---|
| Idle distro | 883 MB |
| Guest allocates and touches 2 GiB | 2941 MB |
| Guest frees it (guest `MemFree` ≈ 17 GB) | **2941 MB** (nothing returned) |

The metric used is `footprint <pid>` / `top -stats mem` on `com.apple.Virtualization.VirtualMachine`, the same figure Activity Monitor shows. The spike's earlier measurement looked inconclusive only because it filled the page cache with files that were already cached.

## What we tried: drop caches, then cycle the balloon

This is WSL's approach (`autoMemoryReclaim`):
1. The guest drops its page cache and compacts memory.
2. msld inflates the virtio balloon over the guest's free memory, so the guest hands those pages to the device.
3. msld deflates the balloon again.

| Step | Guest | Host footprint |
|---|---|---|
| After 3 GiB alloc and free | `MemFree` ≈ 17 GB | 3989 MB |
| Balloon inflated (target = total − free + 256 MB), held 40 s | `MemFree` **0.49 GB**: the balloon really took ~17 GB | **3987 MB** |
| Deflated | back to ≈ 17 GB | ≈ 3721 MB (a ~265 MB drop, not repeatable at scale) |

**VZ's `VZVirtioTraditionalMemoryBalloonDevice` does not release ballooned pages to macOS.** The guest gives the memory up, and the host keeps it. ArcBox describes the same "memory ratchet" ("no runtime on VZ can reliably give the RAM back").

The balloon cycle was **removed**. It freed nothing on the host, and it temporarily squeezed the guest down to ~256 MB of headroom, which could push a busy workload into OOM.

## What msl does instead

- **`vmIdleTimeout`** (default 60 s, as in WSL): when no distros are running, the VM shuts down and *all* its memory goes back to macOS. The next `msl` command boots it again in about 1 s.
- **`instanceIdleTimeout`** (default 15 s): idle distros stop, which lets the VM reach that idle state.
- **`[experimental] autoMemoryReclaim`** is still parsed, for `.wslconfig` compatibility, but has no effect.

## Possible future work

- Re-test when Apple ships free-page reporting (`VIRTIO_BALLOON_F_REPORTING`) or a balloon that releases pages to the host.
- Measure libkrun's free-page reporting as a data point. It's out of scope for msl (not Apple-only), but it's the approach ArcBox and `container-runtime-krun` use.
