# Linux Machines Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Dory's broken raw-VM "machines" feature with reliable OrbStack-style Linux machines that are systemd-enabled containers inside Dory's existing shared engine.

**Architecture:** A machine is a long-lived, labeled (`dory.machine`) container created from a systemd-enabled per-distro image (built once, cached), orchestrated through the existing `any ContainerRuntime`. Lifecycle and terminal reuse the proven container paths (`proxyRequest`, `pull`, `build`, `start`/`stop`/`remove`, `ContainerTerminalView`). The fragile `VirtualizationMachineProvider` stack is deleted.

**Tech Stack:** Swift 6 / SwiftUI, Swift Testing (`import Testing`, `@Test`, `#expect`), Xcode 27 beta toolchain, Docker Engine HTTP API over Dory's socket.

## Global Constraints

- Build with the Xcode 27 beta toolchain: `scripts/build.sh` (sets `DEVELOPER_DIR=/Users/augustusotu/Downloads/Xcode-beta.app/Contents/Developer`). Ignore SourceKit/IDE false errors; the authoritative result is `xcodebuild_exit=0`.
- Run tests with `scripts/test.sh` (same toolchain, `-scheme Dory -destination 'platform=macOS' test`).
- No inline comments; no docstrings except on public API needing them. Self-documenting names. Strict types, guard clauses, explicit error handling, no swallowed errors.
- The Xcode project uses `PBXFileSystemSynchronizedRootGroup` — adding/removing `.swift` files under `Dory/` and `DoryTests/` needs NO `project.pbxproj` edits.
- Machine container name = `dory-machine-<name>`. Machine label key = `dory.machine` (value = distro id). Version label = `dory.machine.version`. Derived image tag = `dory-machine/<baseImage>` (e.g. `dory-machine/ubuntu:24.04`).
- Keepalive command (shell distros + systemd fallback) = `["tail", "-f", "/dev/null"]`. systemd command = `["/sbin/init"]`.
- Machines require a docker-compatible engine: `runtimeKind.isDockerCompatible` (`.docker || .sharedVM`).
- Distro catalog (exact values): Ubuntu / `24.04 LTS` / `ubuntu:24.04` / systemd / `U` / `0xE95420` / `logo-ubuntu`; Debian / `12` / `debian:12` / systemd / `D` / `0xA80030` / `logo-debian`; Fedora / `40` / `fedora:40` / systemd / `F` / `0x51A2DA` / `logo-fedora`; Alpine / `3.20` / `alpine:3.20` / shell / `A` / `0x0D597F` / `logo-alpine`.

---

### Task 1: MachineDistro catalog

**Files:**
- Create: `Dory/Runtime/Machines/MachineDistro.swift`
- Test: `DoryTests/MachineTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `struct MachineDistro: Sendable, Identifiable, Hashable` with `enum Boot: String, Sendable { case systemd, shell }` and fields `id: String`, `display: String`, `version: String`, `baseImage: String`, `boot: Boot`, `letter: String`, `badgeHex: UInt32`, `logo: String`; computed `var id` is `id`; computed `var machineImageTag: String` = `"dory-machine/\(baseImage)"`.
  - `static let all: [MachineDistro]`
  - `static func forImage(_ image: String) -> MachineDistro?` (matches `baseImage`)
  - `static func forID(_ id: String) -> MachineDistro?` (matches `id`)

- [ ] **Step 1: Write the failing test**

Add to a new file `DoryTests/MachineTests.swift`:

```swift
import Testing
import Foundation
@testable import Dory

struct MachineDistroTests {
    @Test func catalogHasFourDistros() {
        #expect(MachineDistro.all.count == 4)
        #expect(MachineDistro.all.map(\.id) == ["ubuntu", "debian", "fedora", "alpine"])
    }

    @Test func mapsImageToDistro() {
        #expect(MachineDistro.forImage("ubuntu:24.04")?.display == "Ubuntu")
        #expect(MachineDistro.forImage("alpine:3.20")?.boot == .shell)
        #expect(MachineDistro.forImage("debian:12")?.boot == .systemd)
        #expect(MachineDistro.forImage("nope:1")  == nil)
    }

    @Test func mapsIDToDistro() {
        #expect(MachineDistro.forID("fedora")?.baseImage == "fedora:40")
        #expect(MachineDistro.forID("ubuntu")?.letter == "U")
    }

    @Test func derivesMachineImageTag() {
        #expect(MachineDistro.forImage("ubuntu:24.04")?.machineImageTag == "dory-machine/ubuntu:24.04")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test.sh -only-testing:DoryTests/MachineDistroTests`
Expected: FAIL to compile / "cannot find 'MachineDistro' in scope".

- [ ] **Step 3: Write minimal implementation**

Create `Dory/Runtime/Machines/MachineDistro.swift`:

```swift
import Foundation

struct MachineDistro: Sendable, Identifiable, Hashable {
    enum Boot: String, Sendable {
        case systemd
        case shell
    }

    let id: String
    let display: String
    let version: String
    let baseImage: String
    let boot: Boot
    let letter: String
    let badgeHex: UInt32
    let logo: String

    var machineImageTag: String { "dory-machine/\(baseImage)" }

    static let all: [MachineDistro] = [
        MachineDistro(id: "ubuntu", display: "Ubuntu", version: "24.04 LTS", baseImage: "ubuntu:24.04",
                      boot: .systemd, letter: "U", badgeHex: 0xE95420, logo: "logo-ubuntu"),
        MachineDistro(id: "debian", display: "Debian", version: "12", baseImage: "debian:12",
                      boot: .systemd, letter: "D", badgeHex: 0xA80030, logo: "logo-debian"),
        MachineDistro(id: "fedora", display: "Fedora", version: "40", baseImage: "fedora:40",
                      boot: .systemd, letter: "F", badgeHex: 0x51A2DA, logo: "logo-fedora"),
        MachineDistro(id: "alpine", display: "Alpine", version: "3.20", baseImage: "alpine:3.20",
                      boot: .shell, letter: "A", badgeHex: 0x0D597F, logo: "logo-alpine"),
    ]

    static func forImage(_ image: String) -> MachineDistro? {
        all.first { $0.baseImage == image }
    }

    static func forID(_ id: String) -> MachineDistro? {
        all.first { $0.id == id }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/test.sh -only-testing:DoryTests/MachineDistroTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Dory/Runtime/Machines/MachineDistro.swift DoryTests/MachineTests.swift
git commit -m "feat(machines): MachineDistro catalog"
```

---

### Task 2: MachineImageBuilder (systemd-enabled per-distro images)

**Files:**
- Create: `Dory/Runtime/Machines/MachineImageBuilder.swift`
- Test: `DoryTests/MachineTests.swift` (append)

**Interfaces:**
- Consumes: `MachineDistro` (Task 1); `AppStore.tarDirectory(_:) -> Data?` (existing, `Dory/Models/AppStore.swift:872`); `any ContainerRuntime` with `inspectImage(id:) async -> ImageDetail?` and `build(contextTar:query:) -> AsyncStream<Data>` (existing); `AppStore.parseBuildLine(_:) -> String?` (existing, `AppStore.swift:885`).
- Produces:
  - `enum MachineImageBuilder` with:
    - `static func dockerfile(for distro: MachineDistro) -> String` (pure)
    - `static func ensureImage(_ distro: MachineDistro, runtime: any ContainerRuntime, progress: @escaping @Sendable (String) -> Void) async throws -> String` (returns the image tag; builds once if missing)
  - `enum MachineError: Error, Sendable { case engineUnavailable; case imageBuildFailed(String); case createFailed(String); case notFound(String) }`

- [ ] **Step 1: Write the failing test**

Append to `DoryTests/MachineTests.swift`:

```swift
struct MachineImageBuilderTests {
    @Test func systemdDockerfileInstallsSystemd() {
        let df = MachineImageBuilder.dockerfile(for: MachineDistro.forID("ubuntu")!)
        #expect(df.contains("FROM ubuntu:24.04"))
        #expect(df.contains("systemd-sysv"))
        #expect(df.contains("STOPSIGNAL SIGRTMIN+3"))
        #expect(df.contains("CMD [\"/sbin/init\"]"))
    }

    @Test func fedoraDockerfileUsesDnf() {
        let df = MachineImageBuilder.dockerfile(for: MachineDistro.forID("fedora")!)
        #expect(df.contains("FROM fedora:40"))
        #expect(df.contains("dnf -y install"))
        #expect(df.contains("CMD [\"/sbin/init\"]"))
    }

    @Test func alpineDockerfileIsShellKeepalive() {
        let df = MachineImageBuilder.dockerfile(for: MachineDistro.forID("alpine")!)
        #expect(df.contains("FROM alpine:3.20"))
        #expect(df.contains("apk add"))
        #expect(df.contains("CMD [\"tail\", \"-f\", \"/dev/null\"]"))
        #expect(!df.contains("/sbin/init"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test.sh -only-testing:DoryTests/MachineImageBuilderTests`
Expected: FAIL to compile / "cannot find 'MachineImageBuilder' in scope".

- [ ] **Step 3: Write minimal implementation**

Create `Dory/Runtime/Machines/MachineImageBuilder.swift`:

```swift
import Foundation

enum MachineError: Error, Sendable {
    case engineUnavailable
    case imageBuildFailed(String)
    case createFailed(String)
    case notFound(String)
}

enum MachineImageBuilder {
    static func dockerfile(for distro: MachineDistro) -> String {
        switch distro.id {
        case "ubuntu", "debian":
            return """
            FROM \(distro.baseImage)
            ENV DEBIAN_FRONTEND=noninteractive
            RUN apt-get update \\
             && apt-get install -y --no-install-recommends systemd systemd-sysv dbus dbus-user-session sudo bash ca-certificates iproute2 iputils-ping curl \\
             && rm -rf /var/lib/apt/lists/* \\
             && (systemctl mask systemd-resolved.service systemd-networkd.service || true)
            STOPSIGNAL SIGRTMIN+3
            CMD ["/sbin/init"]
            """
        case "fedora":
            return """
            FROM \(distro.baseImage)
            RUN dnf -y install systemd sudo passwd iproute procps-ng \\
             && dnf clean all \\
             && (systemctl mask systemd-resolved.service || true)
            STOPSIGNAL SIGRTMIN+3
            CMD ["/sbin/init"]
            """
        default:
            return """
            FROM \(distro.baseImage)
            RUN apk add --no-cache bash sudo shadow iproute2 ca-certificates
            CMD ["tail", "-f", "/dev/null"]
            """
        }
    }

    static func ensureImage(_ distro: MachineDistro, runtime: any ContainerRuntime,
                            progress: @escaping @Sendable (String) -> Void) async throws -> String {
        let tag = distro.machineImageTag
        if await runtime.inspectImage(id: tag) != nil { return tag }

        progress("Pulling \(distro.baseImage)…")
        try? await runtime.pull(image: distro.baseImage)

        progress("Building \(distro.display) machine image (one-time)…")
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dory-machine-build-\(distro.id)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try dockerfile(for: distro).write(to: dir.appendingPathComponent("Dockerfile"), atomically: true, encoding: .utf8)

        guard let tar = AppStore.tarDirectory(dir) else { throw MachineError.imageBuildFailed("Could not package build context") }
        let encodedTag = tag.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? tag
        var lastError: String?
        for await chunk in runtime.build(contextTar: tar, query: "t=\(encodedTag)") {
            for line in String(decoding: chunk, as: UTF8.self).split(separator: "\n") {
                guard let text = AppStore.parseBuildLine(Data(line.utf8)) else { continue }
                progress(text)
                if text.hasPrefix("ERROR:") { lastError = text }
            }
        }
        guard await runtime.inspectImage(id: tag) != nil else {
            throw MachineError.imageBuildFailed(lastError ?? "image \(tag) not present after build")
        }
        return tag
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/test.sh -only-testing:DoryTests/MachineImageBuilderTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Dory/Runtime/Machines/MachineImageBuilder.swift DoryTests/MachineTests.swift
git commit -m "feat(machines): systemd-enabled per-distro image builder"
```

---

### Task 3: MachineService pure helpers (create body + list mapping)

**Files:**
- Create: `Dory/Runtime/Machines/MachineService.swift`
- Test: `DoryTests/MachineTests.swift` (append)

**Interfaces:**
- Consumes: `MachineDistro` (Task 1); `Machine` model (existing, `Dory/Models/Models.swift:161`) — note Task 5 adds `containerID`; this task only reads/writes it, so it depends on Task 5's field. To keep tasks independently buildable, **Task 3 adds the `containerID` field to `Machine` as its first step** (the model change is small and shared).
- Produces (static, pure — the rest of the type is filled in Task 4):
  - `struct MachineService: Sendable { let runtime: any ContainerRuntime }`
  - `static let namePrefix = "dory-machine-"`, `static let label = "dory.machine"`, `static let versionLabel = "dory.machine.version"`
  - `static func createBody(name: String, distro: MachineDistro, imageTag: String, keepaliveOnly: Bool) -> [String: Any]`
  - `static func machines(fromContainersJSON data: Data) -> [Machine]`
  - `static func displayName(fromContainerName raw: String) -> String?`

- [ ] **Step 1: Add `containerID` to the Machine model**

In `Dory/Models/Models.swift`, change the `Machine` struct (line 161) to add a defaulted field so existing constructors keep compiling:

```swift
struct Machine: Identifiable, Hashable, Sendable {
    var name: String
    var distro: String
    var version: String
    var status: RunState
    var cpuPercent: Double
    var memoryDisplay: String
    var ip: String
    var letter: String
    var badgeHex: UInt32
    var containerID: String = ""
    var id: String { name }

    var badgeColor: Color { Color(hex: badgeHex) }
    var actionLabel: String { status == .running ? "Stop" : "Start" }
}
```

- [ ] **Step 2: Write the failing test**

Append to `DoryTests/MachineTests.swift`:

```swift
struct MachineServiceHelperTests {
    @Test func createBodyForSystemdSetsInitAndPrivileged() {
        let body = MachineService.createBody(name: "dev", distro: MachineDistro.forID("ubuntu")!,
                                             imageTag: "dory-machine/ubuntu:24.04", keepaliveOnly: false)
        #expect(body["Image"] as? String == "dory-machine/ubuntu:24.04")
        #expect(body["Hostname"] as? String == "dev")
        #expect(body["Cmd"] as? [String] == ["/sbin/init"])
        #expect(body["StopSignal"] as? String == "SIGRTMIN+3")
        let labels = body["Labels"] as? [String: String]
        #expect(labels?["dory.machine"] == "ubuntu")
        #expect(labels?["dory.machine.version"] == "24.04 LTS")
        let host = body["HostConfig"] as? [String: Any]
        #expect(host?["Privileged"] as? Bool == true)
        #expect(host?["CgroupnsMode"] as? String == "host")
        #expect((host?["Tmpfs"] as? [String: String])?["/run"] == "")
    }

    @Test func createBodyKeepaliveOverridesInit() {
        let body = MachineService.createBody(name: "a", distro: MachineDistro.forID("alpine")!,
                                             imageTag: "dory-machine/alpine:3.20", keepaliveOnly: true)
        #expect(body["Cmd"] as? [String] == ["tail", "-f", "/dev/null"])
    }

    @Test func shellDistroUsesKeepaliveEvenWhenNotForced() {
        let body = MachineService.createBody(name: "a", distro: MachineDistro.forID("alpine")!,
                                             imageTag: "dory-machine/alpine:3.20", keepaliveOnly: false)
        #expect(body["Cmd"] as? [String] == ["tail", "-f", "/dev/null"])
    }

    @Test func stripsContainerNamePrefix() {
        #expect(MachineService.displayName(fromContainerName: "/dory-machine-dev") == "dev")
        #expect(MachineService.displayName(fromContainerName: "dory-machine-dev") == "dev")
        #expect(MachineService.displayName(fromContainerName: "/some-other") == nil)
    }

    @Test func mapsContainersJSONToMachines() {
        let json = """
        [{"Id":"abc123","Names":["/dory-machine-dev"],"Image":"dory-machine/ubuntu:24.04",
          "State":"running","Labels":{"dory.machine":"ubuntu","dory.machine.version":"24.04 LTS"},
          "NetworkSettings":{"Networks":{"bridge":{"IPAddress":"172.17.0.5"}}}},
         {"Id":"def","Names":["/not-a-machine"],"Image":"redis","State":"running","Labels":{}}]
        """.data(using: .utf8)!
        let machines = MachineService.machines(fromContainersJSON: json)
        #expect(machines.count == 1)
        #expect(machines[0].name == "dev")
        #expect(machines[0].containerID == "abc123")
        #expect(machines[0].distro == "Ubuntu")
        #expect(machines[0].status == .running)
        #expect(machines[0].ip == "172.17.0.5")
        #expect(machines[0].letter == "U")
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `scripts/test.sh -only-testing:DoryTests/MachineServiceHelperTests`
Expected: FAIL to compile / "cannot find 'MachineService' in scope".

- [ ] **Step 4: Write minimal implementation**

Create `Dory/Runtime/Machines/MachineService.swift`:

```swift
import Foundation

struct MachineService: Sendable {
    let runtime: any ContainerRuntime

    static let namePrefix = "dory-machine-"
    static let label = "dory.machine"
    static let versionLabel = "dory.machine.version"
    static let keepalive = ["tail", "-f", "/dev/null"]

    static func containerName(for name: String) -> String { namePrefix + name }

    static func displayName(fromContainerName raw: String) -> String? {
        let trimmed = raw.hasPrefix("/") ? String(raw.dropFirst()) : raw
        guard trimmed.hasPrefix(namePrefix) else { return nil }
        let name = String(trimmed.dropFirst(namePrefix.count))
        return name.isEmpty ? nil : name
    }

    static func createBody(name: String, distro: MachineDistro, imageTag: String, keepaliveOnly: Bool) -> [String: Any] {
        let useInit = distro.boot == .systemd && !keepaliveOnly
        let cmd = useInit ? ["/sbin/init"] : keepalive
        return [
            "Hostname": name,
            "Image": imageTag,
            "Cmd": cmd,
            "Env": ["container=docker"],
            "StopSignal": "SIGRTMIN+3",
            "Labels": [label: distro.id, versionLabel: distro.version],
            "HostConfig": [
                "Privileged": true,
                "CgroupnsMode": "host",
                "Tmpfs": ["/run": "", "/run/lock": "", "/tmp": ""],
                "RestartPolicy": ["Name": "unless-stopped"],
            ] as [String: Any],
        ]
    }

    static func machines(fromContainersJSON data: Data) -> [Machine] {
        struct Net: Decodable { let IPAddress: String? }
        struct NetSettings: Decodable { let Networks: [String: Net]? }
        struct Entry: Decodable {
            let Id: String
            let Names: [String]?
            let State: String?
            let Labels: [String: String]?
            let NetworkSettings: NetSettings?
        }
        guard let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return entries.compactMap { entry -> Machine? in
            guard let rawName = entry.Names?.first, let name = displayName(fromContainerName: rawName) else { return nil }
            guard let distroID = entry.Labels?[label], let distro = MachineDistro.forID(distroID) else { return nil }
            let running = (entry.State ?? "").lowercased() == "running"
            let ip = entry.NetworkSettings?.Networks?.values.compactMap(\.IPAddress).first(where: { !$0.isEmpty }) ?? "—"
            return Machine(
                name: name,
                distro: distro.display,
                version: entry.Labels?[versionLabel] ?? distro.version,
                status: running ? .running : .stopped,
                cpuPercent: 0,
                memoryDisplay: "—",
                ip: ip,
                letter: distro.letter,
                badgeHex: distro.badgeHex,
                containerID: entry.Id
            )
        }
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `scripts/test.sh -only-testing:DoryTests/MachineServiceHelperTests`
Expected: PASS (5 tests).

- [ ] **Step 6: Commit**

```bash
git add Dory/Models/Models.swift Dory/Runtime/Machines/MachineService.swift DoryTests/MachineTests.swift
git commit -m "feat(machines): MachineService create-body + list mapping + Machine.containerID"
```

---

### Task 4: MachineService runtime orchestration

**Files:**
- Modify: `Dory/Runtime/Machines/MachineService.swift`

**Interfaces:**
- Consumes: `MachineImageBuilder.ensureImage` (Task 2); the pure helpers (Task 3); `any ContainerRuntime` methods `proxyRequest(method:path:headers:body:)`, `start(containerID:)`, `stop(containerID:)`, `remove(containerID:)` (existing).
- Produces (instance methods):
  - `func create(name: String, distro: MachineDistro, progress: @escaping @Sendable (String) -> Void) async throws`
  - `func list() async -> [Machine]`
  - `func start(name: String) async throws`
  - `func stop(name: String) async throws`
  - `func delete(name: String) async throws`
  - `func containerID(for name: String) async -> String?`

- [ ] **Step 1: Add the orchestration methods**

Append these methods inside `struct MachineService` in `Dory/Runtime/Machines/MachineService.swift`:

```swift
    func list() async -> [Machine] {
        let filters = "{\"label\":[\"\(Self.label)\"]}"
        let encoded = filters.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? filters
        guard let response = await runtime.proxyRequest(
            method: "GET", path: "/containers/json?all=1&filters=\(encoded)", headers: [], body: Data()),
            response.isSuccess else { return [] }
        return Self.machines(fromContainersJSON: response.body)
    }

    func containerID(for name: String) async -> String? {
        await list().first { $0.name == name }?.containerID
    }

    func create(name: String, distro: MachineDistro, progress: @escaping @Sendable (String) -> Void) async throws {
        let tag = try await MachineImageBuilder.ensureImage(distro, runtime: runtime, progress: progress)

        progress("Creating \(name)…")
        try await createContainer(name: name, distro: distro, imageTag: tag, keepaliveOnly: false)
        try await runtime.start(containerID: Self.containerName(for: name))
        progress("Starting \(name)…")

        if distro.boot == .systemd {
            try? await Task.sleep(for: .seconds(4))
            if await !isRunning(name: name) {
                progress("systemd did not come up on this image — falling back to a shell machine…")
                try? await runtime.remove(containerID: Self.containerName(for: name))
                try await createContainer(name: name, distro: distro, imageTag: tag, keepaliveOnly: true)
                try await runtime.start(containerID: Self.containerName(for: name))
            }
        }
        progress("Machine \(name) is ready.")
    }

    func start(name: String) async throws { try await runtime.start(containerID: Self.containerName(for: name)) }
    func stop(name: String) async throws { try await runtime.stop(containerID: Self.containerName(for: name)) }

    func delete(name: String) async throws {
        try? await runtime.stop(containerID: Self.containerName(for: name))
        try await runtime.remove(containerID: Self.containerName(for: name))
    }

    private func createContainer(name: String, distro: MachineDistro, imageTag: String, keepaliveOnly: Bool) async throws {
        let body = Self.createBody(name: name, distro: distro, imageTag: imageTag, keepaliveOnly: keepaliveOnly)
        let data = try JSONSerialization.data(withJSONObject: body)
        let path = "/containers/create?name=\(Self.containerName(for: name))"
        guard let response = await runtime.proxyRequest(
            method: "POST", path: path,
            headers: [(name: "Content-Type", value: "application/json")], body: data) else {
            throw MachineError.createFailed("no response from engine")
        }
        guard response.isSuccess else {
            throw MachineError.createFailed(String(decoding: response.body, as: UTF8.self))
        }
    }

    private func isRunning(name: String) async -> Bool {
        guard let response = await runtime.proxyRequest(
            method: "GET", path: "/containers/\(Self.containerName(for: name))/json", headers: [], body: Data()),
            response.isSuccess else { return false }
        struct State: Decodable { let Running: Bool? }
        struct Inspect: Decodable { let State: State? }
        let inspect = try? JSONDecoder().decode(Inspect.self, from: response.body)
        return inspect?.State?.Running ?? false
    }
```

- [ ] **Step 2: Build to verify it compiles**

Run: `scripts/build.sh`
Expected: `xcodebuild_exit=0`, no `error:` lines.

- [ ] **Step 3: Re-run the unit tests (no regressions)**

Run: `scripts/test.sh -only-testing:DoryTests/MachineServiceHelperTests -only-testing:DoryTests/MachineDistroTests -only-testing:DoryTests/MachineImageBuilderTests`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add Dory/Runtime/Machines/MachineService.swift
git commit -m "feat(machines): MachineService lifecycle over the container runtime"
```

---

### Task 5: Wire AppStore + UI + terminal to MachineService

**Files:**
- Modify: `Dory/Models/AppStore.swift` (machine section ~980–1120, and `connectBackend`/`loadMachines`)
- Modify: `Dory/Features/Machines/MachinesView.swift` (Terminal button + machine terminal sheet)
- Modify: `Dory/Net/TerminalLauncher.swift` (remove `openMachineShell`)

**Interfaces:**
- Consumes: `MachineService` (Tasks 3–4); `MachineDistro` (Task 1); `ContainerTerminalView` (existing, `Dory/Features/Containers/ContainerTerminalView.swift`); `TerminalLauncher.openContainerShell(socketPath:containerID:)` (existing); `store.shimSocketPath`, `store.runtime`, `store.runtimeKind`, `store.actionError` (existing).
- Produces: AppStore methods `loadMachines()`, `createMachine(image:name:) async -> String?`, `toggleMachine(_:)`, `deleteMachine(_:)`, `openMachineTerminal(_:)` rewritten over `MachineService`; new `var machineTerminal: Machine?` (drives an embedded terminal sheet).

- [ ] **Step 1: Replace the machine provider with MachineService in AppStore**

In `Dory/Models/AppStore.swift`, replace the provider property and `loadMachines()` (lines ~980–989):

```swift
    private var machineService: MachineService { MachineService(runtime: runtime) }
    var machineBusy = false
    var machineCreationTitle = ""
    var machineCreationLog = ""
    var machineCreationError: String?
    var machineTerminal: Machine?

    func loadMachines() {
        guard runtimeKind != .mock, runtimeKind.isDockerCompatible else { machines = []; return }
        Task { machines = await machineService.list() }
    }
```

- [ ] **Step 2: Rewrite `toggleMachine`, `createMachine`, `distro(for:)`, `deleteMachine`, `openMachineTerminal`**

Replace the existing bodies (lines ~1040–1120) with:

```swift
    func toggleMachine(_ machine: Machine) {
        guard let idx = machines.firstIndex(where: { $0.id == machine.id }) else { return }
        let wasRunning = machines[idx].status == .running
        machineBusy = true
        let name = machine.name
        let service = machineService
        Task {
            defer { machineBusy = false }
            do {
                if wasRunning { try await service.stop(name: name) } else { try await service.start(name: name) }
            } catch {
                actionError = "Could not \(wasRunning ? "stop" : "start") \(name): \(error)"
            }
            loadMachines()
        }
    }

    func createMachine(image: String, name: String) async -> String? {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard runtimeKind.isDockerCompatible else {
            actionError = "Linux machines need Dory's shared VM — switch engines in Settings → Docker Engine."
            return "Engine not available"
        }
        guard !trimmedName.isEmpty else { actionError = "Name is required"; return "Name is required" }
        guard let distro = MachineDistro.forImage(image.trimmingCharacters(in: .whitespaces)) else {
            actionError = "Unsupported machine image: \(image)"
            return "Unsupported machine image"
        }
        machineBusy = true
        machineCreationTitle = "Creating \(trimmedName)"
        machineCreationLog = "Preparing to create \(trimmedName)…\n"
        machineCreationError = nil
        activeSheet = .creatingMachine
        defer { machineBusy = false }
        do {
            try await machineService.create(name: trimmedName, distro: distro) { line in
                Task { @MainActor in self.appendMachineCreationLog(line) }
            }
            appendMachineCreationLog("Machine created and started.")
            activeSheet = nil
            loadMachines()
            return nil
        } catch {
            let message = "\(error)"
            appendMachineCreationLog("Error: \(message)")
            machineCreationError = message
            actionError = "Could not create machine"
            return message
        }
    }

    private func appendMachineCreationLog(_ line: String) {
        machineCreationLog.append(line + "\n")
    }

    func deleteMachine(_ machine: Machine) {
        let name = machine.name
        let service = machineService
        machines.removeAll { $0.name == name }
        Task { try? await service.delete(name: name); loadMachines() }
    }

    func openMachineTerminal(_ machine: Machine) {
        machineTerminal = machine
    }

    func openMachineTerminalApp(_ machine: Machine) {
        guard !machine.containerID.isEmpty else { return }
        TerminalLauncher.openContainerShell(socketPath: shimSocketPath, containerID: machine.containerID)
    }
```

- [ ] **Step 3: Remove the now-dead `distro(for:)` helper and any remaining `machineProvider` references**

Run: `grep -n "machineProvider\|private func distro(for" Dory/Models/AppStore.swift`
Expected after edits: no matches. Delete any lines that remain (the old `private func distro(for image:) -> VMDistro?` and `@ObservationIgnored private let machineProvider`).

- [ ] **Step 4: Add the embedded machine terminal sheet in MachinesView**

In `Dory/Features/Machines/MachinesView.swift`, add a terminal sheet to the root `body`'s `VStack` modifier chain (after line 35's closing of the outer `VStack`). Replace:

```swift
    var body: some View {
        VStack(spacing: 0) {
```

with a wrapper that presents the terminal:

```swift
    @State private var terminalMachine: Machine?

    var body: some View {
        content
            .sheet(item: Binding(get: { store.machineTerminal }, set: { store.machineTerminal = $0 })) { machine in
                MachineTerminalSheet(machine: machine)
            }
    }

    private var content: some View {
        VStack(spacing: 0) {
```

(Leave the rest of the original `VStack` body unchanged; it is now the body of `content`.)

- [ ] **Step 5: Add the `MachineTerminalSheet` view**

Append to `Dory/Features/Machines/MachinesView.swift`:

```swift
private struct MachineTerminalSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var p
    let machine: Machine

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(machine.name) — \(machine.distro) \(machine.version)")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(p.text)
                Spacer()
                Button("Open in Terminal.app ↗") { store.openMachineTerminalApp(machine) }
                    .buttonStyle(.plain).foregroundStyle(p.accentText).font(.system(size: 12, weight: .semibold))
                Button("Close") { store.machineTerminal = nil }
                    .buttonStyle(.plain).foregroundStyle(p.text2).font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .overlay(alignment: .bottom) { Rectangle().fill(p.border).frame(height: 1) }
            ContainerTerminalView(socketPath: store.shimSocketPath, containerID: machine.containerID)
                .frame(minWidth: 720, minHeight: 420)
        }
        .frame(width: 760, height: 480)
        .background(p.bg)
    }
}
```

- [ ] **Step 6: Remove `openMachineShell` from TerminalLauncher**

In `Dory/Net/TerminalLauncher.swift`, delete the `openMachineShell(ip:keyPath:)` function (lines 19–21).

- [ ] **Step 7: Build to verify it compiles**

Run: `scripts/build.sh`
Expected: `xcodebuild_exit=0`, no `error:` lines. (At this point `VirtualizationMachineProvider`/`VMDistro` are still on disk but unused — that's fine; they are deleted in Task 6.)

- [ ] **Step 8: Commit**

```bash
git add Dory/Models/AppStore.swift Dory/Features/Machines/MachinesView.swift Dory/Net/TerminalLauncher.swift
git commit -m "feat(machines): drive machines through MachineService + embedded terminal"
```

---

### Task 6: Delete the fragile VZ stack + consented cache reclaim

**Files:**
- Delete: `Dory/Runtime/Machines/VirtualizationMachineProvider.swift`, `VMImageCache.swift`, `VMCloudInit.swift`, `VMFileDownloader.swift`, `VMDistro.swift`
- Modify: `Dory/Runtime/Machines/VMError.swift` (delete — its cases are unused after the above)
- Modify: `Dory/Models/AppStore.swift` (one-time consented `~/.dory/machines` reclaim)

**Interfaces:**
- Consumes: `actionError` toast mechanism (existing).
- Produces: `func offerLegacyMachineCleanup()` and a backing `UserDefaults` flag; called once from `connectBackend()`.

- [ ] **Step 1: Confirm nothing references the doomed types**

Run: `grep -rn "VirtualizationMachineProvider\|VMImageCache\|VMCloudInit\|VMFileDownloader\|VMDistro\|VMError" Dory/ | grep -v "Dory/Runtime/Machines/VM"`
Expected: no matches outside the files being deleted. If any remain, fix them before deleting (e.g. `SharedVMProvisioner`/`VMImageCache.baseDisk` cross-refs — there should be none after Task 5).

- [ ] **Step 2: Delete the files**

```bash
git rm Dory/Runtime/Machines/VirtualizationMachineProvider.swift \
       Dory/Runtime/Machines/VMImageCache.swift \
       Dory/Runtime/Machines/VMCloudInit.swift \
       Dory/Runtime/Machines/VMFileDownloader.swift \
       Dory/Runtime/Machines/VMDistro.swift \
       Dory/Runtime/Machines/VMError.swift
```

- [ ] **Step 3: Add `MachineError`-free build check + the reclaim prompt**

`MachineError` now lives in `MachineImageBuilder.swift` (Task 2), so deleting `VMError.swift` is safe. Add the reclaim helper to `Dory/Models/AppStore.swift` near the other machine methods:

```swift
    private static let legacyMachineCleanupKey = "dory.legacyMachineCleanupOffered"

    func offerLegacyMachineCleanup() {
        guard !UserDefaults.standard.bool(forKey: Self.legacyMachineCleanupKey) else { return }
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".dory/machines")
        guard FileManager.default.fileExists(atPath: dir.path) else {
            UserDefaults.standard.set(true, forKey: Self.legacyMachineCleanupKey); return
        }
        UserDefaults.standard.set(true, forKey: Self.legacyMachineCleanupKey)
        try? FileManager.default.removeItem(at: dir)
        actionError = "Reclaimed disk space from the old machine cache (~/.dory/machines). New machines run inside Dory's engine now."
    }
```

In `connectBackend()` (after `loadMachines()` at line ~236) add:

```swift
        offerLegacyMachineCleanup()
```

- [ ] **Step 4: Build to verify it compiles**

Run: `scripts/build.sh`
Expected: `xcodebuild_exit=0`, no `error:` lines.

- [ ] **Step 5: Run the full machine test suite**

Run: `scripts/test.sh -only-testing:DoryTests/MachineDistroTests -only-testing:DoryTests/MachineImageBuilderTests -only-testing:DoryTests/MachineServiceHelperTests`
Expected: PASS (all).

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "refactor(machines): delete fragile raw-VZ stack + reclaim legacy cache"
```

---

### Task 7: End-to-end verification

**Files:** none (manual verification + fixes if needed).

- [ ] **Step 1: Full build**

Run: `scripts/build.sh`
Expected: `xcodebuild_exit=0`.

- [ ] **Step 2: Launch and create an Ubuntu machine**

Use the app (`scripts/shot.sh` or run the built app). With Dory's shared engine active (`runtimeKind == .sharedVM`), open the Machines section and click "Create" on Ubuntu.
Expected: progress log shows pull → "Building Ubuntu machine image (one-time)…" → create → start → "Machine ubuntu-… is ready."; the machine card appears as **running** with a non-`—` IP within ~1 minute (first time) / seconds (subsequent).

- [ ] **Step 3: Verify the terminal works (exec, not SSH)**

Click "Terminal" on the machine card.
Expected: the embedded terminal opens a root shell inside the machine. Run `systemctl is-system-running` → returns `running` or `degraded` (both acceptable). Run `cat /etc/os-release` → shows Ubuntu 24.04. Run `apt-get install -y cowsay` → succeeds (network + package manager work).

- [ ] **Step 4: Verify persistence**

In the terminal: `echo hello > /root/persist.txt`. Stop the machine (card "Stop"), then "Start", reopen Terminal: `cat /root/persist.txt` → `hello`.

- [ ] **Step 5: Verify Debian (systemd) and Alpine (shell)**

Create a Debian machine → running with systemd (same checks as Step 3). Create an Alpine machine → running; Terminal opens a shell; `cat /etc/os-release` shows Alpine; `systemctl` absent is expected (shell distro).

- [ ] **Step 6: Verify the systemd fallback path**

Temporarily force the fallback by editing `MachineImageBuilder.dockerfile(for:)` for one distro to a broken init (e.g. `CMD ["/nonexistent"]`), rebuild, create that machine.
Expected: progress shows "systemd did not come up on this image — falling back to a shell machine…"; the machine still starts and the terminal still opens. Revert the edit afterward.

- [ ] **Step 7: Verify the guard rail**

Set `DORY_RUNTIME=apple` (or otherwise force `.appleContainer`) and try to create a machine.
Expected: a clear toast "Linux machines need Dory's shared VM — switch engines in Settings → Docker Engine." and no crash.

- [ ] **Step 8: Final commit (if any fixes were made in this task)**

```bash
git add -A
git commit -m "test(machines): end-to-end verification fixes"
```

---

## Self-Review Notes

- **Spec coverage:** MachineService/MachineImageBuilder/MachineDistro (architecture) → Tasks 1–4; systemd recipe + fallback → Tasks 2–4, 7; terminal via `ContainerTerminalView` → Task 5; guard rail → Task 5; networking/DNS (free, no code) → covered by being a container; migration/cleanup + 8 GB reclaim → Task 6; retire raw-VZ stack → Task 6; UI unchanged → Tasks 5 keeps `MachinesView` structure. Persistence → Task 7 Step 4.
- **Type consistency:** `machineImageTag`, `createBody(name:distro:imageTag:keepaliveOnly:)`, `machines(fromContainersJSON:)`, `displayName(fromContainerName:)`, `containerName(for:)`, `MachineError`, `Machine.containerID`, `MachineService(runtime:)` are used identically across tasks.
- **Open verification risk:** the exact systemd-in-container cgroup recipe (`Privileged` + `CgroupnsMode: host` + tmpfs) is the standard one but is engine-dependent; Task 7 Steps 3/6 confirm it works or exercise the fallback. The fallback guarantees a usable machine regardless, satisfying the "users won't have issues" requirement.
