# Compare MSL with other Linux environments

This comparison was checked on 2026-09-24 against project documentation, release pages, and pricing pages. Sources appear beside the relevant details and in [Sources](#sources). A `?` means the project's documentation did not answer the question. Versions, features, and prices change, so check the linked sources before relying on a detail.

MSL has a focused goal: **bring the `wsl.exe` workflow to macOS**. It uses the same command-line interface, WSL distribution images, and `wsl.conf` and `.wslconfig` conventions. Teams can carry one Linux development workflow between Windows and macOS. The other tools serve different purposes, including containers, general-purpose virtual machines, and CI. This page compares their trade-offs; it does not rank them.

## Feature matrix

### Linux development environments

| | **msl** | **WSL 2** (reference) | **OrbStack** machines | **Apple `container machine`** | **Lima** | **Multipass** | **UTM** | **Tart** |
|---|---|---|---|---|---|---|---|---|
| Host | macOS 27+, Apple silicon | Windows | macOS 14+ | macOS 26, Apple silicon | macOS, Linux (Windows experimental) | macOS, Linux, Windows | macOS | macOS, Apple silicon |
| `wsl.exe` CLI compatibility | **Yes** (arguments, output, exit codes) | Native | No | No | No | No | No | No |
| Runs WSL `.wsl` images unmodified | **Yes** (arm64; honours `wsl.conf`, `wsl-distribution.conf` OOBE) | Native | No | No (OCI images) | No (cloud images) | No (Ubuntu images) | No | No (OCI VM images) |
| VM model | One shared VM, per-distro namespaces | One shared VM, per-distro namespaces | One shared VM | One VM per machine | One VM per instance | One VM per instance | One VM per VM | One VM per VM |
| systemd | Yes (`[boot] systemd`) | Yes | Yes (also OpenRC, runit) | Yes (images with `/sbin/init`) | Yes | Yes | Yes | Yes |
| macOS/host files in Linux | `/mnt/macos`, virtiofs | `/mnt/c`, DrvFs (9p) | `/mnt/mac` and `/Users/...`, virtiofs | `$HOME` at `/Users/<you>`, virtiofs | virtiofs (vz), 9p (qemu), reverse-sshfs | SSHFS, or 9p on QEMU | virtiofs (Apple backend), 9p/WebDAV (QEMU) | virtiofs, mounted by hand |
| Linux files in Finder / Explorer | `~/.msl/distros/<distro>` over NFS, per-distro entry with logo in Finder Locations (VM must be running) | `\\wsl.localhost\<distro>` in Explorer | `~/OrbStack` and a Finder sidebar entry | No | No | No | No | No |
| localhost forwarding | Automatic, IPv4 and IPv6 | Automatic (NAT), or mirrored | Automatic | Explicit `-p` publish | Automatic (TCP; UDP with gRPC forwarder) | No (instance IP) | No | No |
| DNS | macOS resolver via mDNSResponder (VPN, split DNS, `.local`) | `dnsTunneling` through Windows | Forwards to macOS (VPN aware) | Embedded DNS; `/etc/resolver` for its own domain | Host resolver (hosts, mDNS) | ? | ? | ? |
| x86_64 distro or program support | **No** (arm64 kernel; support deferred, [#40](https://github.com/onexay/msl/issues/40)) | Native on x86_64 hosts | Rosetta | Rosetta | Rosetta (VZ) or QEMU | No | QEMU emulation, Rosetta (Apple backend) | Rosetta (`--rosetta`) |
| GPU | No | Yes (WSLg, `/dev/dxg`) | No | No | Vulkan via krunkit (experimental) | No | Vulkan/Venus (5.0 beta), VirGL (QEMU) | No |
| Memory returned to host while running | **No**; all of it when the VM idles out | Yes (`autoMemoryReclaim`, `dropCache` default) | Yes ("dynamic memory") | No (restart) | No (open issue) | ? | ? | ? |
| Licence / cost | Free; licence not chosen yet, unreleased | MIT, free | Proprietary; free personal, $8/user/month commercial | Apache-2.0, free | Apache-2.0, free | GPL-3.0, free | Apache-2.0, free (paid on App Store) | FSL-1.1-ALv2 (now owned by OpenAI) |
| Apple-native virtualization only | **Yes** (Virtualization.framework) | n/a (Hyper-V) | ? (undisclosed engine) | Yes | Optional (vz default; qemu, krunkit) | No (QEMU default; `applevz` driver new) | Optional | Yes |

### Container-focused tools (for context)

These run containers, not your day-to-day distro, but they are what many macOS teams install first.

| | **Docker Desktop** | **Podman machine** | **Rancher Desktop** | **Colima** | **ArcBox** |
|---|---|---|---|---|---|
| `wsl.exe` compatibility / WSL images | No (uses WSL 2 on Windows only) | No (WSL provider on Windows only) | No (WSL 2 on Windows only) | No | No |
| VM model | One shared VM | One VM per machine (Fedora CoreOS) | One shared VM (Lima, Alpine) | One VM per profile (Lima) | Shared system VM for containers; one VM per Linux machine |
| Full distro with systemd | No | FCOS only | No | Not its purpose | Machines (Ubuntu, Alpine); systemd ? |
| macOS files | VirtioFS or gRPC FUSE | `$HOME` mounted | virtiofs (default with VZ) | virtiofs, 9p, sshfs | virtiofs |
| Linux files in Finder | No | No | No | No | Docker data read-only at `~/ArcBox` (NFSv4) |
| localhost forwarding | Published ports | Published ports (gvproxy) | Automatic | Automatic | Yes |
| DNS | Internal DNS/proxy | gvproxy | Host resolver (Lima) | Host resolver (Lima) | Userspace stack, `*.arcbox.local` |
| x86_64 | Rosetta (VZ backend), QEMU binfmt | Rosetta (applehv only) | Rosetta (VZ) | Rosetta or qemu-user binfmt | FEX |
| GPU | No (Model Runner runs on the host) | Vulkan compute via libkrun/Venus | No | krunkit (AI workloads) | ? |
| Memory back while running | Yes with Docker VMM | ? | No | No | Only on its Hypervisor.framework backend |
| Licence / cost | Paid for orgs with 250+ staff or $10M+ revenue | Apache-2.0, free | Apache-2.0, free | MIT, free | MIT/Apache-2.0, free in beta |
| Apple-native only | Optional (VZ or Docker VMM) | Optional (applehv or libkrun, the default) | Yes by default (VZ; QEMU optional) | Optional | Optional (VZ default, own HV VMM) |

## Per-project notes

**WSL 2** (the reference). WSL has been open source under MIT since May 2025. At the time of this comparison, 2.7.14 was stable and 2.9.12 was a pre-release. WSL runs one utility VM. Each distribution has its own `init` and mount, PID, and UTS namespaces; distributions share a network namespace. WSL also supports GPU and GUI applications through WSLg, mirrored and `consomme` networking, memory reclaim while running, online VHD resize, Windows executable interop, and the `wslc` containers preview. MSL follows WSL's architecture, CLI, messages, and configuration files, but does not run host binaries from Linux. See the [WSL configuration guide](https://learn.microsoft.com/en-us/windows/wsl/wsl-config), [open-source announcement](https://blogs.windows.com/windowsdeveloper/2025/05/19/the-windows-subsystem-for-linux-is-now-open-source/), [technical documentation](https://wsl.dev/technical-documentation/), and [releases](https://github.com/microsoft/WSL/releases).

**OrbStack.** OrbStack is the closest design comparison: it runs multiple systemd distributions in one lightweight VM, exposes host files under `/mnt/mac`, and makes Linux files available in Finder. It also provides automatic port forwarding and VPN-aware DNS. Its additional features include Docker and Kubernetes in the same VM, Rosetta support for x86_64, dynamic memory, USB passthrough, and sound (v2.2). OrbStack can also run macOS commands from Linux through `mac` and Mach-O binfmt; MSL intentionally omits that integration. OrbStack is proprietary, costs $8 per user per month for commercial use, and does not support the WSL CLI or `.wsl` imports. Version 2.2.3 was current in August 2026. See [architecture](https://docs.orbstack.dev/architecture), [machines](https://docs.orbstack.dev/machines/), [dynamic memory](https://orbstack.dev/blog/dynamic-memory), and [pricing](https://orbstack.dev/pricing).

**Apple `container` and Containerization.** Apple's first-party tool added `container machine` in version 1.0 (June 2026), providing persistent Linux environments. A machine runs an OCI image with `/sbin/init` and can use systemd. Each machine has its own Virtualization.framework VM; `vminitd` communicates over vsock gRPC. The tool maps the macOS user and home directory into the guest, but requires explicit port publishing and has no Finder view of Linux files. Apple's documentation says the VM does not return freed memory to the host. The project uses Apache-2.0 and requires macOS 26; version 1.4.1 was current in September 2026. MSL uses Apple's `ContainerizationEXT4` package to format its data disk. See [container](https://github.com/apple/container), [container machine](https://github.com/apple/container/blob/main/docs/container-machine.md), [technical overview](https://github.com/apple/container/blob/main/docs/technical-overview.md), and [The Register's coverage](https://www.theregister.com/devops/2026/06/11/apple-gives-mac-devs-a-wsl-ish-thing-to-call-their-own/5254153).

**Lima and Colima.** Lima creates a VM for each instance from cloud images. On macOS, it defaults to Virtualization.framework and also supports QEMU and experimental krunkit, which provides GPU access through Venus. Lima supports automatic port forwarding, host-resolver DNS, and x86_64 through Rosetta or QEMU. Its `wsl2` VM type is available only on Windows, and memory ballooning remains an open issue ([#4220](https://github.com/lima-vm/lima/issues/4220)). Colima uses Lima to run Docker, containerd, Incus, and K3s. The versions checked were Lima 2.2.0 and Colima 0.10.3. See Lima's [VM types](https://lima-vm.io/docs/config/vmtype/), [mounts](https://lima-vm.io/docs/config/mount/), and [ports](https://lima-vm.io/docs/config/port/) documentation, and the [Colima project](https://github.com/abiosoft/colima).

**Docker Desktop.** Docker Desktop runs containers and Kubernetes in a shared VM; it is not a distribution manager. Users can choose Docker VMM, which returns unused memory to the host but does not support Rosetta, or Apple Virtualization, which does support Rosetta. Larger organizations need a paid subscription. Version 4.92.0 was released on 2026-09-21. See [Docker VMM](https://docs.docker.com/desktop/features/vmm/), [release notes](https://docs.docker.com/desktop/release-notes/), and [licensing](https://docs.docker.com/subscription/desktop-license/).

**Podman machine and Podman Desktop.** Each machine runs one Fedora CoreOS VM, using libkrun by default or the `applehv` provider. With libkrun, Vulkan compute runs through Venus, MoltenVK, and Metal. Rosetta is available only with `applehv`. Podman uses Apache-2.0. The versions checked were Podman 6.1.2 and Podman Desktop 1.29.3. See [`podman machine`](https://github.com/containers/podman/blob/main/docs/source/markdown/podman-machine.1.md) and the [GPU guide](https://podman-desktop.io/docs/podman/gpu).

**Rancher Desktop.** Rancher Desktop combines containers and K3s in a bundled Lima fork with an Alpine guest. It uses Virtualization.framework and virtiofs by default. It is licensed under Apache-2.0; version 1.24.0 was current in this comparison. See [releases](https://github.com/rancher-sandbox/rancher-desktop/releases) and [emulation settings](https://docs.rancherdesktop.io/ui/preferences/virtual-machine/emulation).

**Multipass.** Canonical's VM launcher creates one Ubuntu VM per instance. It uses QEMU by default on macOS and also offers a newer, more limited `applevz` driver. Mounts use SSHFS or 9p, and clients connect to instances by IP address. Multipass is licensed under GPL-3.0; version 1.16.4 was current in this comparison. See [drivers](https://canonical.com/multipass/docs/latest/explanation/driver/) and [mounts](https://canonical.com/multipass/docs/latest/explanation/mount/).

**UTM.** UTM is a general-purpose VM app for running many operating systems with QEMU or Apple Virtualization. It can fully emulate x86_64; the 5.0 beta adds Vulkan 1.3 for Linux guests through Venus. UTM does not provide a terminal-first workflow, port forwarding, or a Finder view of guest files. It is licensed under Apache-2.0. The versions checked were 4.7.5 stable and 5.0.5 beta. See [releases](https://github.com/utmapp/UTM/releases) and [Linux guest support](https://docs.getutm.app/guest-support/linux/).

**Tart.** Tart packages macOS and Linux Virtualization.framework VMs as OCI images for CI. Cirrus Labs joined OpenAI in 2026, and the repository moved to `openai/tart`. It remains under FSL-1.1-ALv2. The version checked was 2.37.0. See the [repository](https://github.com/openai/tart) and [license](https://tart.run/licensing/).

**Others:**
- **krunkit / libkrun:** a Hypervisor.framework VMM (not Virtualization.framework) with virtio-gpu Venus and free-page reporting that does return memory to macOS. It is the backend of Podman's default provider and Lima/Colima's krunkit type. msl rules it out because it isn't Apple-native. [libkrun](https://github.com/libkrun/libkrun), [krunkit](https://github.com/libkrun/krunkit).
- **ArcBox:** an open-source Rust Docker/OrbStack alternative with Linux machines, a Finder-visible `~/ArcBox`, and switchable VZ or custom Hypervisor.framework backends. Its [memory-ratchet write-up](https://arcbox.dev/blog/macos-vm-memory-ratchet) matches msl's own measurements ([#37](https://github.com/onexay/msl/issues/37)): no Virtualization.framework runtime gets freed RAM back to macOS. [Repo](https://github.com/arcboxlabs/arcbox).
- **Parallels Desktop / VMware Fusion:** full desktop hypervisors for any guest OS, one VM each, with 3D graphics. Parallels 27 is paid (subscription or one-time) and has Rosetta for Linux VMs in Pro/Business. Fusion has been free for all use since November 2024. Neither is a CLI-first Linux environment. [Parallels 27](https://www.parallels.com/blogs/parallels-desktop-27/), [Fusion free](https://blogs.vmware.com/cloud-foundation/2024/11/11/vmware-fusion-and-workstation-are-now-free-for-all-users/).
- **distrobox:** integrated distro containers on a Linux host. It doesn't run on macOS, but it works inside an msl distro with podman or docker. [distrobox.it](https://distrobox.it/).
- **Dev Containers:** a per-project environment spec (`devcontainer.json`) on any Docker-compatible engine. It complements msl rather than competing: run the engine inside a distro and point your editor at it. [containers.dev](https://containers.dev/).
- **WSL Manager (bostrot):** a GUI for WSL on Windows that now also manages Virtualization.framework VMs on macOS (beta). It is one VM each, with no `.wsl` import on macOS. [Repo](https://github.com/bostrot/wsl2-distro-manager).

## What MSL offers

- **It is `wsl.exe`.** Same arguments, English messages, table layouts and exit codes (`msl -l -v`, `--install`, `--export`/`--import`, `--manage`, `--mount`, `--debug-shell`, `--shutdown`). Scripts, docs and muscle memory from WSL work unchanged. No other macOS tool accepts WSL's CLI.
- **Same distro images as Windows.** `msl --install Ubuntu` reads Microsoft's `DistributionInfo.json` and uses the `.wsl` tarballs unmodified. It honours `wsl.conf` and the distro's own OOBE (`wsl-distribution.conf`), and masks Windows-only units at runtime. A developer on Windows and one on macOS run the same image.
- **Same config files.** `.mslconfig` uses `.wslconfig`'s sections, keys and warnings, and distros read `/etc/wsl.conf` (or `/etc/msl.conf`).
- **WSL's architecture, on Apple's stack only.** One VM with per-distro namespaces (like WSL 2 and OrbStack; unlike Apple `container machine`, Lima, Multipass, Tart and UTM). Distro start takes milliseconds, all distros share one memory pool and one localhost, and there's no QEMU, libkrun or custom hypervisor on macOS.
- **Finder per distro.** Each distro is its own Finder Locations entry at `~/.msl/distros/<distro>`, with the distro's logo. macOS metadata (`.DS_Store`, AppleDouble) stays out of the Linux filesystem.
- **DNS through mDNSResponder.** Queries resolve with the macOS resolver, so VPN split DNS, `/etc/resolver` and `.local` behave as they do on macOS.
- **Linux only, by design.** No `mac` command, no Mach-O binfmt, no macOS paths in `PATH`. Build tools can only find Linux toolchains, so outputs are always Linux ELF. OrbStack and WSL go the other way.
- **Free and small.** Unlike OrbStack or Docker Desktop, there's no commercial licence fee. The guest is one static Rust binary.

## Current limitations

- **Maturity.** msl is pre-release: not notarised, no signed public build, no licence chosen yet, and tested on one machine. WSL, OrbStack, Docker Desktop and Lima have years of users.
- **x86_64.** MSL runs an arm64 Linux kernel. It does not emulate an x86_64 system and does not support x86_64-only distro images or x86_64 programs. Rosetta integration in the VM is not a supported x86_64 execution path. Support remains deferred in [#40](https://github.com/onexay/msl/issues/40).
- **Memory.** OrbStack, Docker VMM, libkrun-based tools and WSL return memory while the VM runs. msl only returns it when the VM idles out, which is the same Virtualization.framework limit Apple `container`, Lima and ArcBox's VZ backend hit.
- **GPU and GUI apps.** WSL has WSLg and GPU compute. Podman (libkrun), Lima/Colima (krunkit), UTM 5 and Parallels have Vulkan/3D in Linux guests. msl has neither, and Virtualization.framework offers only 2D virtio-gpu.
- **Containers.** OrbStack, Docker Desktop, Podman, Rancher and Apple `container` ship a container engine and Kubernetes integration. With msl you install Docker or Podman inside a distro yourself.
- **Disk.** Both give each distro its own disk and can move, resize, export and import it; msl's are raw ext4 rather than VHDX, and `fsync` inside a distro isn't durable on msl (Virtualization.framework passes no flushes to hot-attached disks).
- **Files view.** `~/.msl/distros` works only while the VM runs (there's no auto-start on access; an FSKit version could add it). WSL's `\\wsl.localhost` starts the distro on access.
- **Networking modes.** WSL has mirrored and `consomme` modes, and Apple `container` gives each VM its own IP. msl has NAT only.
- **Distro choice.** msl runs what Microsoft's list offers for arm64 (Ubuntu, Debian, Fedora, AlmaLinux, openSUSE, Kali) plus any `.wsl` or tar you import. OrbStack and Lima offer more distros out of the box, and Apple `container machine` takes any OCI image with an init.
- **Extras others have:** USB device passthrough and sound (OrbStack), SSH-agent forwarding and cloud-init (OrbStack, Lima), snapshots (UTM, Parallels), macOS guests (Tart, UTM, Lima 2.2).
- **Isolation.** Distros share one kernel and VM (as in WSL 2). Per-VM tools isolate more strongly.

## Sources

- WSL: [wsl-config](https://learn.microsoft.com/en-us/windows/wsl/wsl-config), [build a custom distro (.wsl format)](https://learn.microsoft.com/en-us/windows/wsl/build-custom-distro), [open source](https://learn.microsoft.com/en-us/windows/wsl/opensource), [technical docs](https://wsl.dev/technical-documentation/), [WSL containers preview](https://learn.microsoft.com/en-us/windows/wsl/wsl-container), [releases](https://github.com/microsoft/WSL/releases)
- OrbStack: [architecture](https://docs.orbstack.dev/architecture), [machines](https://docs.orbstack.dev/machines/), [distros](https://docs.orbstack.dev/machines/distros), [network](https://docs.orbstack.dev/machines/network), [FAQ](https://docs.orbstack.dev/faq), [release notes](https://docs.orbstack.dev/release-notes), [dynamic memory](https://orbstack.dev/blog/dynamic-memory), [pricing](https://orbstack.dev/pricing)
- Apple: [container](https://github.com/apple/container), [releases](https://github.com/apple/container/releases), [container machine](https://github.com/apple/container/blob/main/docs/container-machine.md), [technical overview](https://github.com/apple/container/blob/main/docs/technical-overview.md), [networking](https://github.com/apple/container/blob/main/docs/networking.md), [host integration](https://github.com/apple/container/blob/main/docs/host-integration.md), [multiplatform images](https://github.com/apple/container/blob/main/docs/multiplatform-images.md), [containerization](https://github.com/apple/containerization)
- Lima: [vmType](https://lima-vm.io/docs/config/vmtype/), [krunkit](https://lima-vm.io/docs/config/vmtype/krunkit/), [mounts](https://lima-vm.io/docs/config/mount/), [ports](https://lima-vm.io/docs/config/port/), [balloon issue #4220](https://github.com/lima-vm/lima/issues/4220), [VZ memory issue #2789](https://github.com/lima-vm/lima/issues/2789), [releases](https://github.com/lima-vm/lima/releases)
- Colima: [repo](https://github.com/abiosoft/colima), [defaults](https://github.com/abiosoft/colima/blob/main/embedded/defaults/colima.yaml)
- Docker Desktop: [release notes](https://docs.docker.com/desktop/release-notes/), [VMM](https://docs.docker.com/desktop/features/vmm/), [settings](https://docs.docker.com/desktop/settings-and-maintenance/settings/), [licence](https://docs.docker.com/subscription/desktop-license/)
- Podman: [podman machine](https://github.com/containers/podman/blob/main/docs/source/markdown/podman-machine.1.md), [GPU](https://podman-desktop.io/docs/podman/gpu), [releases](https://github.com/containers/podman/releases)
- Rancher Desktop: [releases](https://github.com/rancher-sandbox/rancher-desktop/releases), [emulation](https://docs.rancherdesktop.io/ui/preferences/virtual-machine/emulation)
- Multipass: [releases](https://github.com/canonical/multipass/releases), [drivers](https://canonical.com/multipass/docs/latest/explanation/driver/), [mounts](https://canonical.com/multipass/docs/latest/explanation/mount/)
- UTM: [releases](https://github.com/utmapp/UTM/releases), [Linux guests](https://docs.getutm.app/guest-support/linux/)
- Tart: [repo](https://github.com/openai/tart), [quick start](https://tart.run/quick-start/), [licensing](https://tart.run/licensing/)
- libkrun/krunkit: [libkrun](https://github.com/libkrun/libkrun), [krunkit](https://github.com/libkrun/krunkit)
- ArcBox: [repo](https://github.com/arcboxlabs/arcbox), [memory ratchet](https://arcbox.dev/blog/macos-vm-memory-ratchet)
- Parallels: [Desktop 27](https://www.parallels.com/blogs/parallels-desktop-27/), [Rosetta for Linux VMs](https://kb.parallels.com/en/129871)
- VMware Fusion: [free for all users](https://blogs.vmware.com/cloud-foundation/2024/11/11/vmware-fusion-and-workstation-are-now-free-for-all-users/), [26H1](https://blogs.vmware.com/cloud-foundation/2026/05/14/announcing-vmware-workstation-and-fusion-26h1/)
- distrobox: [distrobox.it](https://distrobox.it/); Dev Containers: [containers.dev](https://containers.dev/), [spec](https://github.com/devcontainers/spec)
- WSL Manager: [bostrot/wsl2-distro-manager](https://github.com/bostrot/wsl2-distro-manager)
