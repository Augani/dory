# Machine SSH — Phase B Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every identity machine a real `sshd` reachable from the Mac at `ssh you@localhost -p <port>` (and IDE Remote-SSH), building on the Phase-A identity work already merged to `main`.

**Architecture:** Bake `openssh` into the per-distro images; flip the Phase-A provisioner's `includeSSH` branch on (it already writes `AuthorizedKeysFile /etc/dory/authorized_keys`, `ssh-keygen -A`, and enables sshd); fix two engine bugs so the published SSH port reaches the Mac (drop the `HostIp:127.0.0.1` bind; forward ALL published ports, not just the lowest); auto-allocate a stable host port mapped to container `22`; and surface it via `dory ssh` and the machine detail pane.

**Tech Stack:** Swift 6 / SwiftUI / macOS; `MachineService`/`MachineImageBuilder`/`HostPortForwarder`; `scripts/dory` (bash); Swift `Testing`.

## Global Constraints

- Build ONLY with `scripts/build.sh`; test ONLY with `scripts/test.sh` (Xcode 27 beta `DEVELOPER_DIR`). Never call `xcodebuild` directly. Runs take minutes.
- Synchronized Xcode folders — new `.swift` files under `Dory/`/`DoryTests/` auto-include; do NOT edit `Dory.xcodeproj/project.pbxproj`.
- IGNORE SourceKit/IDE diagnostics — false positives. `scripts/build.sh` (`BUILD SUCCEEDED`/`xcodebuild_exit=0`) and `scripts/test.sh` are authoritative.
- No inline comments; no docstrings. Self-documenting names. Tests use Swift `Testing`.
- **Inbound auth:** sshd uses `AuthorizedKeysFile /etc/dory/authorized_keys` (seeded from `~/.ssh/*.pub` by the Phase-A provisioner) — never `~/.ssh/authorized_keys`. `PasswordAuthentication no`.
- **sshd only for identity machines** (`settings.identity != nil`); legacy/root machines are unaffected.
- The Phase-A `MachineProvisioner.script(identity:pkg:isSystemd:includeSSH:)` ALREADY implements the `includeSSH: true` branch (sshd config + `ssh-keygen -A` + enable). Phase B turns it on and makes the port reachable — do NOT rewrite the provisioner's ssh lines.
- Back-compat: machines without a `dory.machine.sshPort` label → `Machine.sshPort == nil` (no SSH affordance shown).

---

### Task B1: Bake openssh into the machine images

**Files:**
- Modify: `Dory/Runtime/Machines/MachineImageBuilder.swift` (`dockerfile(for:)`)
- Test: `DoryTests/MachineImageSSHTests.swift`

**Interfaces:**
- Consumes: `MachineDistro` / `MachineDistro.PackageManager`.
- Produces: each per-distro Dockerfile installs the distro's openssh server package (static, baked into the cached `dory-machine/<image>-<arch>` image).

- [ ] **Step 1: Write the failing test**

`DoryTests/MachineImageSSHTests.swift`:
```swift
import Testing
@testable import Dory

struct MachineImageSSHTests {
    private func df(_ image: String) -> String { MachineImageBuilder.dockerfile(for: MachineDistro.forImage(image)!) }

    @Test func aptInstallsOpensshServer() { #expect(df("ubuntu:24.04").contains("openssh-server")) }
    @Test func dnfInstallsOpensshServer() { #expect(df("fedora:41").contains("openssh-server")) }
    @Test func zypperInstallsOpenssh() { #expect(df("opensuse/leap:15.6").contains("openssh")) }
    @Test func apkInstallsOpenssh() { #expect(df("alpine:3.21").contains("openssh")) }
    @Test func pacmanInstallsOpenssh() { #expect(df("archlinux:latest").contains("openssh")) }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test.sh -only-testing:DoryTests/MachineImageSSHTests`
Expected: FAIL — no openssh package in the Dockerfiles yet.

- [ ] **Step 3: Implement**

In `Dory/Runtime/Machines/MachineImageBuilder.swift`, add the openssh package to each branch's install command:
- `.apt`: in the `apt-get install -y --no-install-recommends ...` list, add `openssh-server` (e.g. after `sudo bash`).
- `.dnf`: change `dnf -y install systemd sudo passwd iproute procps-ng` → `... procps-ng openssh-server`.
- `.zypper`: change `zypper -n install systemd sudo iproute2` → `... iproute2 openssh`.
- `.apk`: change `apk add --no-cache bash sudo shadow iproute2 ca-certificates` → `... ca-certificates openssh`.
- `.pacman`: change `pacman -Sy --noconfirm --disable-sandbox --needed sudo iproute2` → `... iproute2 openssh`.

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/test.sh -only-testing:DoryTests/MachineImageSSHTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Dory/Runtime/Machines/MachineImageBuilder.swift DoryTests/MachineImageSSHTests.swift
git commit -m "feat(machines): bake openssh into per-distro machine images"
```

---

### Task B2: Enable sshd provisioning

**Files:**
- Modify: `Dory/Runtime/Machines/MachineService.swift` (`create` — flip `includeSSH`; `start` — re-launch sshd)
- Test: `DoryTests/SSHProvisioningTests.swift`

**Interfaces:**
- Consumes: `MachineProvisioner.script(...)` (its `includeSSH: true` branch), `MachineSettings.identity`.
- Produces: identity machines run sshd after creation and after restart.

- [ ] **Step 1: Write the failing test (asserts the provisioner's ssh output is what create() will run)**

`DoryTests/SSHProvisioningTests.swift`:
```swift
import Testing
@testable import Dory

struct SSHProvisioningTests {
    private let id = MacIdentity(username: "augustusotu", uid: 501, homePath: "/Users/augustusotu", shell: "/bin/bash", publicKeys: ["ssh-ed25519 AAAA me"])

    @Test func systemdScriptEnablesSshAndAuthorizedKeysFile() {
        let s = MachineProvisioner.script(identity: id, pkg: .apt, isSystemd: true, includeSSH: true)
        #expect(s.contains("AuthorizedKeysFile /etc/dory/authorized_keys"))
        #expect(s.contains("PasswordAuthentication no"))
        #expect(s.contains("ssh-keygen -A"))
        #expect(s.contains("systemctl enable --now ssh"))
    }

    @Test func alpineScriptLaunchesSshdDirectly() {
        let s = MachineProvisioner.script(identity: id, pkg: .apk, isSystemd: false, includeSSH: true)
        #expect(s.contains("ssh-keygen -A"))
        #expect(s.contains("/usr/sbin/sshd"))
        #expect(!s.contains("systemctl enable"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails or passes**

Run: `scripts/test.sh -only-testing:DoryTests/SSHProvisioningTests`
Note: the Phase-A `MachineProvisioner` already implements the `includeSSH: true` branch, so these tests may PASS immediately — that is fine; they pin the contract that `create()` now relies on. If any assertion fails, the provisioner's ssh branch is wrong and must be corrected to satisfy these (do NOT weaken the test).

- [ ] **Step 3: Flip includeSSH on in create() + re-launch sshd in start()**

In `MachineService.create`, the Phase-A provisioning block currently calls `MachineProvisioner.script(..., includeSSH: false)`. Change it to gate on identity:
```swift
        if let identity = settings.identity {
            progress("Setting up \(identity.username)…")
            let script = MachineProvisioner.script(identity: identity, pkg: distro.pkg, isSystemd: distro.boot == .systemd, includeSSH: true)
            let result = try? await runtime.exec(containerID: Self.containerName(for: name), command: ["/bin/sh", "-c", script])
            if let result, !result.succeeded { progress("Identity setup reported: \(result.output)") }
        }
```
In `MachineService.start(name:)`, after `runtime.start`, best-effort re-launch sshd (no-op for systemd machines where it's already running, and for non-sshd machines where sshd is absent):
```swift
    func start(name: String) async throws {
        try await runtime.start(containerID: Self.containerName(for: name))
        _ = try? await runtime.exec(containerID: Self.containerName(for: name),
                                    command: ["/bin/sh", "-c", "command -v sshd >/dev/null 2>&1 && (pgrep -x sshd >/dev/null 2>&1 || /usr/sbin/sshd 2>/dev/null) || true"])
    }
```

- [ ] **Step 4: Run test to verify it passes + build**

Run: `scripts/test.sh -only-testing:DoryTests/SSHProvisioningTests`
Expected: PASS (2 tests).
Run: `scripts/build.sh`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
git add Dory/Runtime/Machines/MachineService.swift DoryTests/SSHProvisioningTests.swift
git commit -m "feat(machines): enable sshd provisioning for identity machines + re-launch on start"
```

---

### Task B3: Engine port reachability — drop HostIp, forward all ports

**Files:**
- Modify: `Dory/Runtime/Machines/MachineService.swift` (`hostConfig` PortBindings — omit `HostIp`); `Dory/Models/AppStore.swift` (add `publicPorts(fromContainersJSON:)` + `allPublishedPorts`; wire `forwarder.sync` to all ports)
- Test: `DoryTests/PortReachabilityTests.swift`

**Interfaces:**
- Produces: `static func MachineService.... ` (hostConfig change, no new symbol); `static func AppStore.publicPorts(fromContainersJSON: Data) -> Set<Int>`; `static func AppStore.allPublishedPorts(_ runtime: any ContainerRuntime) async -> Set<Int>`.

- [ ] **Step 1: Write the failing test**

`DoryTests/PortReachabilityTests.swift`:
```swift
import Testing
import Foundation
@testable import Dory

struct PortReachabilityTests {
    @Test func machinePortBindingHasNoHostIp() {
        let s = MachineSettings(cpus: nil, memoryMB: nil, mounts: [], ports: [PortPair(host: 32001, guest: 22)])
        let host = MachineService.hostConfig(base: [:], settings: s)
        let bindings = host["PortBindings"] as! [String: [[String: String]]]
        let entry = bindings["22/tcp"]!.first!
        #expect(entry["HostPort"] == "32001")
        #expect(entry["HostIp"] == nil)
    }

    @Test func publicPortsDecodesEveryPort() {
        let json = """
        [{"Ports":[{"PublicPort":32001},{"PublicPort":8080}]},{"Ports":[{"PublicPort":5432}]},{"Ports":[]}]
        """.data(using: .utf8)!
        #expect(AppStore.publicPorts(fromContainersJSON: json) == [32001, 8080, 5432])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test.sh -only-testing:DoryTests/PortReachabilityTests`
Expected: FAIL — `HostIp` still present; `publicPorts` not found.

- [ ] **Step 3: Implement**

In `MachineService.hostConfig`, change the PortBindings construction to omit `HostIp`:
```swift
                bindings["\(port.guest)/tcp"] = [["HostPort": "\(port.host)"]]
```
In `AppStore.swift`, add a pure decoder + the async collector (near `containerEndpoints`):
```swift
    static func publicPorts(fromContainersJSON data: Data) -> Set<Int> {
        struct Entry: Decodable { let Ports: [PortItem]? }
        struct PortItem: Decodable { let PublicPort: Int? }
        guard let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return Set(entries.flatMap { ($0.Ports ?? []).compactMap(\.PublicPort) })
    }

    static func allPublishedPorts(_ runtime: any ContainerRuntime) async -> Set<Int> {
        guard let response = await runtime.proxyRequest(method: "GET", path: "/containers/json", headers: [], body: Data()),
              response.isSuccess else { return [] }
        return publicPorts(fromContainersJSON: response.body)
    }
```
In the forwarding loop (`startPortForwarding`), replace `forwarder.sync(ports: Set(endpoints.values))` with all published ports (the per-name `endpoints` map still feeds the DomainTable):
```swift
                    let endpoints = await Self.containerEndpoints(runtime, suffix: suffix)
                    forwarder.sync(ports: await Self.allPublishedPorts(runtime))
                    table.replaceContainers(endpoints)
```

- [ ] **Step 4: Run test to verify it passes + build**

Run: `scripts/test.sh -only-testing:DoryTests/PortReachabilityTests`
Expected: PASS (2 tests).
Run: `scripts/build.sh`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
git add Dory/Runtime/Machines/MachineService.swift Dory/Models/AppStore.swift DoryTests/PortReachabilityTests.swift
git commit -m "fix(machines): omit HostIp on machine port bindings + forward all published ports"
```

---

### Task B4: SSH port allocation + label + model

**Files:**
- Modify: `Dory/Models/AppStore.swift` (`allocateFreePort`; `createMachine` appends the 22 port), `Dory/Runtime/Machines/MachineService.swift` (`sshPortLabel`; `createBody`/`runFromImage` emit it; `machines()` decode), `Dory/Models/Models.swift` (`Machine.sshPort`)
- Test: `DoryTests/SSHPortTests.swift`

**Interfaces:**
- Consumes: `MachineSettings.ports` (`PortPair`), `AppStore.withIdentity` (A5).
- Produces: `static func AppStore.allocateFreePort() -> Int`; `MachineService.sshPortLabel = "dory.machine.sshPort"`; `Machine.sshPort: Int?`.

- [ ] **Step 1: Write the failing test**

`DoryTests/SSHPortTests.swift`:
```swift
import Testing
import Foundation
@testable import Dory

struct SSHPortTests {
    @Test func allocatesUsablePort() {
        let p = AppStore.allocateFreePort()
        #expect(p > 1024 && p <= 65535)
    }

    @Test func createBodyEmitsSshPortLabelWhenPort22Published() {
        let distro = MachineDistro.forImage("ubuntu:24.04")!
        var s = MachineSettings.default
        s.identity = MacIdentity(username: "u", uid: 501, homePath: "/Users/u", shell: "/bin/bash", publicKeys: [])
        s.ports = [PortPair(host: 32005, guest: 22)]
        let body = MachineService.createBody(name: "m", distro: distro, arch: .arm64, imageTag: "t", keepaliveOnly: false, settings: s)
        let labels = body["Labels"] as! [String: String]
        #expect(labels[MachineService.sshPortLabel] == "32005")
    }

    @Test func machinesDecodeSshPort() {
        let json = """
        [{"Id":"a","Names":["/dory-machine-m"],"State":"running","Labels":{"dory.machine":"ubuntu","dory.machine.sshPort":"32005"}}]
        """.data(using: .utf8)!
        #expect(MachineService.machines(fromContainersJSON: json).first?.sshPort == 32005)
    }

    @Test func legacyMachineHasNilSshPort() {
        let json = """
        [{"Id":"a","Names":["/dory-machine-m"],"State":"running","Labels":{"dory.machine":"ubuntu"}}]
        """.data(using: .utf8)!
        #expect(MachineService.machines(fromContainersJSON: json).first?.sshPort == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test.sh -only-testing:DoryTests/SSHPortTests`
Expected: FAIL — `allocateFreePort`/`sshPortLabel`/`Machine.sshPort` not found.

- [ ] **Step 3: Implement**

`Dory/Models/Models.swift` — add to `struct Machine` after `var loginShell`:
```swift
    var sshPort: Int? = nil
```
`Dory/Runtime/Machines/MachineService.swift`:
- Add the label constant near `userLabel`:
```swift
    static let sshPortLabel = "dory.machine.sshPort"
```
- In `createBody`, after the identity labels, emit the ssh-port label when a port maps guest 22:
```swift
        if let sshPort = settings.ports.first(where: { $0.guest == 22 })?.host {
            labels[sshPortLabel] = "\(sshPort)"
        }
```
- Mirror the same in `runFromImage` (so edit/recreate keeps the ssh port label).
- In `machines()`, add to the returned `Machine`:
```swift
                sshPort: entry.Labels?[sshPortLabel].flatMap { Int($0) }
```
`Dory/Models/AppStore.swift`:
- Add the allocator:
```swift
    static func allocateFreePort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return 0 }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { return 0 }
        var result = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let got = withUnsafeMutablePointer(to: &result) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        guard got == 0 else { return 0 }
        return Int(UInt16(bigEndian: result.sin_port))
    }
```
- In `createMachine`, where identity is injected, also append the ssh port. Change the `effectiveSettings` computation:
```swift
        var effectiveSettings = identity.map { Self.withIdentity(settings, $0) } ?? settings
        if effectiveSettings.identity != nil, !effectiveSettings.ports.contains(where: { $0.guest == 22 }) {
            effectiveSettings.ports.append(PortPair(host: Self.allocateFreePort(), guest: 22))
        }
```

- [ ] **Step 4: Run test to verify it passes + build**

Run: `scripts/test.sh -only-testing:DoryTests/SSHPortTests`
Expected: PASS (4 tests).
Run: `scripts/build.sh`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
git add Dory/Models/AppStore.swift Dory/Runtime/Machines/MachineService.swift Dory/Models/Models.swift DoryTests/SSHPortTests.swift
git commit -m "feat(machines): allocate a stable SSH host port (22 published) + sshPort label/model"
```

---

### Task B5: `dory ssh` + machine-detail SSH endpoint

**Files:**
- Modify: `scripts/dory` (the `ssh)` case + `usage`), `Dory/Features/Machines/MachinesView.swift` (machine detail SSH row)

**Interfaces:**
- Consumes: the `dory.machine.user`/`.shell`/`.sshPort` labels (B4/A4), `Machine.sshPort`/`username` (B4/A4).

This task has a bash portion (no Swift unit test — verified by `bash -n` + manual smoke) and a SwiftUI portion (build-verified).

- [ ] **Step 1: Rewrite the `dory ssh` case**

In `scripts/dory`, replace the `ssh)` line (currently `exec "$CONTAINER_BIN" machine run -n "$2"`) with a real-ssh-preferred handler:
```bash
  ssh)            shift
                  name="${1:?usage: dory ssh <machine>}"
                  cid="dory-machine-$name"
                  user="$(docker -H "unix://$DORY_SOCK" inspect -f '{{index .Config.Labels "dory.machine.user"}}' "$cid" 2>/dev/null || true)"; user="${user:-root}"
                  shell="$(docker -H "unix://$DORY_SOCK" inspect -f '{{index .Config.Labels "dory.machine.shell"}}' "$cid" 2>/dev/null || true)"; shell="${shell:-/bin/sh}"
                  port="$(docker -H "unix://$DORY_SOCK" inspect -f '{{index .Config.Labels "dory.machine.sshPort"}}' "$cid" 2>/dev/null || true)"
                  if [ -n "$port" ]; then
                    exec ssh -p "$port" -o StrictHostKeyChecking=accept-new "$user@localhost"
                  else
                    home="/Users/$user"; [ "$user" = "root" ] && home="/root"
                    exec docker -H "unix://$DORY_SOCK" exec -it -u "$user" -w "$home" "$cid" "$shell" -l
                  fi ;;
```
Update the `usage()` line for `dory ssh` to: `  dory ssh <machine>           SSH into a Linux machine as you (real ssh when available)`.

- [ ] **Step 2: Syntax-check the script**

Run: `bash -n scripts/dory`
Expected: no output (valid syntax).

- [ ] **Step 3: Add the SSH endpoint to the machine detail**

In `Dory/Features/Machines/MachinesView.swift`, in the machine detail area (near the identity row added in Phase A's M4 fix), add a copyable SSH row when `machine.sshPort != nil`:
```swift
            if let port = machine.sshPort {
                HStack(spacing: 6) {
                    Image(systemName: "terminal").font(.system(size: 11)).foregroundStyle(p.text3)
                    Text("ssh \(machine.username)@localhost -p \(port)").font(.mono(11)).foregroundStyle(p.text2).lineLimit(1)
                    Spacer(minLength: 0)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("ssh \(machine.username)@localhost -p \(port)", forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc").font(.system(size: 10)).foregroundStyle(p.text3)
                    }.buttonStyle(.plain)
                }
            }
```
(Match the surrounding detail row styling; reuse the file's palette + fonts. Place it next to the Phase-A identity row.)

- [ ] **Step 4: Build**

Run: `scripts/build.sh`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Visual check**

Run: `scripts/shots.sh`. Confirm a machine detail shows the `ssh …@localhost -p <port>` line (for an identity machine). If the snapshot harness can't reach the machine detail, note it; build is the gate.

- [ ] **Step 6: Commit**

```bash
git add scripts/dory Dory/Features/Machines/MachinesView.swift
git commit -m "feat(machines): dory ssh (real ssh) + machine-detail SSH endpoint"
```

---

## Live verification (manual, after all tasks — documents the end-to-end SSH path)

Against the shared-VM engine: create an Ubuntu machine (identity on) → `dory ssh ubuntu` logs in via key as you; `ssh you@localhost -p <port>` from a fresh terminal works; VS Code "Remote-SSH: Connect to Host… localhost:<port>" opens the machine; `sudo -n true` works; `git config user.name` reads your Mac config. Repeat for a dnf distro (fedora) and Alpine (confirm the start() re-launch keeps sshd up after a stop/start). Build via the Xcode 27 `DEVELOPER_DIR`.

## Self-review notes (addressed)

- **Spec coverage (Phase B):** B1 bakes openssh (spec B1); B2 enables sshd + Alpine re-launch (spec B2); B3 fixes HostIp + forwards all ports (spec B3, B4); B4 allocates the stable port + label/model (spec B5); B5 `dory ssh` + UI endpoint (spec B6, B7). All Phase-B spec sections map to a task.
- **Type consistency:** `MachineService.sshPortLabel`, `Machine.sshPort`, `AppStore.allocateFreePort`/`publicPorts`/`allPublishedPorts`, the `includeSSH: true` flip — defined once and consumed consistently. The provisioner's `includeSSH` branch is reused from Phase A, not redefined.
- **Reuse:** the per-name `containerEndpoints` map (HTTP DomainTable routing) is preserved; only the forwarder's port set is widened to all published ports — no duplication.
- **Deferred Phase-A M3 (env on edit/recreate):** still open; out of Phase B's SSH scope. Track separately.
- **`dory ssh` has no Swift unit test** (it's bash); verified by `bash -n` + the documented live smoke. The Swift-side ssh-port labels/model that the script reads ARE unit-tested (B4).
