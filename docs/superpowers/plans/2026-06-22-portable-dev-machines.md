# Portable Dev Machines (Phase 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Dory machines portable — snapshot, clone, export/import as a file, one-click dev-toolchain recipes, and per-machine resource settings — all built on one commit-based snapshot primitive.

**Architecture:** A machine is a labeled container. A snapshot is a `docker commit` of it into a portable OCI image whose labels carry the machine's identity. Clone = run from that image; export/import = `docker save`/`load` a `.dorymachine` file; recipes = an extra build layer; settings = extra `HostConfig` fields. Everything rides the existing `MachineService` over `any ContainerRuntime`.

**Tech Stack:** Swift 6 / SwiftUI, Swift Testing (`import Testing`, `@Test`, `#expect`), Xcode 27 beta toolchain, Docker Engine HTTP API over Dory's socket.

## Global Constraints

- Build: `scripts/build.sh` — success = `xcodebuild_exit=0`, no `error:` lines. IGNORE SourceKit/IDE diagnostics (e.g. "No such module 'Testing'", "Cannot find type ... in scope") — they are known false positives; the authoritative signal is `xcodebuild_exit=0`.
- Tests: `scripts/test.sh -only-testing:DoryTests/<Suite>`.
- After a build, `Dory.xcodeproj/project.pbxproj` may get an `objectVersion` bump — do NOT stage/commit it. Stage only the source/test files each task names. Never stage `.claude-tasks.md`.
- The Xcode project uses `PBXFileSystemSynchronizedRootGroup` — added/removed `.swift` files need NO `project.pbxproj` edits.
- No inline comments; no docstrings (except public-API needing them); strict types; guard clauses; explicit errors.
- Snapshot image repo = `dory-snapshot/<machineName>`; tag = a host-supplied short id (NO `Date.now()` in engine; Swift supplies timestamps/ids). Recipe image tag = `dory-recipe/<recipeId>-<arch>` built FROM the base `dory-machine/<baseImage>-<arch>`.
- Snapshot labels (verbatim keys): `dory.machine`, `dory.machine.version`, `dory.machine.arch`, `dory.machine.boot`, `dory.snapshot.of`, `dory.snapshot.created`, `dory.snapshot.note`, `dory.recipe`.
- `.dorymachine` file = the OCI image tar from `GET /images/<ref>/get` (docker-save format); import via `POST /images/load`; a valid file's image carries a `dory.machine` label.
- Existing types to reuse: `MachineService` (`Dory/Runtime/Machines/MachineService.swift`), `MachineDistro`/`MachineArch`/`MachineImageBuilder`, `MachineError`, `Machine` model, `DockerEngineRuntime` HTTP helpers (`http.send(HTTPRequest(method:path:headers:body:))`, `http.stream(_:onChunk:onComplete:)`), `HTTPResponse{statusCode,body,isSuccess}`, `AppStore.tarDirectory`/`parseBuildLine`.

---

### Task 1: Runtime — commit / saveImage / loadImage

**Files:**
- Modify: `Dory/Runtime/ContainerRuntime.swift` (protocol + default no-ops)
- Modify: `Dory/Runtime/Docker/DockerEngineRuntime.swift` (implementations)
- Test: `DoryTests/MachineSnapshotTests.swift` (new)

**Interfaces:**
- Produces on `ContainerRuntime`:
  - `func commit(containerID: String, repo: String, tag: String, labels: [String: String]) async throws -> String` (returns new image id; default no-op returns `""`)
  - `func saveImage(reference: String) -> AsyncStream<Data>` (default: empty stream)
  - `func loadImage(tar: Data) async throws` (default: no-op)
- Produces pure helper for testing: `enum DockerImageOps { static func commitPath(container: String, repo: String, tag: String) -> String }`

- [ ] **Step 1: Failing test for the commit path/label encoding (pure)**

Create `DoryTests/MachineSnapshotTests.swift`:

```swift
import Testing
import Foundation
@testable import Dory

struct DockerImageOpsTests {
    @Test func commitPathEncodesQuery() {
        let path = DockerImageOps.commitPath(container: "dory-machine-dev", repo: "dory-snapshot/dev", tag: "s1700000000")
        #expect(path == "/commit?container=dory-machine-dev&repo=dory-snapshot/dev&tag=s1700000000")
    }
}
```

- [ ] **Step 2: Run it — expect fail**

Run: `scripts/test.sh -only-testing:DoryTests/DockerImageOpsTests`
Expected: FAIL (cannot find `DockerImageOps`).

- [ ] **Step 3: Add the protocol members + default no-ops + the pure helper**

In `Dory/Runtime/ContainerRuntime.swift`, add to the `protocol ContainerRuntime` member list (near `func build`):

```swift
    func commit(containerID: String, repo: String, tag: String, labels: [String: String]) async throws -> String
    func saveImage(reference: String) -> AsyncStream<Data>
    func loadImage(tar: Data) async throws
```

In the `extension ContainerRuntime` (defaults), add:

```swift
    func commit(containerID: String, repo: String, tag: String, labels: [String: String]) async throws -> String { "" }
    func saveImage(reference: String) -> AsyncStream<Data> { AsyncStream { $0.finish() } }
    func loadImage(tar: Data) async throws {}
```

Add a new file is not needed; put the pure helper at the bottom of `ContainerRuntime.swift`:

```swift
enum DockerImageOps {
    static func commitPath(container: String, repo: String, tag: String) -> String {
        "/commit?container=\(container)&repo=\(repo)&tag=\(tag)"
    }
}
```

- [ ] **Step 4: Run the test — expect pass**

Run: `scripts/test.sh -only-testing:DoryTests/DockerImageOpsTests`
Expected: PASS.

- [ ] **Step 5: Implement the three methods in `DockerEngineRuntime`**

Add to `Dory/Runtime/Docker/DockerEngineRuntime.swift` (near `removeImage`):

```swift
    func commit(containerID: String, repo: String, tag: String, labels: [String: String]) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: ["Labels": labels])
        let path = DockerImageOps.commitPath(container: containerID, repo: repo, tag: tag)
        let response = try await http.send(HTTPRequest(method: "POST", path: path,
            headers: [(name: "Content-Type", value: "application/json")], body: body))
        guard response.isSuccess else {
            throw HTTPError.status(code: response.statusCode, message: String(decoding: response.body, as: UTF8.self))
        }
        struct Out: Decodable { let Id: String }
        return (try? JSONDecoder().decode(Out.self, from: response.body))?.Id ?? "\(repo):\(tag)"
    }

    func saveImage(reference: String) -> AsyncStream<Data> {
        let encoded = reference.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? reference
        let request = HTTPRequest(method: "GET", path: "/images/\(encoded)/get")
        let client = http
        return AsyncStream { continuation in
            let handle = client.stream(request, onChunk: { continuation.yield($0) }, onComplete: { continuation.finish() })
            continuation.onTermination = { _ in handle.close() }
        }
    }

    func loadImage(tar: Data) async throws {
        let response = try await http.send(HTTPRequest(method: "POST", path: "/images/load",
            headers: [(name: "Content-Type", value: "application/x-tar")], body: tar))
        guard response.isSuccess else {
            throw HTTPError.status(code: response.statusCode, message: String(decoding: response.body, as: UTF8.self))
        }
    }
```

(If `client.stream` returns a type whose close method differs, mirror exactly what `build(contextTar:query:)` does in the same file — it uses the identical `handle`/`close()` pattern.)

- [ ] **Step 6: Build + commit**

Run: `scripts/build.sh` → `xcodebuild_exit=0`.
Run: `scripts/test.sh -only-testing:DoryTests/DockerImageOpsTests` → PASS.

```bash
git add Dory/Runtime/ContainerRuntime.swift Dory/Runtime/Docker/DockerEngineRuntime.swift DoryTests/MachineSnapshotTests.swift
git commit -m "feat(machines): runtime commit/saveImage/loadImage for snapshots"
```

---

### Task 2: MachineSnapshot model + label codec + snapshot/list

**Files:**
- Create: `Dory/Runtime/Machines/MachineSnapshot.swift`
- Modify: `Dory/Runtime/Machines/MachineService.swift`
- Test: `DoryTests/MachineSnapshotTests.swift` (append)

**Interfaces:**
- Consumes: `commit` (Task 1), `MachineArch`, `MachineDistro`.
- Produces:
  - `struct MachineSnapshot: Identifiable, Hashable, Sendable { let id: String; let imageRef: String; let machineName: String; let note: String; let createdISO: String; let sizeBytes: Int64; let distro: String; let version: String; let arch: String }`
  - `enum SnapshotLabels { static func make(machine: Machine, note: String, createdISO: String) -> [String: String]; static func snapshot(fromImageJSON entry: ...) -> MachineSnapshot? }`
  - `MachineService.snapshot(machine: Machine, note: String, createdISO: String, tag: String) async throws -> MachineSnapshot`
  - `MachineService.listSnapshots() async -> [MachineSnapshot]`

- [ ] **Step 1: Failing tests (pure codec)**

Append to `DoryTests/MachineSnapshotTests.swift`:

```swift
struct SnapshotCodecTests {
    @Test func buildsSnapshotLabels() {
        let m = Machine(name: "dev", distro: "Ubuntu", version: "24.04 LTS", status: .running,
                        cpuPercent: 0, memoryDisplay: "—", ip: "—", letter: "U", badgeHex: 0,
                        containerID: "c1", arch: "arm64")
        let labels = SnapshotLabels.make(machine: m, note: "before upgrade", createdISO: "2026-06-22T10:00:00Z")
        #expect(labels["dory.snapshot.of"] == "dev")
        #expect(labels["dory.snapshot.note"] == "before upgrade")
        #expect(labels["dory.snapshot.created"] == "2026-06-22T10:00:00Z")
        #expect(labels["dory.machine.arch"] == "arm64")
    }

    @Test func mapsImagesJSONToSnapshots() {
        let json = """
        [{"Id":"sha256:abc","RepoTags":["dory-snapshot/dev:s17"],"Size":123456789,
          "Labels":{"dory.snapshot.of":"dev","dory.snapshot.note":"n","dory.snapshot.created":"2026-06-22T10:00:00Z",
                    "dory.machine":"ubuntu","dory.machine.version":"24.04 LTS","dory.machine.arch":"arm64"}},
         {"Id":"sha256:def","RepoTags":["redis:7"],"Size":1,"Labels":{}}]
        """.data(using: .utf8)!
        let snaps = SnapshotLabels.snapshots(fromImagesJSON: json)
        #expect(snaps.count == 1)
        #expect(snaps[0].machineName == "dev")
        #expect(snaps[0].imageRef == "dory-snapshot/dev:s17")
        #expect(snaps[0].distro == "Ubuntu")
        #expect(snaps[0].arch == "arm64")
        #expect(snaps[0].sizeBytes == 123456789)
    }
}
```

- [ ] **Step 2: Run → fail.** `scripts/test.sh -only-testing:DoryTests/SnapshotCodecTests` → FAIL (no `SnapshotLabels`).

- [ ] **Step 3: Create `MachineSnapshot.swift`**

```swift
import Foundation

struct MachineSnapshot: Identifiable, Hashable, Sendable {
    let id: String
    let imageRef: String
    let machineName: String
    let note: String
    let createdISO: String
    let sizeBytes: Int64
    let distro: String
    let version: String
    let arch: String
}

enum SnapshotLabels {
    static let ofKey = "dory.snapshot.of"
    static let noteKey = "dory.snapshot.note"
    static let createdKey = "dory.snapshot.created"

    static func make(machine: Machine, note: String, createdISO: String) -> [String: String] {
        let family = MachineDistro.all.first { $0.display == machine.distro }?.family ?? machine.distro.lowercased()
        return [
            "dory.machine": family,
            "dory.machine.version": machine.version,
            "dory.machine.arch": machine.arch.isEmpty ? MachineArch.host.rawValue : machine.arch,
            ofKey: machine.name,
            noteKey: note,
            createdKey: createdISO,
        ]
    }

    static func snapshots(fromImagesJSON data: Data) -> [MachineSnapshot] {
        struct Entry: Decodable { let Id: String; let RepoTags: [String]?; let Size: Int64?; let Labels: [String: String]? }
        guard let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return entries.compactMap { entry -> MachineSnapshot? in
            guard let labels = entry.Labels, let of = labels[ofKey] else { return nil }
            let ref = entry.RepoTags?.first(where: { $0 != "<none>:<none>" }) ?? entry.Id
            let family = labels["dory.machine"] ?? ""
            let display = MachineDistro.forFamily(family)?.display ?? family
            return MachineSnapshot(
                id: entry.Id, imageRef: ref, machineName: of,
                note: labels[noteKey] ?? "", createdISO: labels[createdKey] ?? "",
                sizeBytes: entry.Size ?? 0, distro: display,
                version: labels["dory.machine.version"] ?? "",
                arch: labels["dory.machine.arch"] ?? ""
            )
        }
    }
}
```

- [ ] **Step 4: Run → pass.** `scripts/test.sh -only-testing:DoryTests/SnapshotCodecTests` → PASS.

- [ ] **Step 5: Add `snapshot` + `listSnapshots` to MachineService**

Append inside `struct MachineService`:

```swift
    static let snapshotRepoPrefix = "dory-snapshot/"

    func snapshot(machine: Machine, note: String, createdISO: String, tag: String) async throws -> MachineSnapshot {
        let labels = SnapshotLabels.make(machine: machine, note: note, createdISO: createdISO)
        let repo = Self.snapshotRepoPrefix + machine.name
        let id = try await runtime.commit(containerID: Self.containerName(for: machine.name), repo: repo, tag: tag, labels: labels)
        return MachineSnapshot(id: id, imageRef: "\(repo):\(tag)", machineName: machine.name, note: note,
                               createdISO: createdISO, sizeBytes: 0, distro: machine.distro, version: machine.version,
                               arch: machine.arch.isEmpty ? MachineArch.host.rawValue : machine.arch)
    }

    func listSnapshots() async -> [MachineSnapshot] {
        let filters = "{\"label\":[\"\(SnapshotLabels.ofKey)\"]}"
        let encoded = filters.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? filters
        guard let response = await runtime.proxyRequest(method: "GET", path: "/images/json?filters=\(encoded)", headers: [], body: Data()),
              response.isSuccess else { return [] }
        return SnapshotLabels.snapshots(fromImagesJSON: response.body)
            .sorted { $0.createdISO > $1.createdISO }
    }
```

- [ ] **Step 6: Build + commit**

`scripts/build.sh` → `xcodebuild_exit=0`. `scripts/test.sh -only-testing:DoryTests/SnapshotCodecTests` → PASS.

```bash
git add Dory/Runtime/Machines/MachineSnapshot.swift Dory/Runtime/Machines/MachineService.swift DoryTests/MachineSnapshotTests.swift
git commit -m "feat(machines): MachineSnapshot model + snapshot/list"
```

---

### Task 3: Clone / restore from a snapshot

**Files:**
- Modify: `Dory/Runtime/Machines/MachineService.swift`

**Interfaces:**
- Consumes: `MachineSnapshot` (Task 2), `createContainer` (existing private), `MachineDistro`, `MachineArch`.
- Produces:
  - `MachineService.cloneFromSnapshot(_ snapshot: MachineSnapshot, newName: String) async throws`
  - `MachineService.restore(_ snapshot: MachineSnapshot) async throws`

- [ ] **Step 1: Add a private `createFromImage` + the two public methods**

`createContainer` currently builds the body from a `MachineDistro`. Add an image-driven variant that reuses the same HostConfig but a given image + labels. Append to `MachineService`:

```swift
    private func runFromImage(name: String, imageRef: String, snapshot: MachineSnapshot) async throws {
        let distro = MachineDistro.forFamily(MachineDistro.all.first { $0.display == snapshot.distro }?.family ?? "")
        let boot: MachineDistro.Boot = distro?.boot ?? .systemd
        let cmd = boot == .systemd ? ["/sbin/init"] : Self.keepalive
        let body: [String: Any] = [
            "Hostname": name, "Image": imageRef, "Cmd": cmd, "Env": ["container=docker"],
            "StopSignal": "SIGRTMIN+3",
            "Labels": [Self.label: distro?.family ?? snapshot.distro.lowercased(),
                       Self.versionLabel: snapshot.version,
                       Self.archLabel: snapshot.arch],
            "HostConfig": ["Privileged": true, "CgroupnsMode": "host",
                           "Tmpfs": ["/run": "", "/run/lock": "", "/tmp": ""],
                           "RestartPolicy": ["Name": "unless-stopped"]] as [String: Any],
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        let platform = (snapshot.arch.isEmpty ? MachineArch.host.rawValue : snapshot.arch)
        let encodedPlatform = "linux/\(platform)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "linux/\(platform)"
        guard let response = await runtime.proxyRequest(method: "POST",
            path: "/containers/create?name=\(Self.containerName(for: name))&platform=\(encodedPlatform)",
            headers: [(name: "Content-Type", value: "application/json")], body: data),
            response.isSuccess else {
            throw MachineError.createFailed("could not create machine from snapshot")
        }
        try await runtime.start(containerID: Self.containerName(for: name))
    }

    func cloneFromSnapshot(_ snapshot: MachineSnapshot, newName: String) async throws {
        try await runFromImage(name: newName, imageRef: snapshot.imageRef, snapshot: snapshot)
    }

    func restore(_ snapshot: MachineSnapshot) async throws {
        try? await runtime.stop(containerID: Self.containerName(for: snapshot.machineName))
        try? await runtime.remove(containerID: Self.containerName(for: snapshot.machineName))
        try await runFromImage(name: snapshot.machineName, imageRef: snapshot.imageRef, snapshot: snapshot)
    }
```

- [ ] **Step 2: Build + commit**

`scripts/build.sh` → `xcodebuild_exit=0`. Re-run `DoryTests/SnapshotCodecTests` + `DoryTests/MachineServiceHelperTests` → PASS (no regression).

```bash
git add Dory/Runtime/Machines/MachineService.swift
git commit -m "feat(machines): clone + restore from snapshot"
```

---

### Task 4: Export / import `.dorymachine`

**Files:**
- Modify: `Dory/Runtime/Machines/MachineService.swift`
- Test: `DoryTests/MachineSnapshotTests.swift` (append — import validation is pure)

**Interfaces:**
- Consumes: `saveImage`/`loadImage` (Task 1), `MachineSnapshot`.
- Produces:
  - `static func isDoryMachineImage(loadedLabels: [String: String]) -> Bool` (pure validation helper)
  - `MachineService.export(_ snapshot: MachineSnapshot, to fileURL: URL) async throws`
  - `MachineService.importMachine(from fileURL: URL) async throws -> String` (returns the loaded image ref)

- [ ] **Step 1: Failing test for the validation helper**

Append to `DoryTests/MachineSnapshotTests.swift`:

```swift
struct DoryMachineFileTests {
    @Test func acceptsDoryLabeledImage() {
        #expect(MachineService.isDoryMachineImage(loadedLabels: ["dory.machine": "ubuntu"]))
    }
    @Test func rejectsPlainImage() {
        #expect(!MachineService.isDoryMachineImage(loadedLabels: [:]))
        #expect(!MachineService.isDoryMachineImage(loadedLabels: ["maintainer": "x"]))
    }
}
```

- [ ] **Step 2: Run → fail.** `scripts/test.sh -only-testing:DoryTests/DoryMachineFileTests` → FAIL.

- [ ] **Step 3: Implement helper + export/import**

Append to `MachineService`:

```swift
    static func isDoryMachineImage(loadedLabels: [String: String]) -> Bool {
        loadedLabels.keys.contains(label)
    }

    func export(_ snapshot: MachineSnapshot, to fileURL: URL) async throws {
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: fileURL) else {
            throw MachineError.createFailed("could not open \(fileURL.lastPathComponent) for writing")
        }
        defer { try? handle.close() }
        for await chunk in runtime.saveImage(reference: snapshot.imageRef) {
            try handle.write(contentsOf: chunk)
        }
    }

    func importMachine(from fileURL: URL) async throws -> String {
        guard let tar = try? Data(contentsOf: fileURL) else {
            throw MachineError.createFailed("could not read \(fileURL.lastPathComponent)")
        }
        try await runtime.loadImage(tar: tar)
        let loaded = await listSnapshots().first
        guard let loaded, Self.isDoryMachineImage(loadedLabels: [Self.label: loaded.distro]) else {
            throw MachineError.createFailed("Not a Dory machine file")
        }
        return loaded.imageRef
    }
```

(Note: `importMachine` confirms a `dory.snapshot.of`-labeled image appeared after load; the loaded snapshot is then cloneable through `cloneFromSnapshot`.)

- [ ] **Step 4: Run → pass.** `scripts/test.sh -only-testing:DoryTests/DoryMachineFileTests` → PASS.

- [ ] **Step 5: Build + commit**

`scripts/build.sh` → `xcodebuild_exit=0`.

```bash
git add Dory/Runtime/Machines/MachineService.swift DoryTests/MachineSnapshotTests.swift
git commit -m "feat(machines): export/import .dorymachine files"
```

---

### Task 5: Dev recipes (catalog + builder layer + picker)

**Files:**
- Create: `Dory/Runtime/Machines/DevRecipe.swift`
- Modify: `Dory/Runtime/Machines/MachineImageBuilder.swift`, `Dory/Runtime/Machines/MachineService.swift`, `Dory/Models/AppStore.swift`, `Dory/Features/Sheets/NewMachineSheet.swift`
- Test: `DoryTests/MachineSnapshotTests.swift` (append)

**Interfaces:**
- Produces:
  - `struct DevRecipe: Identifiable, Hashable, Sendable { let id: String; let display: String; let icon: String; let install: String }` + `static let all: [DevRecipe]` + `static func forID(_:) -> DevRecipe?`
  - `MachineImageBuilder.recipeDockerfile(baseImageTag: String, recipe: DevRecipe) -> String`
  - `MachineImageBuilder.ensureRecipeImage(distro:arch:recipe:runtime:progress:) async throws -> String`
  - `MachineService.create(...)` gains `recipe: DevRecipe? = nil`; `AppStore.createMachine(...)` gains `recipe: DevRecipe? = nil`.

- [ ] **Step 1: Failing tests (pure)**

Append to `DoryTests/MachineSnapshotTests.swift`:

```swift
struct DevRecipeTests {
    @Test func catalogHasFiveRecipes() {
        #expect(DevRecipe.all.map(\.id) == ["node", "python", "go", "java", "ruby"])
    }
    @Test func recipeDockerfileLayersOnBase() {
        let df = MachineImageBuilder.recipeDockerfile(baseImageTag: "dory-machine/ubuntu:24.04-arm64",
                                                      recipe: DevRecipe.forID("node")!)
        #expect(df.contains("FROM dory-machine/ubuntu:24.04-arm64"))
        #expect(df.contains("nodejs"))
        #expect(!df.contains("/sbin/init"))
    }
}
```

(The recipe layer must NOT redeclare CMD/STOPSIGNAL — it inherits them from the base image.)

- [ ] **Step 2: Run → fail.** `scripts/test.sh -only-testing:DoryTests/DevRecipeTests` → FAIL.

- [ ] **Step 3: Create `DevRecipe.swift`**

```swift
import Foundation

struct DevRecipe: Identifiable, Hashable, Sendable {
    let id: String
    let display: String
    let icon: String
    let install: String

    static let all: [DevRecipe] = [
        DevRecipe(id: "node", display: "Node.js", icon: "hexagon",
                  install: "curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - && apt-get install -y nodejs && corepack enable"),
        DevRecipe(id: "python", display: "Python", icon: "chevron.left.forwardslash.chevron.right",
                  install: "apt-get update && apt-get install -y --no-install-recommends python3 python3-pip python3-venv pipx && rm -rf /var/lib/apt/lists/*"),
        DevRecipe(id: "go", display: "Go", icon: "g.circle",
                  install: "ARCH=$(dpkg --print-architecture); curl -fsSL https://go.dev/dl/go1.23.4.linux-${ARCH}.tar.gz | tar -C /usr/local -xz && echo 'export PATH=$PATH:/usr/local/go/bin' > /etc/profile.d/go.sh"),
        DevRecipe(id: "java", display: "Java", icon: "cup.and.saucer",
                  install: "apt-get update && apt-get install -y --no-install-recommends default-jdk maven && rm -rf /var/lib/apt/lists/*"),
        DevRecipe(id: "ruby", display: "Ruby", icon: "diamond",
                  install: "apt-get update && apt-get install -y --no-install-recommends ruby-full build-essential && gem install bundler && rm -rf /var/lib/apt/lists/*"),
    ]

    static func forID(_ id: String) -> DevRecipe? { all.first { $0.id == id } }
}
```

- [ ] **Step 4: Add `recipeDockerfile` + `ensureRecipeImage` to `MachineImageBuilder`**

```swift
    static func recipeTag(_ recipe: DevRecipe, arch: MachineArch) -> String { "dory-recipe/\(recipe.id)-\(arch.rawValue)" }

    static func recipeDockerfile(baseImageTag: String, recipe: DevRecipe) -> String {
        """
        FROM \(baseImageTag)
        RUN \(recipe.install)
        """
    }

    static func ensureRecipeImage(distro: MachineDistro, arch: MachineArch, recipe: DevRecipe,
                                  runtime: any ContainerRuntime, progress: @escaping @Sendable (String) -> Void) async throws -> String {
        let tag = recipeTag(recipe, arch: arch)
        if await runtime.inspectImage(id: tag) != nil { return tag }
        let baseTag = try await ensureImage(distro, arch: arch, runtime: runtime, progress: progress)
        progress("Installing \(recipe.display) toolchain (one-time)…")
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dory-recipe-\(recipe.id)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try recipeDockerfile(baseImageTag: baseTag, recipe: recipe).write(to: dir.appendingPathComponent("Dockerfile"), atomically: true, encoding: .utf8)
        guard let tar = AppStore.tarDirectory(dir) else { throw MachineError.imageBuildFailed("Could not package recipe context") }
        let encodedTag = tag.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? tag
        let encodedPlatform = arch.platform.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? arch.platform
        var lastError: String?
        for await chunk in runtime.build(contextTar: tar, query: "t=\(encodedTag)&platform=\(encodedPlatform)") {
            for line in String(decoding: chunk, as: UTF8.self).split(separator: "\n") {
                guard let text = AppStore.parseBuildLine(Data(line.utf8)) else { continue }
                progress(text); if text.hasPrefix("ERROR:") { lastError = text }
            }
        }
        guard await runtime.inspectImage(id: tag) != nil else {
            throw MachineError.imageBuildFailed(lastError ?? "recipe image \(tag) not present after build")
        }
        return tag
    }
```

- [ ] **Step 5: Thread `recipe` through `MachineService.create` and `AppStore.createMachine`**

In `MachineService.create(name:distro:arch:progress:)`, add a `recipe: DevRecipe? = nil` parameter; when non-nil, replace the `ensureImage` call with `ensureRecipeImage(distro:arch:recipe:...)`, and add label `"dory.recipe": recipe.id` to the created container by passing it into `createBody` (add an optional `recipe` to `createBody` that injects the label). In `AppStore.createMachine(image:name:arch:)`, add `recipe: DevRecipe? = nil` and pass it to `machineService.create`.

- [ ] **Step 6: Add the "Dev environment" picker to `NewMachineSheet`**

Add `@State private var selectedRecipe: DevRecipe?` (nil = Plain OS). Below the DISTRIBUTION grid add a section:

```swift
VStack(alignment: .leading, spacing: 9) {
    sectionLabel("DEV ENVIRONMENT")
    Picker("", selection: $selectedRecipe) {
        Text("Plain OS").tag(DevRecipe?.none)
        ForEach(DevRecipe.all) { recipe in Text(recipe.display).tag(DevRecipe?.some(recipe)) }
    }
    .labelsHidden().pickerStyle(.menu).frame(width: 220, alignment: .leading)
}
```

In `create()`, pass `recipe: selectedRecipe` to `store.createMachine(...)`.

- [ ] **Step 7: Run tests + build + commit**

`scripts/test.sh -only-testing:DoryTests/DevRecipeTests` → PASS. `scripts/build.sh` → `xcodebuild_exit=0`.

```bash
git add Dory/Runtime/Machines/DevRecipe.swift Dory/Runtime/Machines/MachineImageBuilder.swift Dory/Runtime/Machines/MachineService.swift Dory/Models/AppStore.swift Dory/Features/Sheets/NewMachineSheet.swift DoryTests/MachineSnapshotTests.swift
git commit -m "feat(machines): one-click dev recipes (node/python/go/java/ruby)"
```

---

### Task 6: Machine settings (CPU/RAM/folders/ports) + settings-edit recreate

**Files:**
- Modify: `Dory/Runtime/Machines/MachineService.swift`, `Dory/Models/AppStore.swift`, `Dory/Features/Sheets/NewMachineSheet.swift`
- Test: `DoryTests/MachineSnapshotTests.swift` (append)

**Interfaces:**
- Produces:
  - `struct MachineSettings: Sendable, Hashable { var cpus: Int?; var memoryMB: Int?; var mounts: [(host: String, guest: String)]; var ports: [(host: Int, guest: Int)] }` (use two `[String]`/`[Int]`-pair encodings; in Swift, represent mounts/ports as `[[String]]`/`[[Int]]`-free typed structs — see code)
  - `MachineService.createBody(...)` gains a `settings: MachineSettings` and emits `NanoCpus`/`Memory`/`Binds`/`PortBindings`/`ExposedPorts`.
  - `MachineService.create(...)` and `AppStore.createMachine(...)` accept `settings`.

- [ ] **Step 1: Failing test (pure HostConfig mapping)**

Append:

```swift
struct MachineSettingsTests {
    @Test func encodesResourcesAndMounts() {
        let s = MachineSettings(cpus: 2, memoryMB: 2048,
                                mounts: [MountPair(host: "/Users/x/proj", guest: "/proj")],
                                ports: [PortPair(host: 8080, guest: 80)])
        let host = MachineService.hostConfig(base: [:], settings: s)
        #expect(host["NanoCpus"] as? Int64 == 2_000_000_000)
        #expect(host["Memory"] as? Int64 == 2048 * 1024 * 1024)
        #expect((host["Binds"] as? [String])?.first == "/Users/x/proj:/proj")
        let pb = host["PortBindings"] as? [String: [[String: String]]]
        #expect(pb?["80/tcp"]?.first?["HostPort"] == "8080")
    }
}
```

- [ ] **Step 2: Run → fail.**

- [ ] **Step 3: Implement `MachineSettings` + `hostConfig` merge**

In `MachineService.swift` add:

```swift
struct MountPair: Sendable, Hashable { var host: String; var guest: String }
struct PortPair: Sendable, Hashable { var host: Int; var guest: Int }
struct MachineSettings: Sendable, Hashable {
    var cpus: Int?
    var memoryMB: Int?
    var mounts: [MountPair] = []
    var ports: [PortPair] = []
    static let `default` = MachineSettings(cpus: nil, memoryMB: nil)
}

extension MachineService {
    static func hostConfig(base: [String: Any], settings: MachineSettings) -> [String: Any] {
        var host = base
        if let c = settings.cpus { host["NanoCpus"] = Int64(c) * 1_000_000_000 }
        if let m = settings.memoryMB { host["Memory"] = Int64(m) * 1024 * 1024 }
        if !settings.mounts.isEmpty { host["Binds"] = settings.mounts.map { "\($0.host):\($0.guest)" } }
        if !settings.ports.isEmpty {
            var exposed: [String: [String: String]] = [:]
            var bindings: [String: [[String: String]]] = [:]
            for p in settings.ports {
                exposed["\(p.guest)/tcp"] = [:]
                bindings["\(p.guest)/tcp"] = [["HostPort": "\(p.host)"]]
            }
            host["ExposedPorts"] = exposed
            host["PortBindings"] = bindings
        }
        return host
    }
}
```

Note: `ExposedPorts` is a top-level container-config field; in `createBody`, set `body["ExposedPorts"]` from settings AND merge the rest into `HostConfig`. Adjust `hostConfig` so port `ExposedPorts` is applied to the top-level body — simplest: have `createBody` call `hostConfig` for HostConfig keys and separately set `body["ExposedPorts"]`. Keep the test asserting the `hostConfig` output shape; wire the top-level split in `createBody`.

- [ ] **Step 4: Wire `settings` into `createBody`/`create`/`createMachine`**

`createBody` gains `settings: MachineSettings = .default`; build the base HostConfig dict (Privileged/Cgroupns/Tmpfs/RestartPolicy) then `HostConfig = hostConfig(base: …, settings: settings)`, and set top-level `ExposedPorts`. `create` and `AppStore.createMachine` accept `settings: MachineSettings = .default` and pass it through.

- [ ] **Step 5: Add the "Advanced" disclosure to `NewMachineSheet`**

A `DisclosureGroup("Advanced")` with: CPU stepper (1–8), RAM stepper (1–16 GB), an editable list of host:guest folder mounts (a "+" adds a row with a folder picker for host + a text field for guest), and host:guest port rows. Collect into a `MachineSettings` passed to `create()`.

- [ ] **Step 6: Settings-edit recreate (AppStore)**

Add `AppStore.editMachine(_ machine: Machine, settings: MachineSettings)`: snapshot the machine (auto note "pre-edit", host-supplied ISO+tag) → `machineService.restore`-style recreate but with the new settings (add a `MachineService.recreate(name:settings:)` that auto-snapshots, removes, and runs from that snapshot with the new HostConfig). On any failure, re-run from the auto-snapshot so the machine is never lost.

- [ ] **Step 7: Run tests + build + commit**

`scripts/test.sh -only-testing:DoryTests/MachineSettingsTests` → PASS. `scripts/build.sh` → `xcodebuild_exit=0`.

```bash
git add Dory/Runtime/Machines/MachineService.swift Dory/Models/AppStore.swift Dory/Features/Sheets/NewMachineSheet.swift DoryTests/MachineSnapshotTests.swift
git commit -m "feat(machines): per-machine CPU/RAM/folders/ports + safe settings edit"
```

---

### Task 7: UI — Snapshots sheet, card overflow menu, Import action

**Files:**
- Create: `Dory/Features/Machines/SnapshotsSheet.swift`
- Modify: `Dory/Features/Machines/MachinesView.swift`, `Dory/Models/Models.swift` (`AppSheet` cases), `Dory/ContentView.swift`, `Dory/Models/AppStore.swift`, `Dory/Features/Main/MainColumnView.swift`

**Interfaces:**
- Consumes: `MachineSnapshot`, `MachineService` ops (Tasks 2–4), `AppStore` orchestration.
- Produces: `AppSheet.machineSnapshots`; `AppStore` state `snapshotMachine: Machine?`, `machineSnapshots: [MachineSnapshot]`, and methods `openSnapshots(_:)`, `takeSnapshot(_:note:)`, `cloneSnapshot(_:)`, `restoreSnapshot(_:)`, `exportSnapshot(_:)`, `importMachineFile()`.

- [ ] **Step 1: AppStore orchestration**

Add to `AppStore`: the state above and methods that call `machineService` ops, generating host-side ids/timestamps (`ISO8601DateFormatter` for `createdISO`; tag = `"s" + UUID().uuidString.prefix(8)`), using `NSSavePanel`/`NSOpenPanel` for export/import, routing progress through the existing `creatingMachine` sheet pattern, and calling `loadMachines()` after clone/restore/import. `cloneSnapshot` prompts for a new name (reuse the picker's `defaultName` style: `<machine>-copy-<4hex>`).

- [ ] **Step 2: Add `AppSheet.machineSnapshots`** in `Models.swift` and `case .machineSnapshots: SnapshotsSheet()` in `ContentView`'s sheet switch.

- [ ] **Step 3: Create `SnapshotsSheet.swift`** — header (machine name + "Take snapshot" with an optional note field), a list of `store.machineSnapshots` (note, relative time from `createdISO`, `DockerFormat.bytes(sizeBytes)`), each row with Restore / Clone / Export / Delete (Delete = `removeImage`). Match the app's palette/sheet style (see `NewMachineSheet`/`MachineCreationSheet`).

- [ ] **Step 4: Card overflow menu** in `MachinesView.MachineCard`: add a `Menu` (`•••`) to the header with Snapshot, Snapshots…, Clone, Export…, Edit…, Delete (Delete moves into the menu OR stays as the red icon — keep the red icon, add the menu for the rest). Wire to the AppStore methods.

- [ ] **Step 5: Import toolbar action** — in `MainColumnView.toolbar`, for `.machines` add a `secondaryButton("Import") { store.importMachineFile() }` next to the primary "New Machine" (mirror the Images section's "Build" secondary button).

- [ ] **Step 6: Build + commit**

`scripts/build.sh` → `xcodebuild_exit=0`. Re-run all snapshot/machine unit suites → PASS.

```bash
git add Dory/Features/Machines/SnapshotsSheet.swift Dory/Features/Machines/MachinesView.swift Dory/Models/Models.swift Dory/ContentView.swift Dory/Models/AppStore.swift Dory/Features/Main/MainColumnView.swift
git commit -m "feat(machines): snapshots sheet, card menu, import action"
```

---

### Task 8: End-to-end verification (live engine)

**Files:** none (manual + fixes).

- [ ] **Step 1:** `scripts/build.sh` → `xcodebuild_exit=0`; run ALL machine unit suites (`MachineDistroTests`, `MachineImageBuilderTests`, `MachineServiceHelperTests`, `DockerImageOpsTests`, `SnapshotCodecTests`, `DoryMachineFileTests`, `DevRecipeTests`, `MachineSettingsTests`) → PASS.
- [ ] **Step 2:** Launch the app (`DORY_SECTION=machines`). Create an Ubuntu machine; in its terminal `touch /root/marker`. Take a snapshot (note "has marker").
- [ ] **Step 3:** Clone the snapshot → new machine; terminal → `ls /root/marker` exists (clone carried the file).
- [ ] **Step 4:** Export the snapshot to `~/Desktop/x.dorymachine`; delete the snapshot; Import the file; clone it → marker present (round-trip works).
- [ ] **Step 5:** Create a **Node** recipe machine; terminal → `node -v` and `npm -v` work.
- [ ] **Step 6:** Create a machine with **2 CPU / 2 GB**, a mounted host folder, and a published port; verify `nproc`≈2, the folder is visible inside, and the port is reachable on `localhost`.
- [ ] **Step 7:** Edit an existing machine's RAM → confirm it recreates from the auto-snapshot with the new limit and the prior `/root/marker` survives.
- [ ] **Step 8:** Commit any fixes made during verification.

```bash
git add -A && git commit -m "test(machines): portable dev machines e2e fixes"
```

---

## Self-Review Notes

- **Spec coverage:** commit primitive + labels → Tasks 1–2; snapshot/clone/restore → Tasks 2–3; export/import `.dorymachine` + validation → Task 4; dev recipes (5, layered, picker) → Task 5; machine settings (CPU/RAM/folders/ports) + safe recreate → Task 6; UI (snapshots sheet, card menu, import toolbar) → Task 7; tests + live E2E → all tasks + Task 8.
- **Type consistency:** `MachineSnapshot`, `SnapshotLabels`, `DevRecipe`, `MachineSettings`/`MountPair`/`PortPair`, `commit/saveImage/loadImage`, `dory.snapshot.*` label keys, `dory-snapshot/`/`dory-recipe/` repos are used identically across tasks.
- **Open risks flagged in spec:** commit size (recipes clean apt lists), cross-arch `.dorymachine` (arch label carried + emulation), settings-edit recreate transactionality (auto-snapshot before remove). Each is covered by a task step.
