# How msl compares

Checked on 2026-09-24 against each project's docs, releases and pricing pages (sources are linked inline and under [Sources](#sources)). "?" means the project doesn't document it. Versions move fast, so check the links before relying on a cell.

msl's goal is narrow: **be `wsl.exe` on a Mac**. That means the same CLI, the same distro images and the same `wsl.conf`/`.wslconfig`, so a team that develops in WSL on Windows can use one workflow on macOS. Most tools below have a different goal (containers, general VMs, CI), so this is a comparison of trade-offs, not a ranking.

## Feature matrix

### Linux development environments

| | **msl** | **WSL 2** (reference) | **OrbStack** machines | **Apple `container machine`** | **Lima** | **Multipass** | **UTM** | **Tart** |
|---|---|---|---|---|---|---|---|---|
| Host | macOS 26+, Apple silicon | Windows | macOS 14+ | macOS 26, Apple silicon | macOS, Linux (Windows experimental) | macOS, Linux, Windows | macOS | macOS, Apple silicon |
| `wsl.exe` CLI compatibility | **Yes** (arguments, output, exit codes) | Native | No | No | No | No | No | No |
| Runs WSL `.wsl` images unmodified | **Yes** (arm64; honours `wsl.conf`, `wsl-distribution.conf` OOBE) | Native | No | No (OCI images) | No (cloud images) | No (Ubuntu images) | No | No (OCI VM images) |
| VM model | One shared VM, per-distro namespaces | One shared VM, per-distro namespaces | One shared VM | One VM per machine | One VM per instance | One VM per instance | One VM per VM | One VM per VM |
| systemd | Yes (`[boot] systemd`) | Yes | Yes (also OpenRC, runit) | Yes (images with `/sbin/init`) | Yes | Yes | Yes | Yes |
| Mac/host files in Linux | `/mnt/mac`, virtiofs | `/mnt/c`, DrvFs (9p) | `/mnt/mac` and `/Users/...`, virtiofs | `$HOME` at `/Users/<you>`, virtiofs | virtiofs (vz), 9p (qemu), reverse-sshfs | SSHFS, or 9p on QEMU | virtiofs (Apple backend), 9p/WebDAV (QEMU) | virtiofs, mounted by hand |
| Linux files in Finder / Explorer | `~/MSL/<distro>` over NFS, per-distro entry with logo in Finder Locations (VM must be running) | `\\wsl.localhost\<distro>` in Explorer | `~/OrbStack` and a Finder sidebar entry | No | No | No | No | No |
| localhost forwarding | Automatic, IPv4 and IPv6 | Automatic (NAT), or mirrored | Automatic | Explicit `-p` publish | Automatic (TCP; UDP with gRPC forwarder) | No (instance IP) | No | No |
| DNS | macOS resolver via mDNSResponder (VPN, split DNS, `.local`) | `dnsTunneling` through Windows | Forwards to macOS (VPN aware) | Embedded DNS; `/etc/resolver` for its own domain | Host resolver (hosts, mDNS) | ? | ? | ? |
| x86_64 Linux | **No** (qemu-user planned) | n/a (x86_64 host) | Rosetta | Rosetta | Rosetta (vz) or QEMU | No | QEMU emulation, Rosetta (Apple backend) | Rosetta (`--rosetta`) |
| GPU | No | Yes (WSLg, `/dev/dxg`) | No | No | Vulkan via krunkit (experimental) | No | Vulkan/Venus (5.0 beta), VirGL (QEMU) | No |
| Memory returned to host while running | **No**; all of it when the VM idles out | Yes (`autoMemoryReclaim`, `dropCache` default) | Yes ("dynamic memory") | No (restart) | No (open issue) | ? | ? | ? |
| Licence / cost | Free; licence not chosen yet, unreleased | MIT, free | Proprietary; free personal, $8/user/month commercial | Apache-2.0, free | Apache-2.0, free | GPL-3.0, free | Apache-2.0, free (paid on App Store) | FSL-1.1-ALv2 (now owned by OpenAI) |
| Apple-native virtualization only | **Yes** (Virtualization.framework) | n/a (Hyper-V) | ? (undisclosed engine) | Yes | Optional (vz default; qemu, krunkit) | No (QEMU default; `applevz` driver new) | Optional | Yes |

### Container-focused tools (for context)

These run containers, not your day-to-day distro, but they are what many Mac teams install first.

| | **Docker Desktop** | **Podman machine** | **Rancher Desktop** | **Colima** | **ArcBox** |
|---|---|---|---|---|---|
| `wsl.exe` compatibility / WSL images | No (uses WSL 2 on Windows only) | No (WSL provider on Windows only) | No (WSL 2 on Windows only) | No | No |
| VM model | One shared VM | One VM per machine (Fedora CoreOS) | One shared VM (Lima, Alpine) | One VM per profile (Lima) | Shared system VM for containers; one VM per Linux machine |
| Full distro with systemd | No | FCOS only | No | Not its purpose | Machines (Ubuntu, Alpine); systemd ? |
| Mac files | VirtioFS or gRPC FUSE | `$HOME` mounted | virtiofs (default with VZ) | virtiofs, 9p, sshfs | virtiofs |
| Linux files in Finder | No | No | No | No | Docker data read-only at `~/ArcBox` (NFSv4) |
| localhost forwarding | Published ports | Published ports (gvproxy) | Automatic | Automatic | Yes |
| DNS | Internal DNS/proxy | gvproxy | Host resolver (Lima) | Host resolver (Lima) | Userspace stack, `*.arcbox.local` |
| x86_64 | Rosetta (VZ backend), QEMU binfmt | Rosetta (applehv only) | Rosetta (VZ) | Rosetta or qemu-user binfmt | FEX |
| GPU | No (Model Runner runs on the host) | Vulkan compute via libkrun/Venus | No | krunkit (AI workloads) | ? |
| Memory back while running | Yes with Docker VMM | ? | No | No | Only on its Hypervisor.framework backend |
| Licence / cost | Paid for orgs with 250+ staff or $10M+ revenue | Apache-2.0, free | Apache-2.0, free | MIT, free | MIT/Apache-2.0, free in beta |
| Apple-native only | Optional (VZ or Docker VMM) | Optional (applehv or libkrun, the default) | Yes by default (VZ; QEMU optional) | Optional | Optional (VZ default, own HV VMM) |

## Per-project notes

**WSL 2** (the reference). Open source (MIT) since May 2025; stable 2.7.14, pre-release 2.9.12. One utility VM with `mini_init`, one `init` per distro in its own mount/PID/UTS namespaces, a shared network namespace. Ahead of msl on GPU and GUI apps (WSLg), mirrored and `consomme` networking, memory reclaim while running, online VHD resize, Windows interop (running `.exe` from Linux) and the new `wslc` containers preview. msl copies its architecture, CLI, messages and config files, and deliberately leaves out host-binary interop. [WSL docs](https://learn.microsoft.com/en-us/windows/wsl/wsl-config), [open-source announcement](https://blogs.windows.com/windowsdeveloper/2025/05/19/the-windows-subsystem-for-linux-is-now-open-source/), [technical docs](https://wsl.dev/technical-documentation/), [releases](https://github.com/microsoft/WSL/releases).

**OrbStack.** The closest to msl in design: one shared lightweight VM ("similar to WSL 2"), 16 distros with systemd, `/mnt/mac`, `~/OrbStack` in Finder, automatic port forwarding, VPN-aware DNS. It is ahead on polish, Docker and Kubernetes in the same VM, Rosetta x86_64, dynamic memory, USB passthrough and sound (v2.2). It also runs macOS commands from Linux (`mac`, Mach-O binfmt), which msl excludes on purpose. Proprietary, $8/user/month for commercial use, and there's no WSL CLI or `.wsl` import. v2.2.3 (2026-08). [Architecture](https://docs.orbstack.dev/architecture), [machines](https://docs.orbstack.dev/machines/), [dynamic memory](https://orbstack.dev/blog/dynamic-memory), [pricing](https://orbstack.dev/pricing).

**Apple `container` / Containerization.** Apple's first-party tool; 1.0 (June 2026) added `container machine`, persistent Linux environments that The Register called "WSL-ish". Machines are OCI images with `/sbin/init` (systemd works), your macOS user and `$HOME` are mapped in, and each machine is its own VM (Virtualization.framework, `vminitd` over vsock gRPC, the same building blocks msl uses). Ports are published explicitly, with no Finder view of Linux files, and Apple's docs state freed memory is not returned to the host. Apache-2.0; macOS 26. 1.4.1 (2026-09). msl uses its `ContainerizationEXT4` package to format the data disk. [container](https://github.com/apple/container), [container machine](https://github.com/apple/container/blob/main/docs/container-machine.md), [technical overview](https://github.com/apple/container/blob/main/docs/technical-overview.md), [The Register](https://www.theregister.com/devops/2026/06/11/apple-gives-mac-devs-a-wsl-ish-thing-to-call-their-own/5254153).

**Lima / Colima.** Lima runs one VM per instance from cloud images, with vz as the default backend on macOS, plus QEMU and experimental krunkit (GPU via Venus). Automatic port forwarding, host-resolver DNS, Rosetta or QEMU for x86_64. Lima has a `wsl2` vmType, but only on Windows hosts, and no memory ballooning ([#4220](https://github.com/lima-vm/lima/issues/4220)). Colima wraps Lima for Docker/containerd/Incus/K3s. Lima 2.2.0, Colima 0.10.3. [vmType](https://lima-vm.io/docs/config/vmtype/), [mounts](https://lima-vm.io/docs/config/mount/), [ports](https://lima-vm.io/docs/config/port/), [Colima](https://github.com/abiosoft/colima).

**Docker Desktop.** Containers and Kubernetes in one shared VM, not a distro manager. Choice of Docker VMM (returns unused memory to the host; no Rosetta) or Apple Virtualization (Rosetta). Paid subscription for larger organisations. 4.92.0 (2026-09-21). [VMM](https://docs.docker.com/desktop/features/vmm/), [release notes](https://docs.docker.com/desktop/release-notes/), [licence](https://docs.docker.com/subscription/desktop-license/).

**Podman machine / Podman Desktop.** One Fedora CoreOS VM per machine, running on libkrun (the default) or applehv. libkrun gives Vulkan compute through Venus → MoltenVK → Metal. Rosetta only on applehv. Apache-2.0. Podman 6.1.2, Podman Desktop 1.29.3. [podman machine](https://github.com/containers/podman/blob/main/docs/source/markdown/podman-machine.1.md), [GPU](https://podman-desktop.io/docs/podman/gpu).

**Rancher Desktop.** Containers plus k3s on a bundled Lima fork with an Alpine guest; VZ and virtiofs by default. Apache-2.0. 1.24.0. [Releases](https://github.com/rancher-sandbox/rancher-desktop/releases), [emulation](https://docs.rancherdesktop.io/ui/preferences/virtual-machine/emulation).

**Multipass.** Canonical's Ubuntu VM launcher, one VM per instance. QEMU by default on macOS, plus a new `applevz` driver with fewer features. Mounts via SSHFS or 9p, and you reach instances by IP. GPL-3.0, 1.16.4. [Drivers](https://canonical.com/multipass/docs/latest/explanation/driver/), [mounts](https://canonical.com/multipass/docs/latest/explanation/mount/).

**UTM.** A general VM app (any OS) on QEMU or Apple Virtualization. It can emulate x86_64 fully, and 5.0 beta adds Vulkan 1.3 for Linux guests via Venus. It has no terminal-first workflow, port forwarding or Finder view. Apache-2.0; 4.7.5 stable, 5.0.5 beta. [Releases](https://github.com/utmapp/UTM/releases), [Linux guest support](https://docs.getutm.app/guest-support/linux/).

**Tart.** Virtualization.framework VMs (macOS and Linux) distributed as OCI images, built for CI. Cirrus Labs joined OpenAI in 2026; the repo is now `openai/tart`, still FSL-1.1-ALv2. 2.37.0. [Repo](https://github.com/openai/tart), [licensing](https://tart.run/licensing/).

**Others:**
- **krunkit / libkrun:** a Hypervisor.framework VMM (not Virtualization.framework) with virtio-gpu Venus and free-page reporting that does return memory to macOS. It is the backend of Podman's default provider and Lima/Colima's krunkit type. msl rules it out because it isn't Apple-native. [libkrun](https://github.com/libkrun/libkrun), [krunkit](https://github.com/libkrun/krunkit).
- **ArcBox:** an open-source Rust Docker/OrbStack alternative with Linux machines, a Finder-visible `~/ArcBox`, and switchable VZ or custom Hypervisor.framework backends. Its [memory-ratchet write-up](https://arcbox.dev/blog/macos-vm-memory-ratchet) matches msl's own measurements ([memory-reclaim.md](design/memory-reclaim.md)): no Virtualization.framework runtime gets freed RAM back to macOS. [Repo](https://github.com/arcboxlabs/arcbox).
- **Parallels Desktop / VMware Fusion:** full desktop hypervisors for any guest OS, one VM each, with 3D graphics. Parallels 27 is paid (subscription or one-time) and has Rosetta for Linux VMs in Pro/Business. Fusion has been free for all use since November 2024. Neither is a CLI-first Linux environment. [Parallels 27](https://www.parallels.com/blogs/parallels-desktop-27/), [Fusion free](https://blogs.vmware.com/cloud-foundation/2024/11/11/vmware-fusion-and-workstation-are-now-free-for-all-users/).
- **distrobox:** integrated distro containers on a Linux host. It doesn't run on macOS, but it works inside an msl distro with podman or docker. [distrobox.it](https://distrobox.it/).
- **Dev Containers:** a per-project environment spec (`devcontainer.json`) on any Docker-compatible engine. It complements msl rather than competing: run the engine inside a distro and point your editor at it. [containers.dev](https://containers.dev/).
- **WSL Manager (bostrot):** a GUI for WSL on Windows that now also manages Virtualization.framework VMs on macOS (beta). It is one VM each, with no `.wsl` import on macOS. [Repo](https://github.com/bostrot/wsl2-distro-manager).

## Where msl is different

- **It is `wsl.exe`.** Same arguments, English messages, table layouts and exit codes (`msl -l -v`, `--install`, `--export`/`--import`, `--manage`, `--mount`, `--debug-shell`, `--shutdown`). Scripts, docs and muscle memory from WSL work unchanged. No other Mac tool accepts WSL's CLI.
- **Same distro images as Windows.** `msl --install Ubuntu` reads Microsoft's `DistributionInfo.json` and uses the `.wsl` tarballs unmodified. It honours `wsl.conf` and the distro's own OOBE (`wsl-distribution.conf`), and masks Windows-only units at runtime. A Windows developer and a Mac developer run the same image.
- **Same config files.** `.mslconfig` uses `.wslconfig`'s sections, keys and warnings, and distros read `/etc/wsl.conf` (or `/etc/msl.conf`).
- **WSL's architecture, on Apple's stack only.** One VM with per-distro namespaces (like WSL 2 and OrbStack; unlike Apple `container machine`, Lima, Multipass, Tart and UTM). Distro start takes milliseconds, all distros share one memory pool and one localhost, and there's no QEMU, libkrun or custom hypervisor on the Mac.
- **Finder per distro.** Each distro is its own Finder Locations entry at `~/MSL/<distro>`, with the distro's logo. Mac metadata (`.DS_Store`, AppleDouble) stays out of the Linux filesystem.
- **DNS through mDNSResponder.** Queries resolve with the Mac's own resolver, so VPN split DNS, `/etc/resolver` and `.local` behave as on the Mac.
- **Linux only, by design.** No `mac` command, no Mach-O binfmt, no Mac paths in `PATH`. Build tools can only find Linux toolchains, so outputs are always Linux ELF. OrbStack and WSL go the other way.
- **Free and small.** Unlike OrbStack or Docker Desktop, there's no commercial licence fee. The guest is one static Rust binary.

## Gaps (where others are ahead)

- **Maturity.** msl is pre-release: not notarised, no signed public build, no licence chosen yet, and tested on one Mac. WSL, OrbStack, Docker Desktop and Lima have years of users.
- **x86_64.** OrbStack, Apple `container`, Lima, Colima, Docker Desktop and Rancher Desktop run amd64 through Rosetta, and UTM and QEMU-based tools emulate it fully. msl has an untested Rosetta path (only when Rosetta is already installed) and plans qemu-user in the [Nitrogen](https://github.com/onexay/msl/milestone/7) milestone. Until then x86-only WSL distros (Arch, SLES, eLxr) are out.
- **Memory.** OrbStack, Docker VMM, libkrun-based tools and WSL return memory while the VM runs. msl only returns it when the VM idles out, which is the same Virtualization.framework limit Apple `container`, Lima and ArcBox's VZ backend hit.
- **GPU and GUI apps.** WSL has WSLg and GPU compute. Podman (libkrun), Lima/Colima (krunkit), UTM 5 and Parallels have Vulkan/3D in Linux guests. msl has neither, and Virtualization.framework offers only 2D virtio-gpu.
- **Containers.** OrbStack, Docker Desktop, Podman, Rancher and Apple `container` ship a container engine and Kubernetes integration. With msl you install Docker or Podman inside a distro yourself.
- **Disk.** WSL resizes VHDs, while msl can't grow the store (`--manage --resize` isn't supported yet).
- **Files view.** `~/MSL` works only while the VM runs (there's no auto-start on access; an FSKit version could add it). WSL's `\\wsl.localhost` starts the distro on access.
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
