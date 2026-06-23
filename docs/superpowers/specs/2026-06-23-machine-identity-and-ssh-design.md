# Machine Identity, File Sharing & Real SSH — Design Spec

**Workstream:** WS4 of the Dory UI/UX redesign (see [2026-06-22-ui-redesign-audit-digest.md](2026-06-22-ui-redesign-audit-digest.md)). The biggest functional gap vs OrbStack: today a Linux machine boots as **root** with no user, no home sharing, no SSH. This makes every new machine an instant, OrbStack-style dev box you own.

**Goal:** A new Linux machine auto-provisions a passwordless-sudo user matching your macOS account (uid 501), mounts your live Mac home at the same path as the user's home, makes `~/.gitconfig`/`~/.ssh`/projects available, runs a real `sshd` reachable at `ssh you@localhost -p <port>` (and IDE Remote-SSH), and opens the terminal/`dory ssh` as you — not root.

**Architecture:** A machine is a Privileged systemd container in Dory's shared-VM engine (one `docker:dind` micro-VM that already virtiofs-shares your Mac `$HOME` at the identical path). We add (1) a Mac-side identity reader, (2) per-distro images that bake `openssh-server` + `sudo`, (3) a post-create `docker exec` provisioning step (user/sudo/sshd/authorized_keys), (4) two engine fixes so a raw-TCP SSH port reaches the Mac, (5) exec-as-user terminals + a fixed `dory ssh`, and (6) a redesigned stepped creation flow.

**Tech Stack:** Swift 6 / SwiftUI / macOS; `MachineService` over `any ContainerRuntime`; the shared-VM dind engine; `HostPortForwarder` (raw L4 TCP). Tests: Swift `Testing`.

## Locked decisions

- **User:** `NSUserName()`, **uid 501** (matches macOS so virtiofs file ownership is correct), passwordless sudo.
- **Home:** mirrored — the Linux user's home **is** `/Users/<you>` (the live Mac home, read-write). One default bind `$HOME:$HOME`. Only paths under `$HOME` are shareable without an engine recreate (the boundary).
- **Inbound SSH auth:** the machine's `sshd` uses `AuthorizedKeysFile /etc/dory/authorized_keys` (a machine-local path), seeded from the Mac's `~/.ssh/*.pub` — **never** writes to the mounted `~/.ssh/authorized_keys` (which would alter the Mac's own SSH access). Private keys are never copied; they're present via the home mount for *outbound* git/ssh only.
- **Shell:** bash by default (installed on every distro), with a bash/zsh/fish picker in the creation UI.
- **SSH model:** real `sshd` + published port (full parity), chosen by the user over the exec-only fast-follow.
- **Sequencing:** XL scope; the implementation plan lands it in two reviewable phases — **A: identity + home + exec-as-user + stepped UI + bug fix**, then **B: sshd + engine fixes + port allocation + `dory ssh`/IDE Remote-SSH**. Same end state.

## Security posture (explicit)

This makes *your own* machine a dev box with *your* credentials — appropriate for the local-dev product. It is **not** the future agent-sandbox safety model: a machine with your home mounted RW can read your `~/.ssh` private keys and write your Mac files. The eventual AI-agent-sandbox product ([[dory-business-strategy]]) will replace raw home-mounting with a credential proxy + egress firewall + read-restricted `~/.ssh`. WS4 explicitly defers that. The creation UI states "your Mac home and keys are shared into this machine."

---

## Phase A — Identity, home sharing, exec-as-user, stepped UI

### A1. `MacIdentity` (new, `Dory/Runtime/Machines/MacIdentity.swift`)
Reads the Mac-side identity once, at create time. Pure, injectable, unit-testable (inject the reads).
```
struct MacIdentity: Sendable, Hashable {
    let username: String      // NSUserName()
    let uid: Int              // Int(getuid()) — 501 on a standard Mac
    let homePath: String      // NSHomeDirectory() — e.g. /Users/<you>
    let shell: String         // chosen login shell inside the machine, default "/bin/bash"
    let publicKeys: [String]  // contents of each ~/.ssh/*.pub (may be empty)
}
extension MacIdentity {
    static func current(shell: String = "/bin/bash") -> MacIdentity   // production reader
}
```
`publicKeys` = every readable `~/.ssh/*.pub` file's trimmed contents. Empty `~/.ssh` is valid (sshd still provisions; password login stays disabled — keys can be added later).

### A2. Settings model changes (`MachineService.swift`)
- Extend `MountPair` with a read-only flag: `struct MountPair { var host: String; var guest: String; var readOnly: Bool = false }`. `hostConfig` (MachineService.swift:346) emits `"\(host):\(guest)\(readOnly ? ":ro" : "")"`. `currentSettings` (MachineService.swift:281) parses the optional `:ro` back.
- Add `identity: MacIdentity?` to `MachineSettings` (nil = legacy root machine).
- `MachineSettings.default` stays root/empty; the *creation path* (not the default) injects identity + home bind.

### A3. Default home bind + identity injection (`AppStore.createMachine`, AppStore.swift:1197)
Before `machineService.create(...)`, when identity is requested:
```
let id = MacIdentity.current(shell: chosenShell)
var s = settings
s.identity = id
if !s.mounts.contains(where: { $0.guest == id.homePath }) {
    s.mounts.append(MountPair(host: id.homePath, guest: id.homePath, readOnly: false))
}
```
The bind resolves because the VM already virtiofs-shares `$HOME` at the same path (SharedVMProvisioner.swift:105-112). Inside the machine, `/Users/<you>` is the live Mac home.

### A4. Provisioning (post-create exec, `MachineService.create` after `runtime.start`, ~line 138)
Run one non-interactive `runtime.exec` (DockerEngineRuntime.swift:258) of a `/bin/sh -c` script (skip when `settings.identity == nil`). Idempotent — safe to re-run on machine start to pick up new Mac keys:
```sh
set -e
U=<username>; UID=<uid>; SH=<shell>; HOME_DIR=<homePath>
# install the chosen non-bash shell via the known pkg manager (e.g. apt-get install -y zsh); bash is pre-baked
<pkgInstallShell if shell != /bin/bash>
command -v "$SH" >/dev/null 2>&1 || SH=/bin/bash
id -u "$U" >/dev/null 2>&1 || useradd -u "$UID" -M -d "$HOME_DIR" -s "$SH" "$U"
usermod -d "$HOME_DIR" -s "$SH" "$U" 2>/dev/null || true
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$U" > /etc/sudoers.d/dory-"$U"; chmod 440 /etc/sudoers.d/dory-"$U"
install -d -m755 /etc/dory
printf '%s\n' "<publicKeys joined by \\n>" > /etc/dory/authorized_keys; chmod 644 /etc/dory/authorized_keys
```
Notes:
- `useradd -M` (no home creation) because the home already exists as the live Mac mount; uid 501 makes ownership match virtiofs.
- The sshd half (AuthorizedKeysFile, ssh-keygen -A, enable sshd) is **Phase B** — Phase A provisions only the user + sudo + the keys file, so the terminal-as-you works immediately.

### A5. Machine metadata + model (`MachineService` labels + `Models.swift`)
- `createBody` (MachineService.swift:57) adds labels `dory.machine.user`, `dory.machine.shell` (and in Phase B, `dory.machine.sshPort`). Mirror them in `runFromImage` (snapshot/restore/edit keep identity).
- `struct Machine` (Models.swift:161) gains `var username = "root"`, `var loginShell = "/bin/sh"` (and Phase B `var sshPort: Int? = nil`), populated in `MachineService.machines()` from the labels with root/sh defaults (back-compatible with pre-WS4 machines).

### A6. Exec-as-user terminal (`TerminalLauncher`, `ContainerTerminalView`, `AppStore`)
- New shared builder (one source of truth): `TerminalLauncher.execArgs(user:shell:container:)` returns, for a non-root user, `exec -it -u <user> -w <homePath> <id> <shell> -l`; for root, the existing `exec -it <id> sh -c 'command -v bash >/dev/null && exec bash || exec sh'`.
- `ContainerTerminalView` gains optional `user`/`shell`/`home` props. `MachinesView` (machine terminal) passes `machine.username`/`loginShell`/home; `ContainerDetailView` (containers) passes nothing → stays root.
- `AppStore.openMachineTerminalApp` calls a new `TerminalLauncher.openMachineShell(...)` with the machine's user/shell; containers keep `openContainerShell`. Guard: if `username == "root"` (legacy/Alpine-fallback), use the root path.

### A7. Stepped creation flow + bug fix (`NewMachineSheet.swift`)
Redesign the single modal into a clean **stepped** flow (no blocking wizard required — a segmented step header over one sheet is fine):
1. **Distro** — family cards + version + arch + name (existing, restyled to the WS1 design system).
2. **Identity & Sharing** — provisioned user (shows your username, read-only), shell picker (bash/zsh/fish), a "Share my Mac home (read-write)" toggle (on by default; explains keys/files are shared), additional host-folder mounts (existing picker, must be under `$HOME` — validate and warn otherwise), and env vars (new `[KEY=VALUE]` rows → `MachineSettings.env`).
3. **Resources** — CPU/RAM steppers + exposed ports (existing).
- **Fix the silent-data-loss bug** (NewMachineSheet.swift:417-418): `collectedSettings()` must always read CPU/RAM/mounts/ports/identity from state, never gate on `advancedExpanded`.
- Machine **detail** pane shows the provisioned user, shell, shared home, and (Phase B) the SSH endpoint.

### A7b. Env vars
Add `var env: [String: String] = [:]` to `MachineSettings`; `createBody` merges into the container `Env` (alongside `container=docker`); `currentSettings` reads it back from the container config.

---

## Phase B — Real SSH, engine fixes, IDE Remote-SSH

### B1. Bake sshd + sudo into images (`MachineImageBuilder.swift:11-58`)
Add to each per-distro Dockerfile (static, stays in the cached `dory-machine/<image>-<arch>` image): apt → `openssh-server`; dnf → `openssh-server`; zypper → `openssh`; pacman → `openssh`; apk → `openssh` (+ `shadow`, already present). `sudo` is already installed on all. Bump any image-cache key if needed so existing users rebuild.

### B2. sshd provisioning (extends A4's post-create exec)
Append to the provisioning script:
```sh
mkdir -p /etc/ssh
grep -q '^AuthorizedKeysFile /etc/dory/authorized_keys' /etc/ssh/sshd_config 2>/dev/null \
  || printf '\nAuthorizedKeysFile /etc/dory/authorized_keys\nPasswordAuthentication no\n' >> /etc/ssh/sshd_config
ssh-keygen -A
# systemd: try both unit names; Alpine: launch directly
systemctl enable --now ssh 2>/dev/null || systemctl enable --now sshd 2>/dev/null || /usr/sbin/sshd
```
- `AuthorizedKeysFile /etc/dory/authorized_keys` is the key decision: inbound auth uses the machine-local keys file (seeded from Mac `*.pub`), never the mounted `~/.ssh/authorized_keys`.
- Alpine (non-systemd keepalive boot): launch `/usr/sbin/sshd` directly here and re-launch it from `MachineService.start` (MachineService.swift:156) so it survives restart.
- Idempotent: re-running refreshes `authorized_keys` when Mac keys change.

### B3. Engine fix — HostIp (`MachineService.hostConfig`, MachineService.swift:352)
Machine PortBindings hardcode `HostIp: 127.0.0.1`, which binds dockerd's publish to the VM's loopback only — unreachable from the Mac forwarder's direct-TCP path. **Omit `HostIp`** (→ dockerd binds 0.0.0.0) to match regular containers (DockerCreateModels.swift:40) and k3s (KubernetesProvisioner.swift:56), which are already host-reachable through the forwarder.

### B4. Engine fix — forward all published ports (`AppStore.containerEndpoints`, AppStore.swift:401-417)
`containerEndpoints` collapses each container to `.PublicPort.min()` (line 409), so a machine publishing both 22 and an app port forwards only the lower one. Keep the `min()` map for the `*.dory.local` HTTP DomainTable, but feed `forwarder.sync` the **set of every `PublicPort`** across all containers, so `22 → localhost:<port>` always gets a loopback listener.

### B5. Stable SSH host-port allocation (`AppStore.createMachine`)
Add a free-port helper (bind `127.0.0.1:0`, read `getsockname`, close, return — or probe a 320xx range). At create, append `PortPair(host: <allocated>, guest: 22)` to `settings.ports` and record `dory.machine.sshPort` label. The port persists in the container HostConfig and is read back by `currentSettings`, so it's stable across restart and edit/recreate (MachineService.recreate:223).

### B6. `dory ssh <machine>` (scripts/dory:42)
Replace the mis-wired `container machine run` line. Resolve the deterministic container `dory-machine-<name>`; prefer **real ssh** when port 22 is published: `exec ssh -p <hostPort> -o StrictHostKeyChecking=accept-new <user>@localhost` (reads the host port via `docker inspect`); fall back to `docker -H unix://$DORY_SOCK exec -it -u <user> -w <home> dory-machine-<name> <shell> -l`. Quote/default every capture (`set -euo pipefail`). Update `usage()`.

### B7. Surface SSH in the UI
Machine detail shows `ssh <you>@localhost -p <port>` (copyable) and a "Copy VS Code Remote-SSH" affordance. The provisioned-user + shared-home are shown from Phase A.

---

## Error handling

- **No engine / non-shared-VM runtime:** creation already gates on `engineReady` (NewMachineSheet.swift:45); identity provisioning only runs on the shared-VM dind path. Surface a clear notice otherwise.
- **Provisioning exec failure:** if the post-create exec returns non-zero, the machine still exists as a root box; surface the exec output via the global error toast and mark the machine "identity setup failed" (retry available). Never leave the user without *a* working machine.
- **Empty `~/.ssh`:** provisioning proceeds; sshd runs with no authorized keys (no inbound key login until keys are added) — not an error.
- **Shell missing in-guest:** validate `command -v <shell>`; fall back to `/bin/bash` then `/bin/sh`; record the actually-used shell in the label so exec-as-user can't pick a missing shell.
- **Non-`$HOME` mount requested:** validate in the UI and block with an explanation (would need an engine recreate) rather than silently failing at runtime.

## Testing

**Unit (`DoryTests/`, Swift `Testing`):**
- `MacIdentityTests` — `current(shell:)` reads username/uid/home; `publicKeys` concatenation; empty `~/.ssh` → `[]` (inject a temp dir).
- `MountPairTests` — `:ro` round-trips through `hostConfig` serialize + `currentSettings` parse.
- `ProvisioningScriptTests` — the generated provisioning script for each `PackageManager` contains the right `useradd -u 501 -M -d`, sudoers line, `AuthorizedKeysFile /etc/dory/authorized_keys`, and the correct sshd-enable form (systemd `ssh`/`sshd` vs Alpine direct); shell-meta in username is rejected/escaped.
- `MachineLabelsTests` — `createBody` emits `dory.machine.user/.shell/.sshPort`; `machines()` round-trips them with root/sh defaults for legacy machines.
- `HostConfigPortTests` — machine PortBindings omit `HostIp`; ssh port published as `22/tcp`.
- `ForwarderSetTests` — `containerEndpoints` set includes every `PublicPort` (not just min) for the forwarder while the DomainTable map stays min-per-name.
- `FreePortTests` — allocator returns a usable, unique port.
- `ExecArgsTests` — `TerminalLauncher.execArgs` builds `-u <user> -w <home> <shell> -l` for a user and the root form otherwise.
- `NewMachineSettingsTests` — `collectedSettings()` returns CPU/RAM/mounts/ports/env/identity regardless of `advancedExpanded` (the bug fix), and injects the `$HOME:$HOME` bind.

**Live verification (documented, run manually against the shared-VM engine):** create an Ubuntu machine → terminal opens as `<you>` in `/Users/<you>`, `sudo -n true` works, `git config user.name` reads your Mac config, `ls ~/.ssh` shows your keys; `ssh <you>@localhost -p <port>` logs in via key; VS Code Remote-SSH connects. Repeat for a dnf distro and Alpine. Build via the Xcode 27 `DEVELOPER_DIR`; snapshot via `scripts/shots.sh`.

## File structure

- **Create:** `Dory/Runtime/Machines/MacIdentity.swift`; `Dory/Runtime/Machines/MachineProvisioner.swift` (the provisioning-script builder, pure/testable).
- **Modify:** `Dory/Runtime/Machines/MachineService.swift` (MountPair `:ro`, identity in settings, labels, post-create provisioning, hostConfig HostIp + ssh port, currentSettings); `Dory/Runtime/Machines/MachineImageBuilder.swift` (bake sshd/sudo); `Dory/Models/Models.swift` (Machine username/loginShell/sshPort); `Dory/Models/AppStore.swift` (createMachine identity + home bind + free-port; containerEndpoints set; openMachineTerminalApp); `Dory/Net/TerminalLauncher.swift` + `Dory/Features/Containers/ContainerTerminalView.swift` (exec-as-user); `Dory/Features/Sheets/NewMachineSheet.swift` (stepped flow + bug fix + env); `Dory/Features/Machines/MachinesView.swift` (machine terminal user/shell, SSH endpoint in detail); `scripts/dory` (`dory ssh`).
- **Test:** new suites under `DoryTests/`.

## Non-goals (this cycle)

- Agent-sandbox credential proxy / egress firewall / read-restricted `~/.ssh` (future product).
- Sharing folders **outside** `$HOME` (needs a VM-level virtiofs share + engine recreate).
- Per-machine separate VMs or the not-yet-wired in-process `ContainerizationEngine` backend.
- The remote-access ("reach your machine from anywhere") workstream — that's the Tailscale-style phase, separate.
