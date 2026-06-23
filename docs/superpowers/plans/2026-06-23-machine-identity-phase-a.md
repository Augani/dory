# Machine Identity — Phase A Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a new Linux machine auto-provision a passwordless-sudo user matching your macOS account (uid 501), mount your live Mac home as that user's home, and open the terminal/`dory ssh` as you — not root. (Phase B adds real sshd + the engine fixes; this phase is shippable on its own.)

**Architecture:** A machine is a Privileged systemd container in Dory's shared-VM dind engine, which already virtiofs-shares your Mac `$HOME` at the same path. We add a Mac-side identity reader, a pure provisioning-script builder, a post-create `docker exec` that creates the user/sudo/keys-file, a default `$HOME:$HOME` bind, exec-as-user terminals, and a stepped creation UI (fixing the silent-data-loss bug).

**Tech Stack:** Swift 6 / SwiftUI / macOS; `MachineService` over `any ContainerRuntime`; Swift `Testing`.

## Global Constraints

- Build ONLY with `scripts/build.sh`; test ONLY with `scripts/test.sh` (both export the Xcode 27 beta `DEVELOPER_DIR`). Never call `xcodebuild` directly. Runs take minutes — expected.
- The Xcode project uses synchronized folders — new `.swift` files under `Dory/` and `DoryTests/` are auto-included; do NOT edit `Dory.xcodeproj/project.pbxproj`.
- IGNORE SourceKit/IDE "cannot find" diagnostics — false positives from the IDE toolchain. `scripts/build.sh` (`BUILD SUCCEEDED`/`xcodebuild_exit=0`) and `scripts/test.sh` are authoritative.
- No inline comments; no docstrings except on public-API surfaces. Self-documenting names. Tests use Swift `Testing` (`import Testing`, `@Test`, `#expect`), `@MainActor` for AppStore tests, `import Foundation` where needed.
- **User:** `NSUserName()`, **uid 501** (`Int(getuid())`), passwordless sudo. **Home:** mirrored `$HOME` (the user's Linux home IS `/Users/<you>`), read-write. **Shell:** bash default, picker bash/zsh/fish (non-bash installed via pkg manager during provisioning).
- **Inbound SSH auth** (Phase B) will use `AuthorizedKeysFile /etc/dory/authorized_keys`; Phase A already writes that file from the Mac's `~/.ssh/*.pub` — it must NEVER write to the mounted `~/.ssh/authorized_keys`.
- Only paths under `$HOME` are shareable (the single VM virtiofs share is rooted at `$HOME`); reject non-`$HOME` mounts in the UI.
- Back-compat: machines created before WS4 have no identity labels → default to `root`/`/bin/sh` everywhere.

---

### Task A1: MacIdentity reader

**Files:**
- Create: `Dory/Runtime/Machines/MacIdentity.swift`
- Test: `DoryTests/MacIdentityTests.swift`

**Interfaces:**
- Produces: `struct MacIdentity: Sendable, Hashable { let username: String; let uid: Int; let homePath: String; let shell: String; let publicKeys: [String] }`; `static func current(shell: String = "/bin/bash") -> MacIdentity`; `static func make(username: String, uid: Int, homePath: String, shell: String, sshDir: String) -> MacIdentity` (reads `*.pub` from `sshDir` — the testable seam).

- [ ] **Step 1: Write the failing test**

`DoryTests/MacIdentityTests.swift`:
```swift
import Testing
import Foundation
@testable import Dory

struct MacIdentityTests {
    private func tempSSH(_ pubs: [String: String]) -> String {
        let dir = NSTemporaryDirectory() + "ssh-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for (name, body) in pubs { try? body.write(toFile: dir + "/" + name, atomically: true, encoding: .utf8) }
        return dir
    }

    @Test func readsPublicKeysFromSSHDir() {
        let dir = tempSSH(["id_ed25519.pub": "ssh-ed25519 AAAA me\n", "id_rsa.pub": "ssh-rsa BBBB me\n", "config": "Host x\n"])
        let id = MacIdentity.make(username: "augustusotu", uid: 501, homePath: "/Users/augustusotu", shell: "/bin/bash", sshDir: dir)
        #expect(id.username == "augustusotu")
        #expect(id.uid == 501)
        #expect(id.homePath == "/Users/augustusotu")
        #expect(Set(id.publicKeys) == ["ssh-ed25519 AAAA me", "ssh-rsa BBBB me"])
    }

    @Test func emptySSHDirYieldsNoKeys() {
        let id = MacIdentity.make(username: "u", uid: 501, homePath: "/Users/u", shell: "/bin/bash", sshDir: tempSSH([:]))
        #expect(id.publicKeys.isEmpty)
    }

    @Test func currentPopulatesFromMac() {
        let id = MacIdentity.current()
        #expect(!id.username.isEmpty)
        #expect(id.homePath == NSHomeDirectory())
        #expect(id.shell == "/bin/bash")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test.sh -only-testing:DoryTests/MacIdentityTests`
Expected: FAIL — `cannot find 'MacIdentity' in scope`.

- [ ] **Step 3: Write the implementation**

`Dory/Runtime/Machines/MacIdentity.swift`:
```swift
import Foundation

struct MacIdentity: Sendable, Hashable {
    let username: String
    let uid: Int
    let homePath: String
    let shell: String
    let publicKeys: [String]

    static func current(shell: String = "/bin/bash") -> MacIdentity {
        make(username: NSUserName(), uid: Int(getuid()), homePath: NSHomeDirectory(),
             shell: shell, sshDir: NSHomeDirectory() + "/.ssh")
    }

    static func make(username: String, uid: Int, homePath: String, shell: String, sshDir: String) -> MacIdentity {
        let keys = (try? FileManager.default.contentsOfDirectory(atPath: sshDir))?
            .filter { $0.hasSuffix(".pub") }
            .compactMap { try? String(contentsOfFile: sshDir + "/" + $0, encoding: .utf8) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            ?? []
        return MacIdentity(username: username, uid: uid, homePath: homePath, shell: shell, publicKeys: keys.sorted())
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/test.sh -only-testing:DoryTests/MacIdentityTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Dory/Runtime/Machines/MacIdentity.swift DoryTests/MacIdentityTests.swift
git commit -m "feat(machines): MacIdentity reader (username/uid/home/shell/pubkeys)"
```

---

### Task A2: MountPair read-only + bind helpers

**Files:**
- Modify: `Dory/Runtime/Machines/MachineService.swift:3` (MountPair), `:346` (hostConfig Binds), `:281-284` (currentSettings parse)
- Test: `DoryTests/MountBindTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: `struct MountPair { var host: String; var guest: String; var readOnly: Bool = false }`; `static func bindString(_ m: MountPair) -> String`; `static func parseBind(_ s: String) -> MountPair?`.

- [ ] **Step 1: Write the failing test**

`DoryTests/MountBindTests.swift`:
```swift
import Testing
@testable import Dory

struct MountBindTests {
    @Test func readWriteBindString() {
        #expect(MachineService.bindString(MountPair(host: "/Users/u", guest: "/Users/u")) == "/Users/u:/Users/u")
    }

    @Test func readOnlyBindString() {
        #expect(MachineService.bindString(MountPair(host: "/a", guest: "/b", readOnly: true)) == "/a:/b:ro")
    }

    @Test func parsesReadWrite() {
        #expect(MachineService.parseBind("/Users/u:/Users/u") == MountPair(host: "/Users/u", guest: "/Users/u"))
    }

    @Test func parsesReadOnly() {
        #expect(MachineService.parseBind("/a:/b:ro") == MountPair(host: "/a", guest: "/b", readOnly: true))
    }

    @Test func roundTrip() {
        let m = MountPair(host: "/x/y", guest: "/z", readOnly: true)
        #expect(MachineService.parseBind(MachineService.bindString(m)) == m)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test.sh -only-testing:DoryTests/MountBindTests`
Expected: FAIL — `MountPair` has no `readOnly`; `bindString`/`parseBind` not found.

- [ ] **Step 3: Implement**

In `Dory/Runtime/Machines/MachineService.swift`, change line 3:
```swift
struct MountPair: Sendable, Hashable { var host: String; var guest: String; var readOnly: Bool = false }
```
Add to the `extension MachineService` (near `hostConfig`):
```swift
    static func bindString(_ m: MountPair) -> String { m.readOnly ? "\(m.host):\(m.guest):ro" : "\(m.host):\(m.guest)" }

    static func parseBind(_ s: String) -> MountPair? {
        let parts = s.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return nil }
        return MountPair(host: parts[0], guest: parts[1], readOnly: parts.count == 3 && parts[2] == "ro")
    }
```
Change `hostConfig` (line 346) to use the helper:
```swift
        if !settings.mounts.isEmpty { host["Binds"] = settings.mounts.map(Self.bindString) }
```
Change `currentSettings` mounts parse (lines 281-284) to:
```swift
        let mounts: [MountPair] = (host.Binds ?? []).compactMap { Self.parseBind($0) }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/test.sh -only-testing:DoryTests/MountBindTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Build (confirm callers still compile)**

Run: `scripts/build.sh`
Expected: `BUILD SUCCEEDED` (MountPair gets a defaulted field; existing `MountPair(host:guest:)` call sites in NewMachineSheet/MachineService still compile).

- [ ] **Step 6: Commit**

```bash
git add Dory/Runtime/Machines/MachineService.swift DoryTests/MountBindTests.swift
git commit -m "feat(machines): MountPair read-only flag + bind string round-trip"
```

---

### Task A3: MachineProvisioner script builder

**Files:**
- Create: `Dory/Runtime/Machines/MachineProvisioner.swift`
- Test: `DoryTests/MachineProvisionerTests.swift`

**Interfaces:**
- Consumes: `MacIdentity` (A1), `MachineDistro.PackageManager`.
- Produces: `enum MachineProvisioner { static func script(identity: MacIdentity, pkg: MachineDistro.PackageManager, isSystemd: Bool, includeSSH: Bool) -> String }`. Phase A always calls with `includeSSH: false`; the `includeSSH` branch (sshd) is exercised in Phase B but defined now.

- [ ] **Step 1: Write the failing test**

`DoryTests/MachineProvisionerTests.swift`:
```swift
import Testing
@testable import Dory

struct MachineProvisionerTests {
    private func id(_ shell: String = "/bin/bash", keys: [String] = ["ssh-ed25519 AAAA me"]) -> MacIdentity {
        MacIdentity(username: "augustusotu", uid: 501, homePath: "/Users/augustusotu", shell: shell, publicKeys: keys)
    }

    @Test func createsUserWithUid501AndMirroredHome() {
        let s = MachineProvisioner.script(identity: id(), pkg: .apt, isSystemd: true, includeSSH: false)
        #expect(s.contains("useradd -u 501 -M -d /Users/augustusotu -s /bin/bash augustusotu"))
        #expect(s.contains("/etc/sudoers.d/dory-augustusotu"))
        #expect(s.contains("NOPASSWD:ALL"))
    }

    @Test func seedsAuthorizedKeysFileNotHome() {
        let s = MachineProvisioner.script(identity: id(), pkg: .apt, isSystemd: true, includeSSH: false)
        #expect(s.contains("/etc/dory/authorized_keys"))
        #expect(s.contains("ssh-ed25519 AAAA me"))
        #expect(!s.contains("/Users/augustusotu/.ssh/authorized_keys"))
    }

    @Test func installsNonBashShellViaPkg() {
        #expect(MachineProvisioner.script(identity: id("/bin/zsh"), pkg: .apt, isSystemd: true, includeSSH: false).contains("apt-get install -y zsh"))
        #expect(MachineProvisioner.script(identity: id("/usr/bin/fish"), pkg: .dnf, isSystemd: true, includeSSH: false).contains("dnf install -y fish"))
        #expect(MachineProvisioner.script(identity: id("/usr/bin/zsh"), pkg: .pacman, isSystemd: true, includeSSH: false).contains("pacman -Sy --noconfirm zsh"))
    }

    @Test func bashShellSkipsInstall() {
        #expect(!MachineProvisioner.script(identity: id("/bin/bash"), pkg: .apt, isSystemd: true, includeSSH: false).contains("install -y bash"))
    }

    @Test func sshOmittedWhenIncludeSSHFalse() {
        let s = MachineProvisioner.script(identity: id(), pkg: .apt, isSystemd: true, includeSSH: false)
        #expect(!s.contains("ssh-keygen -A"))
        #expect(!s.contains("AuthorizedKeysFile"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test.sh -only-testing:DoryTests/MachineProvisionerTests`
Expected: FAIL — `cannot find 'MachineProvisioner' in scope`.

- [ ] **Step 3: Implement**

`Dory/Runtime/Machines/MachineProvisioner.swift`:
```swift
import Foundation

enum MachineProvisioner {
    static func script(identity: MacIdentity, pkg: MachineDistro.PackageManager, isSystemd: Bool, includeSSH: Bool) -> String {
        let user = shellQuote(identity.username)
        let home = shellQuote(identity.homePath)
        let shellPath = identity.shell
        let keys = identity.publicKeys.joined(separator: "\n")
        var lines: [String] = ["set -e"]
        if let install = shellInstall(shellPath, pkg: pkg) { lines.append(install) }
        lines.append("SH=\(shellQuote(shellPath)); command -v \"$SH\" >/dev/null 2>&1 || SH=/bin/bash; command -v \"$SH\" >/dev/null 2>&1 || SH=/bin/sh")
        lines.append("id -u \(user) >/dev/null 2>&1 || useradd -u \(identity.uid) -M -d \(home) -s \"$SH\" \(user)")
        lines.append("usermod -d \(home) -s \"$SH\" \(user) 2>/dev/null || true")
        lines.append("printf '%s ALL=(ALL) NOPASSWD:ALL\\n' \(user) > /etc/sudoers.d/dory-\(identity.username); chmod 440 /etc/sudoers.d/dory-\(identity.username)")
        lines.append("install -d -m755 /etc/dory")
        lines.append("printf '%s\\n' \(shellQuote(keys)) > /etc/dory/authorized_keys; chmod 644 /etc/dory/authorized_keys")
        if includeSSH {
            lines.append("mkdir -p /etc/ssh")
            lines.append("grep -q '^AuthorizedKeysFile /etc/dory/authorized_keys' /etc/ssh/sshd_config 2>/dev/null || printf '\\nAuthorizedKeysFile /etc/dory/authorized_keys\\nPasswordAuthentication no\\n' >> /etc/ssh/sshd_config")
            lines.append("ssh-keygen -A")
            if isSystemd {
                lines.append("systemctl enable --now ssh 2>/dev/null || systemctl enable --now sshd 2>/dev/null || /usr/sbin/sshd")
            } else {
                lines.append("/usr/sbin/sshd")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func shellInstall(_ shell: String, pkg: MachineDistro.PackageManager) -> String? {
        let name = (shell as NSString).lastPathComponent
        guard name != "bash", name != "sh" else { return nil }
        switch pkg {
        case .apt: return "apt-get update -qq && apt-get install -y \(name)"
        case .dnf: return "dnf install -y \(name)"
        case .zypper: return "zypper -n install \(name)"
        case .apk: return "apk add \(name)"
        case .pacman: return "pacman -Sy --noconfirm \(name)"
        }
    }

    private static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/test.sh -only-testing:DoryTests/MachineProvisionerTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Dory/Runtime/Machines/MachineProvisioner.swift DoryTests/MachineProvisionerTests.swift
git commit -m "feat(machines): pure provisioning-script builder (user/sudo/keys; ssh behind flag)"
```

---

### Task A4: Identity in settings + labels + Machine model

**Files:**
- Modify: `Dory/Runtime/Machines/MachineService.swift` (`MachineSettings` :5, label constants :17-20, `createBody` :54-78, `runFromImage` :187-193, `machines()` :96-109), `Dory/Models/Models.swift` (`Machine` struct)
- Test: `DoryTests/MachineIdentityLabelTests.swift`

**Interfaces:**
- Consumes: `MacIdentity` (A1).
- Produces: `MachineSettings` gains `var identity: MacIdentity? = nil` and `var env: [String: String] = [:]`; `MachineService.userLabel = "dory.machine.user"`, `MachineService.shellLabel = "dory.machine.shell"`; `Machine` gains `var username = "root"`, `var loginShell = "/bin/sh"`.

- [ ] **Step 1: Write the failing test**

`DoryTests/MachineIdentityLabelTests.swift`:
```swift
import Testing
import Foundation
@testable import Dory

struct MachineIdentityLabelTests {
    private let distro = MachineDistro.forImage("ubuntu:24.04")!

    @Test func createBodyEmitsUserShellLabelsAndEnv() {
        let id = MacIdentity(username: "augustusotu", uid: 501, homePath: "/Users/augustusotu", shell: "/bin/bash", publicKeys: [])
        var s = MachineSettings.default
        s.identity = id
        s.env = ["FOO": "bar"]
        let body = MachineService.createBody(name: "m", distro: distro, arch: .arm64, imageTag: "t", keepaliveOnly: false, settings: s)
        let labels = body["Labels"] as! [String: String]
        #expect(labels[MachineService.userLabel] == "augustusotu")
        #expect(labels[MachineService.shellLabel] == "/bin/bash")
        let env = body["Env"] as! [String]
        #expect(env.contains("FOO=bar"))
        #expect(env.contains("container=docker"))
    }

    @Test func machinesDecodeUserShellLabels() {
        let json = """
        [{"Id":"abc","Names":["/dory-machine-m"],"State":"running","Labels":{"dory.machine":"ubuntu","dory.machine.user":"augustusotu","dory.machine.shell":"/bin/bash"}}]
        """.data(using: .utf8)!
        let machines = MachineService.machines(fromContainersJSON: json)
        #expect(machines.first?.username == "augustusotu")
        #expect(machines.first?.loginShell == "/bin/bash")
    }

    @Test func legacyMachineDefaultsToRoot() {
        let json = """
        [{"Id":"abc","Names":["/dory-machine-m"],"State":"running","Labels":{"dory.machine":"ubuntu"}}]
        """.data(using: .utf8)!
        let machines = MachineService.machines(fromContainersJSON: json)
        #expect(machines.first?.username == "root")
        #expect(machines.first?.loginShell == "/bin/sh")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test.sh -only-testing:DoryTests/MachineIdentityLabelTests`
Expected: FAIL — `MachineSettings` has no `identity`/`env`; `userLabel` not found; `Machine` has no `username`.

- [ ] **Step 3: Implement**

`Dory/Models/Models.swift` — add to `struct Machine` after `var recipe: String = ""`:
```swift
    var username: String = "root"
    var loginShell: String = "/bin/sh"
```

`Dory/Runtime/Machines/MachineService.swift`:
- `MachineSettings` (line 5) — add fields:
```swift
    var identity: MacIdentity? = nil
    var env: [String: String] = [:]
```
- Add label constants near line 20:
```swift
    static let userLabel = "dory.machine.user"
    static let shellLabel = "dory.machine.shell"
```
- `createBody` (lines 57, 71) — after building `labels`, add identity labels; merge env. Replace the `Env` line and add to labels:
```swift
        var labels = [label: distro.family, versionLabel: distro.version, archLabel: arch.rawValue]
        if let recipe { labels[recipeLabel] = recipe.id }
        if let identity = settings.identity {
            labels[userLabel] = identity.username
            labels[shellLabel] = identity.shell
        }
```
and change the `body` `Env` value:
```swift
            "Env": (["container=docker"] + settings.env.map { "\($0.key)=\($0.value)" }).sorted(),
```
- `runFromImage` (lines 187-193) — carry identity labels when present:
```swift
        if let identity = settings.identity {
            labels[Self.userLabel] = identity.username
            labels[Self.shellLabel] = identity.shell
        }
```
- `machines()` (the `Machine(...)` return at line 96) — add the two fields:
```swift
                recipe: entry.Labels?[recipeLabel] ?? "",
                username: entry.Labels?[userLabel] ?? "root",
                loginShell: entry.Labels?[shellLabel] ?? "/bin/sh"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/test.sh -only-testing:DoryTests/MachineIdentityLabelTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Build**

Run: `scripts/build.sh`
Expected: `BUILD SUCCEEDED` (Machine's new fields are defaulted; MockData/other Machine(...) call sites still compile).

- [ ] **Step 6: Commit**

```bash
git add Dory/Runtime/Machines/MachineService.swift Dory/Models/Models.swift DoryTests/MachineIdentityLabelTests.swift
git commit -m "feat(machines): identity+env in MachineSettings, user/shell labels, Machine.username/loginShell"
```

---

### Task A5: Wire provisioning + default home bind

**Files:**
- Modify: `Dory/Runtime/Machines/MachineService.swift` (`create` :126-154 — post-start provisioning exec), `Dory/Models/AppStore.swift` (`createMachine` :1197 — identity param + home bind injection)
- Test: `DoryTests/MachineCreateIdentityTests.swift`

**Interfaces:**
- Consumes: `MacIdentity` (A1), `MachineProvisioner` (A3), `MachineSettings.identity` (A4).
- Produces: `static func AppStore.withIdentity(_ settings: MachineSettings, _ identity: MacIdentity) -> MachineSettings` (pure: sets identity + appends `$HOME:$HOME` bind if absent); `AppStore.createMachine` gains `identity: MacIdentity? = nil`.

- [ ] **Step 1: Write the failing test**

`DoryTests/MachineCreateIdentityTests.swift`:
```swift
import Testing
@testable import Dory

struct MachineCreateIdentityTests {
    private let id = MacIdentity(username: "augustusotu", uid: 501, homePath: "/Users/augustusotu", shell: "/bin/bash", publicKeys: [])

    @Test func injectsIdentityAndHomeBind() {
        let s = AppStore.withIdentity(.default, id)
        #expect(s.identity == id)
        #expect(s.mounts.contains(MountPair(host: "/Users/augustusotu", guest: "/Users/augustusotu")))
    }

    @Test func doesNotDuplicateExistingHomeBind() {
        var base = MachineSettings.default
        base.mounts = [MountPair(host: "/Users/augustusotu", guest: "/Users/augustusotu")]
        let s = AppStore.withIdentity(base, id)
        #expect(s.mounts.filter { $0.guest == "/Users/augustusotu" }.count == 1)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test.sh -only-testing:DoryTests/MachineCreateIdentityTests`
Expected: FAIL — `AppStore.withIdentity` not found.

- [ ] **Step 3: Implement**

`Dory/Models/AppStore.swift` — add a static pure helper (near `createMachine`):
```swift
    static func withIdentity(_ settings: MachineSettings, _ identity: MacIdentity) -> MachineSettings {
        var s = settings
        s.identity = identity
        if !s.mounts.contains(where: { $0.guest == identity.homePath }) {
            s.mounts.append(MountPair(host: identity.homePath, guest: identity.homePath, readOnly: false))
        }
        return s
    }
```
Change `createMachine` signature (line 1197) to add `identity: MacIdentity? = nil`, and inject before the `machineService.create` call (line 1215):
```swift
    func createMachine(image: String, name: String, arch: MachineArch = .host, recipe: DevRecipe? = nil, settings: MachineSettings = .default, identity: MacIdentity? = nil) async -> String? {
        ...
        let effectiveSettings = identity.map { Self.withIdentity(settings, $0) } ?? settings
        do {
            try await machineService.create(name: trimmedName, distro: distro, arch: arch, recipe: recipe, settings: effectiveSettings) { line in
```
(replace the `settings:` argument with `effectiveSettings`).

`Dory/Runtime/Machines/MachineService.swift` — in `create`, after the systemd-readiness block and before `progress("Machine \(name) is ready.")` (line 153), add the provisioning exec:
```swift
        if let identity = settings.identity {
            progress("Setting up \(identity.username)…")
            let script = MachineProvisioner.script(identity: identity, pkg: distro.pkg, isSystemd: distro.boot == .systemd, includeSSH: false)
            let result = try? await runtime.exec(containerID: Self.containerName(for: name), command: ["/bin/sh", "-c", script])
            if let result, !result.succeeded {
                progress("Identity setup reported: \(result.output)")
            }
        }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/test.sh -only-testing:DoryTests/MachineCreateIdentityTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Build**

Run: `scripts/build.sh`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 6: Commit**

```bash
git add Dory/Models/AppStore.swift Dory/Runtime/Machines/MachineService.swift DoryTests/MachineCreateIdentityTests.swift
git commit -m "feat(machines): inject identity+home bind, run post-create provisioning exec"
```

---

### Task A6: Exec-as-user terminal

**Files:**
- Modify: `Dory/Net/TerminalLauncher.swift` (add `execArgs` + `openMachineShell`), `Dory/Features/Containers/ContainerTerminalView.swift` (optional user/shell/home), `Dory/Features/Machines/MachinesView.swift:296` (pass machine identity), `Dory/Models/AppStore.swift:1443` (`openMachineTerminalApp`)
- Test: `DoryTests/ExecArgsTests.swift`

**Interfaces:**
- Consumes: `Machine.username`/`loginShell` (A4).
- Produces: `static func TerminalLauncher.execArgs(user: String, shell: String, home: String, container: String) -> String`; `static func TerminalLauncher.openMachineShell(socketPath: String, containerID: String, user: String, shell: String, home: String)`.

- [ ] **Step 1: Write the failing test**

`DoryTests/ExecArgsTests.swift`:
```swift
import Testing
@testable import Dory

struct ExecArgsTests {
    @Test func rootUsesFallbackShellProbe() {
        let a = TerminalLauncher.execArgs(user: "root", shell: "/bin/sh", home: "/root", container: "c1")
        #expect(a == "exec -it c1 sh -c 'command -v bash >/dev/null && exec bash || exec sh'")
    }

    @Test func nonRootExecsAsUserWithLoginShell() {
        let a = TerminalLauncher.execArgs(user: "augustusotu", shell: "/bin/bash", home: "/Users/augustusotu", container: "c1")
        #expect(a == "exec -it -u augustusotu -w /Users/augustusotu c1 /bin/bash -l")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test.sh -only-testing:DoryTests/ExecArgsTests`
Expected: FAIL — `execArgs` not found.

- [ ] **Step 3: Implement**

`Dory/Net/TerminalLauncher.swift` — add to the enum:
```swift
    static func execArgs(user: String, shell: String, home: String, container: String) -> String {
        if user == "root" {
            return "exec -it \(container) sh -c 'command -v bash >/dev/null && exec bash || exec sh'"
        }
        return "exec -it -u \(user) -w \(home) \(container) \(shell) -l"
    }

    static func openMachineShell(socketPath: String, containerID: String, user: String, shell: String, home: String) {
        open(command: "docker -H unix://\(socketPath) \(execArgs(user: user, shell: shell, home: home, container: containerID))")
    }
```

`Dory/Features/Containers/ContainerTerminalView.swift` — add optional props and use the builder:
```swift
struct ContainerTerminalView: NSViewRepresentable {
    let socketPath: String
    let containerID: String
    var user: String = "root"
    var shell: String = "/bin/sh"
    var home: String = "/root"

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let term = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        let exec = "docker -H unix://\(socketPath) \(TerminalLauncher.execArgs(user: user, shell: shell, home: home, container: containerID))"
        let env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        term.startProcess(executable: "/bin/zsh", args: ["-lc", exec], environment: env)
        return term
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
}
```
(Containers keep the default root args since `ContainerDetailView` constructs `ContainerTerminalView(socketPath:containerID:)` without the new props.)

`Dory/Features/Machines/MachinesView.swift:296` — pass the machine's identity:
```swift
            ContainerTerminalView(socketPath: store.shimSocketPath, containerID: machine.containerID,
                                  user: machine.username, shell: machine.loginShell, home: machine.username == "root" ? "/root" : "/Users/\(machine.username)")
```
(Use the machine's home: for an identity machine the home is `/Users/<user>`; root machines pass `/root`.)

`Dory/Models/AppStore.swift:1443` — `openMachineTerminalApp` execs as the user:
```swift
    func openMachineTerminalApp(_ machine: Machine) {
        guard !machine.containerID.isEmpty else { return }
        let home = machine.username == "root" ? "/root" : "/Users/\(machine.username)"
        TerminalLauncher.openMachineShell(socketPath: shimSocketPath, containerID: machine.containerID,
                                          user: machine.username, shell: machine.loginShell, home: home)
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/test.sh -only-testing:DoryTests/ExecArgsTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Build**

Run: `scripts/build.sh`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 6: Commit**

```bash
git add Dory/Net/TerminalLauncher.swift Dory/Features/Containers/ContainerTerminalView.swift Dory/Features/Machines/MachinesView.swift Dory/Models/AppStore.swift DoryTests/ExecArgsTests.swift
git commit -m "feat(machines): exec the machine terminal as the provisioned user (containers stay root)"
```

---

### Task A7: Stepped creation flow + identity UI + bug fix

**Files:**
- Modify: `Dory/Features/Sheets/NewMachineSheet.swift` (stepped layout, Identity & Sharing section, env rows, `collectedSettings` bug fix, pass identity to `createMachine`)
- Test: `DoryTests/NewMachineSettingsTests.swift`

**Interfaces:**
- Consumes: `MacIdentity` (A1), `AppStore.createMachine(...identity:)` (A5), `MachineSettings.env` (A4).
- Produces: the create flow always collects CPU/RAM/mounts/ports/env regardless of the Advanced disclosure; builds a `MacIdentity` when "share home" is on; validates mounts are under `$HOME`.

This task has a UI portion (not unit-tested) and a logic portion (the `collectedSettings` fix, unit-tested). Do the logic test first.

- [ ] **Step 1: Write the failing test for the settings logic**

The bug: `collectedSettings()` gates CPU/RAM on `advancedExpanded`. Extract a pure static helper so it's testable. `DoryTests/NewMachineSettingsTests.swift`:
```swift
import Testing
@testable import Dory

struct NewMachineSettingsTests {
    @Test func collectsResourcesRegardlessOfDisclosure() {
        let s = NewMachineSheet.buildSettings(cpus: 4, memoryGB: 8,
            mounts: [MountPair(host: "/Users/u/p", guest: "/Users/u/p")],
            ports: [PortPair(host: 8080, guest: 80)], env: ["K": "V"])
        #expect(s.cpus == 4)
        #expect(s.memoryMB == 8 * 1024)
        #expect(s.mounts.count == 1)
        #expect(s.ports == [PortPair(host: 8080, guest: 80)])
        #expect(s.env == ["K": "V"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test.sh -only-testing:DoryTests/NewMachineSettingsTests`
Expected: FAIL — `NewMachineSheet.buildSettings` not found.

- [ ] **Step 3: Implement the pure helper + fix the bug**

In `NewMachineSheet.swift`, add the env-row state (so `collectedSettings` compiles), a static pure builder, and route `collectedSettings()` through it (replacing the `advancedExpanded ? cpus : nil` gating at lines 416-421). Add near the other `@State` (after `portRows`):
```swift
    @State private var envRows: [EnvRow] = []
    private struct EnvRow: Identifiable, Hashable { let id = UUID(); var key = ""; var value = "" }
```
Then:
```swift
    static func buildSettings(cpus: Int, memoryGB: Int, mounts: [MountPair], ports: [PortPair], env: [String: String]) -> MachineSettings {
        MachineSettings(cpus: cpus, memoryMB: memoryGB * 1024, mounts: mounts, ports: ports, env: env)
    }

    private func collectedSettings() -> MachineSettings {
        let mounts = mountRows.compactMap { row -> MountPair? in
            let host = row.host.trimmingCharacters(in: .whitespaces); let guest = row.guest.trimmingCharacters(in: .whitespaces)
            guard !host.isEmpty, !guest.isEmpty else { return nil }
            return MountPair(host: host, guest: guest)
        }
        let ports = portRows.compactMap { row -> PortPair? in
            guard let h = Int(row.host.trimmingCharacters(in: .whitespaces)), let g = Int(row.guest.trimmingCharacters(in: .whitespaces)), h > 0, g > 0 else { return nil }
            return PortPair(host: h, guest: g)
        }
        let env = Dictionary(envRows.compactMap { r -> (String, String)? in
            let k = r.key.trimmingCharacters(in: .whitespaces); guard !k.isEmpty else { return nil }
            return (k, r.value)
        }, uniquingKeysWith: { _, b in b })
        return Self.buildSettings(cpus: cpus, memoryGB: memoryGB, mounts: mounts, ports: ports, env: env)
    }
```
(`MachineSettings`'s memberwise init now accepts `env:`; if the synthesized init ordering trips you, set `s.env = env` after construction. Note CPU/RAM are now ALWAYS applied — the silent-data-loss bug is fixed.)

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/test.sh -only-testing:DoryTests/NewMachineSettingsTests`
Expected: PASS (1 test).

- [ ] **Step 5: Build the UI changes**

Add to `NewMachineSheet` state: `@State private var shareHome = true`, `@State private var shell = "/bin/bash"` (`envRows` was added in Step 3). Add an **Identity & Sharing** section (between `devEnvironmentSection` and `optionsRow`) showing: the provisioned username (`Text(NSUserName())`, read-only), a shell `Picker` (`/bin/bash`, `/bin/zsh`, `/usr/bin/fish`) bound to `$shell`, a `Toggle("Share my Mac home (read-write)", isOn: $shareHome)` with helper text "Your home, git config, and SSH keys are shared into this machine.", and the env rows (reuse the `addButton`/`removeButton`/`fieldInput` helpers, `KEY` + `VALUE`). Validate added mount rows are under `NSHomeDirectory()` and show a red warning otherwise (block create). Restyle section headers with the WS1 design system where trivial; a full visual restep is optional — the required deliverable is the new section + the bug fix. Change `create()` to pass identity:
```swift
    private func create() {
        let identity = shareHome ? MacIdentity.current(shell: shell) : nil
        let settings = collectedSettings()
        let machineName = name; let image = selectedVersion.baseImage; let arch = selectedArch; let recipe = selectedRecipe
        store.activeSheet = nil
        Task { _ = await store.createMachine(image: image, name: machineName, arch: arch, recipe: recipe, settings: settings, identity: identity) }
    }
```
Run: `scripts/build.sh`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 6: Visual check**

Run: `scripts/shots.sh`. Confirm the New Machine sheet shows the Identity & Sharing section (username, shell picker, share-home toggle, env rows) and that CPU/RAM persist whether or not Advanced is expanded.

- [ ] **Step 7: Commit**

```bash
git add Dory/Features/Sheets/NewMachineSheet.swift DoryTests/NewMachineSettingsTests.swift
git commit -m "feat(machines): stepped creation — Identity & Sharing section, env, fix silent-data-loss bug"
```

---

## Self-review notes (addressed)

- **Spec coverage (Phase A):** MacIdentity (A1), MountPair `:ro` + helpers (A2), provisioning-script builder with the `/etc/dory/authorized_keys` rule + shell install (A3), identity/env in settings + labels + Machine model (A4), home bind + post-create provisioning wiring (A5), exec-as-user terminal (A6), stepped UI + env + bug fix (A7). Phase B items (sshd enable, HostIp fix, multi-port forwarding, port allocation, `dory ssh`, image bake) are explicitly out of this plan and get their own plan.
- **Type consistency:** `MacIdentity`, `MountPair.readOnly`, `bindString`/`parseBind`, `MachineProvisioner.script(identity:pkg:isSystemd:includeSSH:)`, `MachineSettings.identity`/`.env`, `MachineService.userLabel`/`shellLabel`, `Machine.username`/`loginShell`, `AppStore.withIdentity`, `createMachine(...identity:)`, `TerminalLauncher.execArgs`/`openMachineShell`, `NewMachineSheet.buildSettings` — each defined once and consumed by the same names later.
- **Edit/recreate identity:** preserved automatically — the post-create provisioning writes the user/sudoers/keys into the container filesystem, which `docker commit` captures; `recreate`/`restore` run from that snapshot image, so the user persists. `runFromImage` also re-applies the user/shell labels when `settings.identity` is present (A4).
- **Provisioning failure** is non-fatal: the machine still exists; the exec output is surfaced via `progress(...)`. (A richer retry affordance is a Phase B/UI follow-up.)
