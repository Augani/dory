# Linux desktop parity contract

> **Status note (2026-08-22):** This document remains the product parity bar, but its narrative
> “Current state” cells are a historical snapshot and must not be used as release support claims.
> Implementation, product reachability, qualification, and support are now tracked separately in
> [`docs/linux-capability-and-qualification-matrix.md`](docs/linux-capability-and-qualification-matrix.md).
> The controlling design and sequencing are
> [`docs/linux-virtual-workspace-architecture.md`](docs/linux-virtual-workspace-architecture.md) and
> [`docs/linux-virtual-workspace-delivery-plan.md`](docs/linux-virtual-workspace-delivery-plan.md).

This document defines Dory's release bar for a Parallels-class Linux experience on Apple Silicon.
The comparison target is the Linux feature set in Parallels Desktop 26, not its Windows-only
features. A capability is not considered shipped because code or a package exists: it must pass an
automated test in the signed release candidate and a live test on physical supported Macs.

Primary references:

- [Parallels Tools overview](https://docs.parallels.com/landing/pdfm-ug/parallels-desktop-for-mac-26-users-guide/advanced-topics/installing-and-updating-parallels-tools/parallels-tools-overview)
- [Parallels Apple-silicon limitations](https://kb.parallels.com/en/128914)
- [Parallels Linux OpenGL support](https://kb.parallels.com/124138)
- [Parallels Virtio GPU and VirGL](https://kb.parallels.com/en/128518)
- [Apple GUI Linux VM reference](https://developer.apple.com/documentation/virtualization/running-gui-linux-in-a-virtual-machine-on-a-mac)
- [Apple shared directories](https://developer.apple.com/documentation/virtualization/shared-directories)
- [Apple clipboard sharing](https://developer.apple.com/documentation/virtualization/clipboard-sharing)
- [Apple VM audio](https://developer.apple.com/documentation/virtualization/audio)
- [Apple Intel-binary translation in Linux](https://developer.apple.com/documentation/virtualization/running-intel-binaries-in-linux-vms)

## Non-negotiable release contract

| Area | Required behavior | Current state |
|---|---|---|
| Official desktops | Ubuntu uses Canonical GNOME and Yaru; Debian and Kali use complete, distro-native Xfce sessions | Ubuntu's same-commit image and signed-app candidate passed the physical-Mac live gate, including restart, persistence, guest-tools update, corrupt-update rejection, rollback, and post-rollback qualification; Debian and Kali still need the same candidate-bound run |
| Applications | Each managed desktop includes a browser, terminal, files, settings, editor, archive viewer, image viewer, PDF viewer, package sources, and can install and launch more apps | Ubuntu's signed candidate mapped and rendered Firefox, Files, Settings, Calculator, and Terminal correctly; Debian and Kali plus the broader app set still need candidate-bound evidence |
| Custom Linux | Create an ARM64 Linux VM from a user-selected ISO through EFI, with persistent NVRAM and install media lifecycle | The signed app securely stages protected user-selected media, fingerprints the exact bytes, reports architecture compatibility separately from runtime qualification, imports accepted media into private daemon-managed storage, creates a thin disk, and boots through persistent EFI. Desktop ISO machines use balanced 4-vCPU/4-GB resource defaults rather than treating a CPU count as a compatibility workaround. A private bidirectional serial console gives every EFI boot durable diagnostics and recovery input. The EFI root disk is now native NVMe with fsync semantics; Dory-owned direct-kernel guests retain their VirtIO-block contract. Ubuntu 24.04.3 ARM64 completed installation and booted its persistent desktop after ISO ejection, but a later whole-guest stall during a Chromium snap installation keeps the exact runtime unqualified |
| Native and Intel apps | Native ARM64 apps work normally; supported x86_64 Linux applications use Apple's Linux translation runtime with guided setup and clear compatibility reporting | Missing for desktop machines |
| Display | Retina rendering, dynamic resolution during resize, full screen, correct scaling, cursor integration, and multi-display support | Single-display Retina, resize, native full-screen participation, and system-key capture exist; full qualification and multi-display are missing |
| Graphics | Hardware-accelerated Linux graphics meeting Parallels' advertised OpenGL level, with a software fallback and an application compatibility suite | The isolated dual VirGL2/Venus renderer, real packaged-worker bootstrap receipt, fresh exact live comparison, and candidate-bound crash circuit breaker are implemented. A renderer failure stops the uncertain GPU generation safely and makes the next automatic plan select its declared software recovery level; a hardware-only request stays an error. Hardware 3D remains unqualified until the release-signed candidate passes the physical Mesa VirGL desktop and Venus/Zed sustained-application gates |
| Clipboard | Bidirectional text and image clipboard with an explicit off/host-to-guest/guest-to-host/bidirectional policy | Binary-safe host/guest transport, native shortcuts, focus synchronization, Wayland/X11 adapters, and policy UI are implemented; all-distro live and exact-candidate qualification remain |
| Drag and drop | Bidirectional file drag and drop between Finder and the Linux desktop with conflict, cancellation, and progress handling | Missing |
| Shared folders | Add/remove read-only or read-write Mac folders, stable guest paths, permissions, large-file tests, file watching, and safe runtime updates | Scoped VirtioFS shares exist; runtime mutation and complete compatibility qualification are missing |
| Audio | Speaker output and microphone input, device/permission handling, mute, reconnect, and host sleep/wake recovery | Output and microphone devices plus signing/privacy declarations added; exact-candidate capture, controls, and recovery qualification pending |
| Devices | USB storage plus qualified physical USB attachment/detachment and remembered routing; camera and removable-media behavior is explicit | Host discovery only; passthrough missing |
| Networking | NAT/shared networking, bridged networking, host-only networking, stable addressing, DNS/VPN behavior, port forwarding, and offline recovery | Shared/NAT, host-only, and disconnected profiles now have exact backend-neutral contracts; new resolved plans bind a stable locally administered MAC and exact MTU across gvproxy, VZ, raw-HV, and source-preserving LAN forwarding. Qualified bridged networking and the signed-candidate stress matrix remain open. |
| Lifecycle | Graceful stop, pause/resume, durable suspend-to-disk, host sleep/wake, crash recovery, and resource reconfiguration | Managed guests shut down through the Dory agent; arbitrary EFI guests now fall back to Virtualization.framework's native virtual power-button request so filesystems can flush without guest tools. Pause foundations and disk persistence exist; saved machine state is missing |
| Data safety | Consistent snapshots, restore, clone, linked clone, export/import, and corruption/interruption recovery | Snapshot, restore, clone, and export/import include EFI machine identity/NVRAM with transactional rollback and bundle integrity checks; linked clones and live-state consistency need work |
| Guest tools | Versioned Dory guest tools update automatically and provide clipboard, resize, shares, time sync, drag/drop, telemetry, and compatibility health | Agent and Dory-owned integration files, including clipboard adapters, ship in one offline, deterministic desktop-update transaction. The signed package list is provenance and a compatibility preflight, not permission to run a hidden distribution upgrade; drag/drop and a unified compatibility-health surface remain missing |
| Updates | Existing desktops receive tested guest-tools and integration updates in place with rollback, while normal distro package and application updates remain available inside the guest; recreating the VM is never the upgrade path | Durable daemon journals, retained last-good snapshots, automatic failure/interruption rollback, and UI activation exist. The Ubuntu signed candidate passed the schema-v2 offline guest-tools update, corrupt-bundle rejection, last-good rollback, and post-rollback requalification; distro package-update UX and the remaining distros still need release evidence |
| Release provenance | Desktop kernel and every rootfs are built and verified from the release commit, signed into the component catalog, then boot-tested from that exact catalog | Same-commit build plus signed-helper physical-Mac boot gate added; the workflow must still pass before release |

## Current installer-media evidence

- Ubuntu 24.04.4 Desktop ARM64 (`c2610520bf582976839a1724c669e1cfed0547427be5a0ad12d457b92b46ffbe`) is architecture-compatible but runtime-known-unstable on Mac14,10 with macOS build 26A5406e and Dory's retired `vz-efi-virtio-blk-v1` profile. This exact media/host/profile tuple panicked or froze at one, two, and six vCPUs, so Dory blocks that tuple instead of presenting a resource-count workaround. It has not yet been qualified with the materially different native-NVMe profile.
- Ubuntu 24.04.3 Desktop ARM64 (`cdbf0f83ab4f7d46be767e73c59b5cbca9743dd5fb887142c96f4b2df38fa5ad`) also froze during installation with the retired VirtIO-block EFI profile. With `vz-efi-nvme-fsync-v1`, its 6.14.0-27 installer completed `curtin_install`, post-install configuration, and unattended package updates against a 64-GB NVMe disk. After ejecting the ISO, the installed system cold-booted, reached GNOME, retained Chrome, and browsed HTTPS over the VirtIO network. A later whole-guest stall was observed while App Center installed the Chromium snap, so this exact native-NVMe tuple remains unqualified pending a reproduced kernel/runtime diagnosis and sustained application stress pass.
- The user-supplied Omarchy 4.0.0 ISO (`9224fab3720560f771969a99a499e5f7e0f8e2d6a0681d872d52f05fb5003da4`) is x86_64 EFI-only. Dory rejects it before disk allocation or ISO staging with: `This ISO is Intel x86_64-only. Apple Silicon requires an arm64 EFI ISO.` This is the same whole-guest architecture limit documented for hardware-virtualized Linux on Apple silicon; native Omarchy qualification requires upstream ARM64 EFI media.

## Qualification matrix

Every supported managed desktop and every custom-ISO path must pass the following on each supported
macOS major version and qualified Apple-silicon generation:

1. Cold boot, login, shutdown, restart, host sleep/wake, pause/resume, and durable suspend/restore.
2. DHCP, DNS, IPv4/IPv6, VPN route changes, host-only connectivity, bridged connectivity, and port forwarding.
3. Browser HTTPS navigation, package update, GUI package installation, application launch, file open/save, and reboot persistence.
4. Window resize, full screen, Retina scaling, cursor capture/release, keyboard shortcuts, clipboard text/image, and drag/drop in both directions.
5. Speaker playback, microphone recording, shared-folder read/write and read-only enforcement, USB attach/detach, and removable media.
6. OpenGL compatibility, accelerated rendering correctness, software fallback, and representative developer/creative GUI workloads.
7. Snapshot, restore, clone, export/import, interrupted-operation recovery, and low-disk behavior.
8. Native ARM64 and supported x86_64 application execution with architecture and failure diagnostics.
9. Upgrade from every supported prior Dory desktop image without losing user accounts, applications,
   settings, shared-folder configuration, or workload data; failed updates must roll back cleanly.

Evidence must identify the release commit, app digest, component catalog digest, desktop image digest,
Mac model, macOS version, guest distribution, guest package manifest, and pass/fail result.

## Platform-equivalent scope

The contract does not require a capability that Parallels itself marks unavailable for Linux on
Apple Silicon, such as nested virtualization or booting a complete Intel Linux distribution through
hardware virtualization. It does require supported Intel Linux *applications* inside ARM Linux.
Windows-only Coherence is not a Linux parity requirement. A beta-only host API does not count as a
shipping capability; Dory must either provide a qualified fallback or mark that host version
unsupported for the parity release.

## Release rule

Dory must not describe its Linux experience as Parallels-equivalent while any required row is
missing or only preview. The next public desktop release may ship when every required capability is
either `PASS` in candidate-bound evidence or explicitly outside Parallels' own Apple-silicon Linux
contract.
