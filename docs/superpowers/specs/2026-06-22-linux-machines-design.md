# Design: OrbStack-style Linux machines

Date: 2026-06-22
Branch: feat/live-refresh-and-docker-routing
Status: Approved (pending spec review)

## Problem

Creating a Linux machine in Dory does not work the way it does in OrbStack. Evidence
gathered this session:

- A machine `ubuntu-176` exists at `~/.dory/machines/ubuntu-176/` with a built `disk.img`
  (8 GB), `seed.iso`, and SSH keys — but `share/ip.txt` was **never written**, meaning the
  VM never booted far enough for cloud-init to run. The machine appears in the list but is
  unusable: no IP, terminal cannot connect, `waitForIP` times out after 120s with no surfaced
  error or console log.
- The base-disk build (the subject of recent commits `eb95ef1`, `3c13caa`) actually succeeds.
  The failure is one layer deeper: the **raw VM boot itself**.

### Why the current path is fragile

`VirtualizationMachineProvider` is a standalone, brittle stack disconnected from the rest of
Dory. Per machine it:

1. Downloads raw Ubuntu cloud kernel/initrd/root.tar.xz.
2. Builds an 8 GB ext4 disk via `losetup`/`mkfs.ext4`/`mount`/`tar` inside an Apple-`container`
   micro-VM (`--cap-add ALL`).
3. Boots a raw `VZVirtualMachine` (`VZLinuxBootLoader`, `root=/dev/vda ro`) with a cloud-init
   seed ISO + NAT networking.
4. Discovers the guest IP by hoping cloud-init mounts virtiofs and writes `ip.txt`.
5. Connects the terminal over SSH to the NAT IP.

That chain (generic initrd → NOCLOUD cloud-init → DHCP → virtiofs IP report → SSH) has many
silent failure points and surfaces no console log. It is a second, parallel VM stack that
duplicates capability Dory already has elsewhere.

### What Dory already has that works

- A proven container engine reached through `any ContainerRuntime` (`DockerEngineRuntime`),
  driving either Dory's shared dind VM (`SharedVMProvisioner`, persistent
  `dory-engine-data:/var/lib/docker` volume) or a fronted Docker/OrbStack socket.
- A working embedded terminal (`ContainerTerminalView`) that execs `docker exec -it <id>` into
  any container over Dory's socket — no SSH.
- Image pull, container create (raw `proxyRequest`), build (`build(contextTar:query:)`), stats,
  inspect — all already implemented and shipping.
- `*.dory.local` DNS + host port-forwarding that already reconciles every container endpoint.

## Goals

- Creating a machine is fast and reliable: pick a distro, get a working Linux environment with
  a shell, package manager, persistence, real IP, and (where supported) systemd — every time.
- Match OrbStack's architecture: all machines are guests inside Dory's one shared VM, not a VM
  each, not cloud images, not loopback disk builds, not cloud-init.
- Reuse the proven `ContainerRuntime` + embedded terminal paths end to end.
- Keep the existing `MachinesView` UI, `Machine` model, and the four distro templates unchanged.

## Non-goals

- Dedicated micro-VM per machine (rejected: heavier memory, new cross-process terminal, not
  OrbStack's model).
- Fixing/keeping the raw-`VZVirtualMachine` path (retired).
- Host-user UID mapping / shared home into the machine (future enhancement; v1 runs as root).
- GUI distro version pickers beyond the four existing templates.

## Architecture

A **machine = a long-lived, labeled Linux container** in the active engine, orchestrated
through `any ContainerRuntime`. Lifecycle (create/start/stop/delete/list/exec) rides the same
code that already powers every container in Dory.

```
MachinesView (unchanged UI)
      │  createMachine / toggleMachine / deleteMachine / openMachineTerminal
      ▼
AppStore (machine methods rewritten)
      │
      ▼
MachineService ───────► MachineImageBuilder (systemd-enabled derived image, cached per distro)
      │  raw docker API via runtime.proxyRequest + runtime.{pull,build,start,stop,remove}
      ▼
ContainerRuntime (DockerEngineRuntime) → shared dind VM  OR  fronted Docker/OrbStack
```

### Components

**`MachineDistro` (catalog)** — replaces `VMDistro`. One entry per template: display name,
version, base image (`ubuntu:24.04`, `debian:12`, `fedora:40`, `alpine:3.20`), init strategy
(`systemd` for ubuntu/debian/fedora, `openrc-or-shell` for alpine), badge letter/hex, logo.

**`MachineImageBuilder`** — given a `MachineDistro`, ensures a systemd-enabled derived image
exists, tagged `dory-machine/<distro>:<version>`, building it once via `runtime.build`. Tiny
generated Dockerfile per distro family:

- ubuntu/debian:
  ```
  FROM <base>
  RUN apt-get update && apt-get install -y --no-install-recommends \
        systemd systemd-sysv dbus sudo bash ca-certificates iproute2 && \
      rm -rf /var/lib/apt/lists/*
  STOPSIGNAL SIGRTMIN+3
  CMD ["/sbin/init"]
  ```
- fedora (already ships systemd):
  ```
  FROM fedora:40
  RUN dnf -y install systemd sudo passwd iproute && dnf clean all
  STOPSIGNAL SIGRTMIN+3
  CMD ["/sbin/init"]
  ```
- alpine (no systemd; OpenRC + shell):
  ```
  FROM alpine:3.20
  RUN apk add --no-cache openrc bash sudo shadow iproute2
  CMD ["/bin/sh"]
  ```

  Cached by tag, so the first machine of a distro pays the build (~20–60s, mostly the package
  install) and every later machine of that distro is instant. If the build fails (e.g. no
  network for the package install), fall back to the plain base image with a keepalive init —
  the machine still starts and the terminal still works.

**`MachineService`** — thin orchestrator over `any ContainerRuntime`:

- `create(name, distro, progress)`:
  1. `MachineImageBuilder.ensureImage(distro)` → image tag.
  2. `POST /containers/create?name=dory-machine-<name>` via `proxyRequest` with the machine
     `HostConfig` (below). Label `dory.machine=<distro id>`, `dory.machine.version=<version>`,
     `hostname=<name>`.
  3. `start` the container.
  4. If init strategy is `systemd`: poll up to ~20s for the container to reach running and
     `systemctl is-system-running` to return any state (running/degraded both acceptable). If
     it never comes up, **safe fallback**: recreate the same container with command
     `["sleep", "infinity"]` (or `tail -f /dev/null`) so it always starts; terminal still works.
- `list()` → `GET /containers/json?all=1&filters={"label":["dory.machine"]}`, map each to
  `Machine` (status from `State`, IP from inspect `NetworkSettings.IPAddress`, cpu/mem from the
  stats path AppStore already uses for cards). Distro/version/letter/hex from the label + the
  `MachineDistro` catalog.
- `start(name)` / `stop(name)` / `delete(name)` → `runtime.start/stop/remove` by container id.
- `containerID(forMachine name)` → resolve the labeled container's id for the terminal.

Machine `HostConfig` create payload (raw docker API):

```json
{
  "Hostname": "<name>",
  "Image": "dory-machine/<distro>:<version>",
  "Cmd": ["/sbin/init"],
  "Labels": { "dory.machine": "<distro>", "dory.machine.version": "<version>" },
  "Env": ["container=docker"],
  "StopSignal": "SIGRTMIN+3",
  "HostConfig": {
    "Privileged": true,
    "CgroupnsMode": "host",
    "Tmpfs": { "/run": "", "/run/lock": "", "/tmp": "" },
    "RestartPolicy": { "Name": "unless-stopped" }
  }
}
```

(`Privileged` + cgroup-v2 — which Dory's dind already delegates subtree control for — is the
standard, well-trodden systemd-in-container recipe. For alpine the `Cmd` is `["/bin/sh"]` with a
keepalive and no systemd polling.)

### Terminal

`AppStore.openMachineTerminal` resolves the machine's container id and opens the **embedded
`ContainerTerminalView`** pointed at that id (the same view containers use). "Open in
Terminal.app" uses the existing `TerminalLauncher.openContainerShell(socketPath:containerID:)`.
`TerminalLauncher.openMachineShell` (SSH) is deleted. This removes SSH keys, NAT IP discovery,
and the cloud-init dependency entirely — the single biggest reliability win.

The `Machine` model gains `var containerID: String` (display `id` stays `name`).

### Networking / DNS

Because a machine is a container in the shared VM, Dory's existing port-forwarder and
`*.dory.local` reverse proxy already give it `machine-name.dory.local` when it publishes a
port. The card ADDRESS field shows the real container IP from inspect.

### Guard rail

Machines require a docker-compatible engine (`runtimeKind == .sharedVM || .docker`). On the
Apple-per-container fallback (`.appleContainer`), the New Machine / Create actions show the same
friendly "switch engines in Settings → Docker Engine" message the volume browser already uses,
instead of silently failing.

### Persistence

A machine is a normal container; its writable layer persists across stop/start and app restarts
as long as the engine's `/var/lib/docker` is durable — true for the shipping shared engine
(`dory-engine-data` volume) and for fronted Docker/OrbStack. Delete removes the container and
its layer.

## Migration & cleanup

- Retire and delete: `VirtualizationMachineProvider.swift`, `VMImageCache.swift`,
  `VMCloudInit.swift`, `VMFileDownloader.swift`. Trim `VMError.swift` to what `MachineService`
  needs (or remove). Replace `VMDistro.swift` with `MachineDistro`.
- `TerminalLauncher.openMachineShell` removed.
- The dead `ubuntu-176` raw-VZ machine and the stale `~/.dory/machines/.cache` (8 GB) are not
  used anymore. On first launch after the upgrade, AppStore offers a one-time, consented reclaim
  of `~/.dory/machines` (delete the directory) surfaced via the existing action-error/toast
  mechanism. Nothing is deleted without explicit consent.
- `RuntimeSnapshot.machines` and Apple `startMachine`/`stopMachine` (Apple `container machine`
  concept) are left intact but no longer feed the UI — the UI's machines come solely from
  `MachineService`. This avoids a third machine concept leaking into the view.

## Files

Added:
- `Dory/Runtime/Machines/MachineService.swift`
- `Dory/Runtime/Machines/MachineImageBuilder.swift`
- `Dory/Runtime/Machines/MachineDistro.swift`

Modified:
- `Dory/Models/AppStore.swift` — rewrite `createMachine`/`loadMachines`/`toggleMachine`/
  `deleteMachine`/`openMachineTerminal` over `MachineService`; add guard rail + machine-terminal
  state + one-time `~/.dory/machines` reclaim prompt.
- `Dory/Models/Models.swift` — add `Machine.containerID`.
- `Dory/Features/Machines/MachinesView.swift` — terminal button opens embedded
  `ContainerTerminalView` for the machine (a sheet/detail), mirroring containers.
- `Dory/Net/TerminalLauncher.swift` — remove `openMachineShell`.

Removed:
- `Dory/Runtime/Machines/VirtualizationMachineProvider.swift`
- `Dory/Runtime/Machines/VMImageCache.swift`
- `Dory/Runtime/Machines/VMCloudInit.swift`
- `Dory/Runtime/Machines/VMFileDownloader.swift`
- `Dory/Runtime/Machines/VMDistro.swift` (replaced by `MachineDistro.swift`)

The Xcode project uses `PBXFileSystemSynchronizedRootGroup`, so added/removed files need no
`project.pbxproj` edits.

## Error handling

- Create surfaces real, staged progress into the existing `machineCreationLog` sheet: pulling
  base image → building systemd image (first time) → creating → starting → ready. On any failure
  the actual engine error is shown (not a generic "Could not create machine"), and the partial
  container is removed so a retry is clean.
- systemd-failed-to-boot is not an error to the user: it triggers the keepalive fallback and the
  machine is still usable; a non-fatal note ("systemd unavailable on this image, shell ready")
  is logged.
- Guard rail returns a clear, actionable message when the engine is not docker-compatible.

## Testing / verification

- Unit: `MachineDistro` catalog mapping; `MachineImageBuilder` Dockerfile generation per family;
  `MachineService.create` payload shape (labels, HostConfig, StopSignal); list mapping from a
  fixed `/containers/json` JSON fixture (follows existing `DoryTests` patterns).
- Integration (manual, on the running shared engine): create an Ubuntu machine end to end →
  appears running with an IP in seconds-to-~1min → embedded terminal opens a root shell →
  `systemctl is-system-running` responds → `apt-get install` works → stop/start preserves a
  written file → delete removes it. Repeat for Debian (systemd) and Alpine (shell). Confirm the
  systemd-fallback path by simulating a build/boot failure.
- `cargo`/`swift` equivalent here: full Xcode build via `scripts/build.sh` (Xcode 27 beta
  DEVELOPER_DIR) must succeed with no errors before the work is considered done.

## Risks & mitigations

- **systemd-in-container quirks per distro** → mitigated by building images we control (install
  systemd ourselves) + the keepalive fallback so the core shell experience never breaks.
- **First-create latency from the image build** → one-time per distro, cached by tag; staged
  progress keeps the user informed. Acceptable and OrbStack-like (OrbStack ships prebuilt
  machine images).
- **Engine not docker-compatible** → explicit guard rail with an actionable message.
- **Engine `/var/lib/docker` durability** → relies on the shared engine's persistent volume
  (already in place) / native Docker; documented, not newly introduced.
```
