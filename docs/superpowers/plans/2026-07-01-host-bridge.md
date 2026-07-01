# Host Bridge (guest→host browser + login port-forward) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** Let CLIs inside a Dory machine open the Mac browser and complete `localhost:<port>` OAuth logins, via a file-drop bridge over virtiofs plus a host watcher that opens URLs and wires loopback ports back into the machine.

**Architecture:** The guest `dory-open` shim writes atomic JSON requests to `~/.dory/bridge/<machine>/{open,forward}` (mounted at `/opt/dory/bridge`). A host-side `HostBridge` watches those dirs with `DispatchSource`, validates each request (http/https scheme; loopback port 1024–65535), then calls `NSWorkspace.shared.open` or spins up a host `127.0.0.1:<port>` listener bridged into the machine container via `HostPortForwarder`'s exec-nc path. `AppStore` owns `HostBridge` (started in `startLocalNetworking`), registers/unregisters machines on their lifecycle, and gates the watcher behind a persisted "Open logins on my Mac" toggle; `MachineService`/`MachineProvisioner` mount the bridge dir, set `BROWSER=dory-open`, and install the shim (symlinked over `xdg-open`/`sensible-browser`/`www-browser` and, best-effort, `gio`).

**Tech Stack:** Swift 6 (macOS, `@Observable` AppStore, Environment DI, no ViewModels), Foundation `DispatchSource`, `NSWorkspace`, POSIX sockets (existing `HostPortForwarder`), POSIX-sh guest shim, Swift Testing (`@Test`/`#expect`), bash integration tests.

## Sequencing

Global execution order across the three related plans:

1. menu-bar-background (A) — executed FIRST.
2. **host-bridge (B) — THIS PLAN — executed SECOND.**
3. credential-bootstrap (C) — builds on A and B.

This plan MUST be executed AFTER the menu-bar-background plan (`docs/superpowers/plans/2026-07-01-menu-bar-background.md`) and rebased on its edits. The shared files across the three plans are `Dory/Models/AppStore.swift`, `Dory/Runtime/Machines/MachineService.swift`, `Dory/Runtime/Machines/MachineProvisioner.swift`, and `Dory/Features/Settings/SettingsView.swift`. Edits from plan A that this plan rebases on:

- `Dory/Models/AppStore.swift` — plan A adds `isAgentMode`, `shouldOpenWindowOnLaunch`, force-on logic in `setShowMenuBarIcon`, and an `if isAgentMode { showMenuBarIcon = true }` line in the `init`/`realLaunch` load block (~line 112). This plan adds `HostBridge` ownership, machine-bridge registration, and the persisted `openLoginsOnMac` state near the same properties and load block — insert after plan A's lines, do not remove them.
- `Dory/Features/Settings/SettingsView.swift` — plan A changes the `toggleRow` helper signature to add a `disabled: Bool = false` parameter. This plan's new "open logins on my Mac" row calls `toggleRow` and MUST use plan A's updated signature.

Credential-bootstrap (C) is executed after this plan and rebases on both A's and this plan's edits to the shared files.

## Global Constraints

- File-drop over virtiofs is the ONLY proven guest→host channel; no TCP/vsock path exists guest→macOS host.
- Bridge mounted at `/opt/dory/bridge` (NOT under `/run`, which is tmpfs in `createBody`), added as an explicit bind independent of the "Share my Mac home" toggle.
- Request files are JSON, written atomically (write `*.tmp`, then `rename`), consumed-then-deleted by the host.
- Host enforces: http/https scheme allow-list; loopback-only forward ports (1024 ≤ port ≤ 65535); rename-based atomic reads; request TTLs (default 300s); size caps on request files; NO shell interpolation of guest-provided strings.
- Only the user's own machines mount the user's own bridge dir (trust boundary = "code in my dev machine may open my browser / forward a loopback port").
- SwiftUI macOS app, `@Observable` AppStore, Environment-based DI, NO ViewModels. NO line comments; no docstrings except public API.
- Build via `scripts/build.sh` (auto-detects Xcode; `DEVELOPER_DIR` override). NEVER open the Xcode GUI (re-bumps objectVersion 77→110). New `.swift` files under `Dory/` and `DoryTests/` are auto-synced by `PBXFileSystemSynchronizedRootGroup` — NO pbxproj edits needed for source files.
- Swift tests run via `scripts/test.sh`; shell shim tests run with `bash` under `scripts/`.
- Work happens on the existing git branch `feat/host-bridge`; commit frequently.
- Docker/machine engine reached through the dory socket (`~/.dory/dory.sock`); machines are `dory-machine-<name>` containers; the shared VM engine container is `dory-engine`.

---

## File Structure

| File | Responsibility |
| --- | --- |
| `Dory/Net/HostBridge.swift` (new) | Host watcher: per-machine `DispatchSource` over `open/`+`forward/`, request decode, URL-scheme + port validation, `NSWorkspace.open`, forward wiring via `HostPortForwarder`, TTL teardown, `startWatching`/`stopWatching`. |
| `Dory/Runtime/Machines/DoryOpenShim.swift` (new) | The `dory-open` POSIX-sh script as a Swift string (drops a leading `open` arg for `gio open <url>`) + install-command builder (write to `/usr/local/bin/dory-open`, symlink `xdg-open`/`sensible-browser`/`www-browser`, best-effort `gio`). |
| `Dory/Net/HostPortForwarder.swift` (modify) | Add `forwardLoopback(machine:port:ttl:)` + `teardownLoopback(machine:port:)` on-demand entry points reusing the exec-nc bridge, keyed per (machine, port). |
| `Dory/Runtime/Machines/MachineService.swift` (modify) | Add `/opt/dory/bridge` bind + `BROWSER=dory-open` env in `createBody`; expose `bridgeHostDir(for:)`. |
| `Dory/Runtime/Machines/MachineProvisioner.swift` (modify) | Append shim install + symlinks + `ensure socat` to the provisioning script. |
| `Dory/Models/AppStore.swift` (modify) | Own `HostBridge`; start/stop it in `startLocalNetworking`/`stopLocalNetworking`; register/unregister machine bridge dirs on start/stop/delete; persisted `openLoginsOnMac` state + setter gating the bridge. |
| `Dory/Features/Settings/SettingsView.swift` (modify) | Add the "Open logins on my Mac" toggle row (rebased on plan A's `toggleRow` signature). |
| `scripts/readiness.sh` (modify) | Add `--bridge` / `RUN_BRIDGE` case running `test_bridge`: fake login in a machine calls `dory-open`, assert host saw the open request (stubbed opener) and forward wired host↔guest. |
| `DoryTests/HostBridgeTests.swift` (new) | Swift Testing: URL-scheme validation, forward-port validation, request JSON encode/decode, atomic (rename) read, disabled-gate skip. |
| `DoryTests/DoryOpenShimTests.swift` (new) | Swift Testing: shim string contains the required install/symlink commands (incl. `gio`), drops a leading `open` arg, and no unquoted interpolation points. |
| `DoryTests/HostBridgeForwardTests.swift` (new) | Swift Testing: `HostPortForwarder.forwardLoopback`/`teardownLoopback` idempotency + key accounting. |
| `DoryTests/OpenLoginsOnMacTests.swift` (new) | Swift Testing: `AppStore.openLoginsOnMac` default (`true`) + setter toggle. |
| `scripts/test-dory-open.sh` (new) | Bash: run the extracted `dory-open` shim against fixture URLs (incl. percent-encoded `redirect_uri`) + fixture `/proc/net/tcp`(6), assert port extraction + LISTEN scan + atomic writes. |

---

### Task 1: HostBridge request model + JSON encode/decode

**Files:**
- Create `Dory/Net/HostBridge.swift`
- Create `DoryTests/HostBridgeTests.swift`

**Interfaces:**
- Consumes: (none)
- Produces:
  - `struct OpenRequest: Codable, Sendable { let url: String; let cwd: String?; let ts: Int }`
  - `struct ForwardRequest: Codable, Sendable { let port: Int; let ts: Int; let ttlSec: Int? }`
  - `enum HostBridge { static func decodeOpen(_ data: Data) -> OpenRequest? }`
  - `enum HostBridge { static func decodeForward(_ data: Data) -> ForwardRequest? }`

Steps:

- [ ] Create `DoryTests/HostBridgeTests.swift` with this exact content (the failing test):
  ```swift
  import Testing
  import Foundation
  @testable import Dory

  struct HostBridgeTests {
      @Test func decodesOpenRequest() {
          let json = #"{"url":"https://example.com/cb?code=1","cwd":"/home/me","ts":1719800000}"#
          let req = HostBridge.decodeOpen(Data(json.utf8))
          #expect(req?.url == "https://example.com/cb?code=1")
          #expect(req?.cwd == "/home/me")
          #expect(req?.ts == 1719800000)
      }

      @Test func decodesForwardRequest() {
          let json = #"{"port":53219,"ts":1719800000,"ttlSec":300}"#
          let req = HostBridge.decodeForward(Data(json.utf8))
          #expect(req?.port == 53219)
          #expect(req?.ttlSec == 300)
      }

      @Test func rejectsMalformedJSON() {
          #expect(HostBridge.decodeOpen(Data("not json".utf8)) == nil)
          #expect(HostBridge.decodeForward(Data(#"{"port":"x"}"#.utf8)) == nil)
      }
  }
  ```
- [ ] Run `scripts/test.sh -only-testing:DoryTests/HostBridgeTests` — expected FAIL: `cannot find 'HostBridge' in scope`.
- [ ] Create `Dory/Net/HostBridge.swift` with this exact content (minimal to pass):
  ```swift
  import Foundation

  struct OpenRequest: Codable, Sendable {
      let url: String
      let cwd: String?
      let ts: Int
  }

  struct ForwardRequest: Codable, Sendable {
      let port: Int
      let ts: Int
      let ttlSec: Int?
  }

  enum HostBridge {
      static func decodeOpen(_ data: Data) -> OpenRequest? {
          guard data.count <= maxRequestBytes else { return nil }
          return try? JSONDecoder().decode(OpenRequest.self, from: data)
      }

      static func decodeForward(_ data: Data) -> ForwardRequest? {
          guard data.count <= maxRequestBytes else { return nil }
          return try? JSONDecoder().decode(ForwardRequest.self, from: data)
      }

      static let maxRequestBytes = 64 * 1024
  }
  ```
- [ ] Run `scripts/test.sh -only-testing:DoryTests/HostBridgeTests` — expected PASS (3 tests).
- [ ] Commit: `git add Dory/Net/HostBridge.swift DoryTests/HostBridgeTests.swift && git commit -m "feat(bridge): host-bridge request model + JSON decode"`

---

### Task 2: URL scheme allow-list validation

**Files:**
- Modify `Dory/Net/HostBridge.swift`
- Modify `DoryTests/HostBridgeTests.swift`

**Interfaces:**
- Consumes: `OpenRequest`
- Produces: `enum HostBridge { static func allowedURL(_ raw: String) -> URL? }`

Steps:

- [ ] Add this test method inside `struct HostBridgeTests` in `DoryTests/HostBridgeTests.swift` (place it directly after `rejectsMalformedJSON`):
  ```swift
      @Test func allowsHTTPAndHTTPSOnly() {
          #expect(HostBridge.allowedURL("https://example.com/cb?code=1") != nil)
          #expect(HostBridge.allowedURL("http://127.0.0.1:53219/cb") != nil)
          #expect(HostBridge.allowedURL("file:///etc/passwd") == nil)
          #expect(HostBridge.allowedURL("vscode://x") == nil)
          #expect(HostBridge.allowedURL("") == nil)
          #expect(HostBridge.allowedURL("javascript:alert(1)") == nil)
          #expect(HostBridge.allowedURL("HTTPS://EXAMPLE.com") != nil)
      }
  ```
- [ ] Run `scripts/test.sh -only-testing:DoryTests/HostBridgeTests` — expected FAIL: `type 'HostBridge' has no member 'allowedURL'`.
- [ ] Add this method to `enum HostBridge` in `Dory/Net/HostBridge.swift` (after `maxRequestBytes`):
  ```swift
      static func allowedURL(_ raw: String) -> URL? {
          guard !raw.isEmpty, raw.utf8.count <= 8192, let url = URL(string: raw) else { return nil }
          guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
          return url
      }
  ```
- [ ] Run `scripts/test.sh -only-testing:DoryTests/HostBridgeTests` — expected PASS (4 tests).
- [ ] Commit: `git add Dory/Net/HostBridge.swift DoryTests/HostBridgeTests.swift && git commit -m "feat(bridge): http/https scheme allow-list"`

---

### Task 3: Forward-port range validation

**Files:**
- Modify `Dory/Net/HostBridge.swift`
- Modify `DoryTests/HostBridgeTests.swift`

**Interfaces:**
- Consumes: `ForwardRequest`
- Produces: `enum HostBridge { static func allowedForwardPort(_ port: Int) -> Bool }`

Steps:

- [ ] Add this test method inside `struct HostBridgeTests` (after `allowsHTTPAndHTTPSOnly`):
  ```swift
      @Test func forwardPortRange() {
          #expect(HostBridge.allowedForwardPort(1024))
          #expect(HostBridge.allowedForwardPort(53219))
          #expect(HostBridge.allowedForwardPort(65535))
          #expect(!HostBridge.allowedForwardPort(1023))
          #expect(!HostBridge.allowedForwardPort(80))
          #expect(!HostBridge.allowedForwardPort(0))
          #expect(!HostBridge.allowedForwardPort(65536))
          #expect(!HostBridge.allowedForwardPort(-5))
      }
  ```
- [ ] Run `scripts/test.sh -only-testing:DoryTests/HostBridgeTests` — expected FAIL: `type 'HostBridge' has no member 'allowedForwardPort'`.
- [ ] Add this method to `enum HostBridge` in `Dory/Net/HostBridge.swift` (after `allowedURL`):
  ```swift
      static func allowedForwardPort(_ port: Int) -> Bool {
          port >= 1024 && port <= 65535
      }
  ```
- [ ] Run `scripts/test.sh -only-testing:DoryTests/HostBridgeTests` — expected PASS (5 tests).
- [ ] Commit: `git add Dory/Net/HostBridge.swift DoryTests/HostBridgeTests.swift && git commit -m "feat(bridge): loopback forward-port range check"`

---

### Task 4: TTL resolution (clamp + default)

**Files:**
- Modify `Dory/Net/HostBridge.swift`
- Modify `DoryTests/HostBridgeTests.swift`

**Interfaces:**
- Consumes: `ForwardRequest`
- Produces: `enum HostBridge { static func resolvedTTL(_ ttlSec: Int?) -> Int }`

Steps:

- [ ] Add this test method inside `struct HostBridgeTests` (after `forwardPortRange`):
  ```swift
      @Test func ttlDefaultsAndClamps() {
          #expect(HostBridge.resolvedTTL(nil) == 300)
          #expect(HostBridge.resolvedTTL(120) == 120)
          #expect(HostBridge.resolvedTTL(0) == 300)
          #expect(HostBridge.resolvedTTL(-10) == 300)
          #expect(HostBridge.resolvedTTL(99999) == 3600)
      }
  ```
- [ ] Run `scripts/test.sh -only-testing:DoryTests/HostBridgeTests` — expected FAIL: `type 'HostBridge' has no member 'resolvedTTL'`.
- [ ] Add this method to `enum HostBridge` in `Dory/Net/HostBridge.swift` (after `allowedForwardPort`):
  ```swift
      static func resolvedTTL(_ ttlSec: Int?) -> Int {
          guard let ttlSec, ttlSec > 0 else { return 300 }
          return min(ttlSec, 3600)
      }
  ```
- [ ] Run `scripts/test.sh -only-testing:DoryTests/HostBridgeTests` — expected PASS (6 tests).
- [ ] Commit: `git add Dory/Net/HostBridge.swift DoryTests/HostBridgeTests.swift && git commit -m "feat(bridge): forward TTL default + clamp"`

---

### Task 5: Atomic (rename) read helper

**Files:**
- Modify `Dory/Net/HostBridge.swift`
- Modify `DoryTests/HostBridgeTests.swift`

**Interfaces:**
- Consumes: (filesystem)
- Produces: `enum HostBridge { static func consume(at url: URL) -> Data? }`

Behavior: skip files ending in `.tmp` (still being written); read then delete; return nil for missing/`.tmp`/oversized files.

Steps:

- [ ] Add these test methods inside `struct HostBridgeTests` (after `ttlDefaultsAndClamps`):
  ```swift
      @Test func consumeReadsThenDeletes() throws {
          let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
          try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
          defer { try? FileManager.default.removeItem(at: dir) }
          let file = dir.appendingPathComponent("req.json")
          try Data("payload".utf8).write(to: file)
          let data = HostBridge.consume(at: file)
          #expect(data == Data("payload".utf8))
          #expect(!FileManager.default.fileExists(atPath: file.path))
      }

      @Test func consumeSkipsTmpFiles() throws {
          let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
          try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
          defer { try? FileManager.default.removeItem(at: dir) }
          let file = dir.appendingPathComponent("req.json.tmp")
          try Data("partial".utf8).write(to: file)
          #expect(HostBridge.consume(at: file) == nil)
          #expect(FileManager.default.fileExists(atPath: file.path))
      }
  ```
- [ ] Run `scripts/test.sh -only-testing:DoryTests/HostBridgeTests` — expected FAIL: `type 'HostBridge' has no member 'consume'`.
- [ ] Add this method to `enum HostBridge` in `Dory/Net/HostBridge.swift` (after `resolvedTTL`):
  ```swift
      static func consume(at url: URL) -> Data? {
          guard !url.lastPathComponent.hasSuffix(".tmp") else { return nil }
          guard let data = try? Data(contentsOf: url), data.count <= maxRequestBytes else {
              try? FileManager.default.removeItem(at: url)
              return nil
          }
          try? FileManager.default.removeItem(at: url)
          return data
      }
  ```
- [ ] Run `scripts/test.sh -only-testing:DoryTests/HostBridgeTests` — expected PASS (8 tests).
- [ ] Commit: `git add Dory/Net/HostBridge.swift DoryTests/HostBridgeTests.swift && git commit -m "feat(bridge): atomic rename-based request read"`

---

### Task 6: HostPortForwarder on-demand loopback forward + teardown

**Files:**
- Modify `Dory/Net/HostPortForwarder.swift` (add methods after `stopAll()` at line 53; add stored state near `listeners` at line 18)
- Create `DoryTests/HostBridgeForwardTests.swift`

**Interfaces:**
- Consumes: existing `HostPortForwarder.execBridge`, `Listener`, `listenLoopback`
- Produces:
  - `func forwardLoopback(machine: String, port: Int, ttl: Int) -> Bool`
  - `func teardownLoopback(machine: String, port: Int)`
  - `func activeLoopbackKeys() -> Set<String>` (test observability; key format `"<machine>:<port>"`)

Behavior: idempotent per (machine, port); returns `false` if a listener for that port cannot bind; forces the exec bridge (bypass direct TCP) since the target is the machine's own container loopback, reached only via `container exec <dory-machine-<machine>> nc 127.0.0.1 <port>`.

Steps:

- [ ] Create `DoryTests/HostBridgeForwardTests.swift` with this exact content:
  ```swift
  import Testing
  import Foundation
  @testable import Dory

  struct HostBridgeForwardTests {
      @Test func forwardIsIdempotentPerMachinePort() {
          let fwd = HostPortForwarder(targetHost: "127.0.0.1", containerBinary: nil, engineName: "")
          defer { fwd.stopAll() }
          let first = fwd.forwardLoopback(machine: "dev", port: 54010, ttl: 300)
          let second = fwd.forwardLoopback(machine: "dev", port: 54010, ttl: 300)
          #expect(first)
          #expect(second)
          #expect(fwd.activeLoopbackKeys() == ["dev:54010"])
      }

      @Test func teardownRemovesKey() {
          let fwd = HostPortForwarder(targetHost: "127.0.0.1", containerBinary: nil, engineName: "")
          defer { fwd.stopAll() }
          _ = fwd.forwardLoopback(machine: "dev", port: 54011, ttl: 300)
          fwd.teardownLoopback(machine: "dev", port: 54011)
          #expect(fwd.activeLoopbackKeys().isEmpty)
      }

      @Test func distinctMachinesTracksSeparateKeys() {
          let fwd = HostPortForwarder(targetHost: "127.0.0.1", containerBinary: nil, engineName: "")
          defer { fwd.stopAll() }
          _ = fwd.forwardLoopback(machine: "a", port: 54012, ttl: 300)
          _ = fwd.forwardLoopback(machine: "b", port: 54013, ttl: 300)
          #expect(fwd.activeLoopbackKeys() == ["a:54012", "b:54013"])
      }
  }
  ```
- [ ] Run `scripts/test.sh -only-testing:DoryTests/HostBridgeForwardTests` — expected FAIL: `value of type 'HostPortForwarder' has no member 'forwardLoopback'`.
- [ ] In `Dory/Net/HostPortForwarder.swift`, add loopback state after the `private var listeners: [Int: Listener] = [:]` declaration (line 18):
  ```swift
      private var loopbackListeners: [String: Listener] = [:]
      private var loopbackTimers: [String: DispatchSourceTimer] = [:]
  ```
- [ ] In `Dory/Net/HostPortForwarder.swift`, add these methods immediately after `stopAll()` (after line 53):
  ```swift
      func forwardLoopback(machine: String, port: Int, ttl: Int) -> Bool {
          let key = "\(machine):\(port)"
          lock.lock()
          if loopbackListeners[key] != nil { lock.unlock(); return true }
          lock.unlock()
          guard let fd = Self.listenLoopback(port: port) else { return false }
          let engine = engineName
          let binary = containerBinary
          let listener = Listener(listenFD: fd) { client in
              Self.execBridgeInto(client: client, port: port, containerName: engine, binary: binary)
          }
          lock.lock()
          loopbackListeners[key] = listener
          let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
          timer.schedule(deadline: .now() + .seconds(ttl))
          timer.setEventHandler { [weak self] in self?.teardownLoopback(machine: machine, port: port) }
          loopbackTimers[key] = timer
          timer.resume()
          lock.unlock()
          listener.run()
          return true
      }

      func teardownLoopback(machine: String, port: Int) {
          let key = "\(machine):\(port)"
          lock.lock()
          let listener = loopbackListeners.removeValue(forKey: key)
          let timer = loopbackTimers.removeValue(forKey: key)
          lock.unlock()
          timer?.cancel()
          listener?.stop()
      }

      func activeLoopbackKeys() -> Set<String> {
          lock.lock(); defer { lock.unlock() }
          return Set(loopbackListeners.keys)
      }
  ```
- [ ] In `Dory/Net/HostPortForwarder.swift`, add this static helper immediately after the existing `execBridge(client:port:)` method (after line 109), reusing the exec-nc mechanism against a specific container name:
  ```swift
      nonisolated static func execBridgeInto(client: Int32, port: Int, containerName: String, binary: String?) {
          guard let binary, !containerName.isEmpty else { shutdown(client, SHUT_RDWR); Darwin.close(client); return }
          let process = Process()
          process.executableURL = URL(fileURLWithPath: binary)
          process.arguments = ["exec", "-i", containerName, "nc", "127.0.0.1", String(port)]
          let stdin = Pipe(), stdout = Pipe()
          process.standardInput = stdin
          process.standardOutput = stdout
          process.standardError = Pipe()
          guard (try? process.run()) != nil else { shutdown(client, SHUT_RDWR); Darwin.close(client); return }
          let inFD = stdin.fileHandleForWriting.fileDescriptor
          let outFD = stdout.fileHandleForReading.fileDescriptor
          let group = DispatchGroup()
          group.enter()
          Thread.detachNewThread {
              pump(from: client, to: inFD)
              try? stdin.fileHandleForWriting.close()
              group.leave()
          }
          pump(from: outFD, to: client)
          group.wait()
          if process.isRunning { process.terminate() }
          shutdown(client, SHUT_RDWR); Darwin.close(client)
      }
  ```
- [ ] In `Dory/Net/HostPortForwarder.swift` `stopAll()` (line 50-53), also tear down loopback state by replacing its body with:
  ```swift
      func stopAll() {
          lock.lock(); let ports = Array(listeners.keys); let loopKeys = Array(loopbackListeners.keys); lock.unlock()
          for port in ports { stop(port: port) }
          for key in loopKeys {
              let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
              if parts.count == 2, let port = Int(parts[1]) { teardownLoopback(machine: parts[0], port: port) }
          }
      }
  ```
- [ ] Run `scripts/test.sh -only-testing:DoryTests/HostBridgeForwardTests` — expected PASS (3 tests).
- [ ] Commit: `git add Dory/Net/HostPortForwarder.swift DoryTests/HostBridgeForwardTests.swift && git commit -m "feat(bridge): on-demand loopback forward + TTL teardown"`

---

### Task 7: HostBridge per-machine watcher lifecycle

**Files:**
- Modify `Dory/Net/HostBridge.swift` (convert `enum HostBridge` static helpers to remain; add a `final class HostBridgeWatcher`)
- Modify `DoryTests/HostBridgeTests.swift`

**Interfaces:**
- Consumes: `HostBridge.consume`, `HostBridge.decodeOpen`, `HostBridge.decodeForward`, `HostBridge.allowedURL`, `HostBridge.allowedForwardPort`, `HostBridge.resolvedTTL`, `HostPortForwarder.forwardLoopback/teardownLoopback`, `MachineService.containerName(for:)`
- Produces:
  - `final class HostBridgeWatcher: @unchecked Sendable`
  - `init(bridgeRoot: URL, forwarder: HostPortForwarder, open: @escaping @Sendable (URL) -> Void)`
  - `func startWatching(machine: String)`
  - `func stopWatching(machine: String)`
  - `func watchedMachines() -> Set<String>`
  - `func scanOnce(machine: String)` (deterministic drain used by tests + the DispatchSource handler)

Behavior: `startWatching` creates `<bridgeRoot>/<machine>/{open,forward}`, opens a `DispatchSource(.vnode, .write)` on each dir, and on each event (and once immediately) calls `scanOnce`. `scanOnce` drains `forward/` first (write-forward-before-open ordering), then `open/`: for each file, `consume` → decode → validate → act (`forwarder.forwardLoopback(machine:port:ttl:)` / `open(url)`). The `open` closure is injected so tests can record instead of launching a browser. Directory-name / machine string is never passed to a shell.

Steps:

- [ ] Add these test methods inside `struct HostBridgeTests` (after `consumeSkipsTmpFiles`):
  ```swift
      @Test func watcherOpensValidURLAndDeletesRequest() throws {
          let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
          defer { try? FileManager.default.removeItem(at: root) }
          let recorded = OpenRecorder()
          let fwd = HostPortForwarder(targetHost: "127.0.0.1", containerBinary: nil, engineName: "")
          let watcher = HostBridgeWatcher(bridgeRoot: root, forwarder: fwd) { url in recorded.append(url) }
          watcher.startWatching(machine: "dev")
          defer { watcher.stopWatching(machine: "dev"); fwd.stopAll() }
          let openDir = root.appendingPathComponent("dev/open")
          let file = openDir.appendingPathComponent("\(UUID().uuidString).json")
          try Data(#"{"url":"https://example.com/cb?code=1","cwd":null,"ts":1}"#.utf8).write(to: file)
          watcher.scanOnce(machine: "dev")
          #expect(recorded.urls.map(\.absoluteString) == ["https://example.com/cb?code=1"])
          #expect(!FileManager.default.fileExists(atPath: file.path))
      }

      @Test func watcherRejectsFileSchemeButStillDeletes() throws {
          let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
          defer { try? FileManager.default.removeItem(at: root) }
          let recorded = OpenRecorder()
          let fwd = HostPortForwarder(targetHost: "127.0.0.1", containerBinary: nil, engineName: "")
          let watcher = HostBridgeWatcher(bridgeRoot: root, forwarder: fwd) { url in recorded.append(url) }
          watcher.startWatching(machine: "dev")
          defer { watcher.stopWatching(machine: "dev"); fwd.stopAll() }
          let file = root.appendingPathComponent("dev/open/\(UUID().uuidString).json")
          try Data(#"{"url":"file:///etc/passwd","cwd":null,"ts":1}"#.utf8).write(to: file)
          watcher.scanOnce(machine: "dev")
          #expect(recorded.urls.isEmpty)
          #expect(!FileManager.default.fileExists(atPath: file.path))
      }

      @Test func watcherWiresForwardForValidPort() throws {
          let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
          defer { try? FileManager.default.removeItem(at: root) }
          let fwd = HostPortForwarder(targetHost: "127.0.0.1", containerBinary: nil, engineName: "")
          let watcher = HostBridgeWatcher(bridgeRoot: root, forwarder: fwd) { _ in }
          watcher.startWatching(machine: "dev")
          defer { watcher.stopWatching(machine: "dev"); fwd.stopAll() }
          let file = root.appendingPathComponent("dev/forward/54020.json")
          try Data(#"{"port":54020,"ts":1,"ttlSec":300}"#.utf8).write(to: file)
          watcher.scanOnce(machine: "dev")
          #expect(fwd.activeLoopbackKeys() == ["dev:54020"])
          #expect(!FileManager.default.fileExists(atPath: file.path))
      }

      @Test func startAndStopTracksWatchedMachines() {
          let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
          defer { try? FileManager.default.removeItem(at: root) }
          let fwd = HostPortForwarder(targetHost: "127.0.0.1", containerBinary: nil, engineName: "")
          let watcher = HostBridgeWatcher(bridgeRoot: root, forwarder: fwd) { _ in }
          watcher.startWatching(machine: "dev")
          #expect(watcher.watchedMachines() == ["dev"])
          watcher.stopWatching(machine: "dev")
          #expect(watcher.watchedMachines().isEmpty)
          fwd.stopAll()
      }

      final class OpenRecorder: @unchecked Sendable {
          private let lock = NSLock()
          private var storage: [URL] = []
          var urls: [URL] { lock.lock(); defer { lock.unlock() }; return storage }
          func append(_ url: URL) { lock.lock(); storage.append(url); lock.unlock() }
      }
  ```
- [ ] Run `scripts/test.sh -only-testing:DoryTests/HostBridgeTests` — expected FAIL: `cannot find 'HostBridgeWatcher' in scope`.
- [ ] Append this class to `Dory/Net/HostBridge.swift` (after the `enum HostBridge { … }` block):
  ```swift
  final class HostBridgeWatcher: @unchecked Sendable {
      private let bridgeRoot: URL
      private let forwarder: HostPortForwarder
      private let open: @Sendable (URL) -> Void
      private let lock = NSLock()
      private var sources: [String: [DispatchSourceFileSystemObject]] = [:]

      init(bridgeRoot: URL, forwarder: HostPortForwarder, open: @escaping @Sendable (URL) -> Void) {
          self.bridgeRoot = bridgeRoot
          self.forwarder = forwarder
          self.open = open
      }

      func startWatching(machine: String) {
          lock.lock()
          let already = sources[machine] != nil
          lock.unlock()
          guard !already else { return }
          let openDir = bridgeRoot.appendingPathComponent(machine).appendingPathComponent("open")
          let forwardDir = bridgeRoot.appendingPathComponent(machine).appendingPathComponent("forward")
          for dir in [openDir, forwardDir] {
              try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
          }
          var made: [DispatchSourceFileSystemObject] = []
          for dir in [openDir, forwardDir] {
              let fd = Darwin.open(dir.path, O_EVTONLY)
              guard fd >= 0 else { continue }
              let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: DispatchQueue.global())
              source.setEventHandler { [weak self] in self?.scanOnce(machine: machine) }
              source.setCancelHandler { Darwin.close(fd) }
              source.resume()
              made.append(source)
          }
          lock.lock(); sources[machine] = made; lock.unlock()
          scanOnce(machine: machine)
      }

      func stopWatching(machine: String) {
          lock.lock()
          let made = sources.removeValue(forKey: machine)
          lock.unlock()
          made?.forEach { $0.cancel() }
      }

      func watchedMachines() -> Set<String> {
          lock.lock(); defer { lock.unlock() }
          return Set(sources.keys)
      }

      func scanOnce(machine: String) {
          let base = bridgeRoot.appendingPathComponent(machine)
          drainForward(base.appendingPathComponent("forward"), machine: machine)
          drainOpen(base.appendingPathComponent("open"))
      }

      private func drainForward(_ dir: URL, machine: String) {
          for file in files(in: dir) {
              guard let data = HostBridge.consume(at: file),
                    let req = HostBridge.decodeForward(data),
                    HostBridge.allowedForwardPort(req.port) else { continue }
              _ = forwarder.forwardLoopback(machine: machine, port: req.port, ttl: HostBridge.resolvedTTL(req.ttlSec))
          }
      }

      private func drainOpen(_ dir: URL) {
          for file in files(in: dir) {
              guard let data = HostBridge.consume(at: file),
                    let req = HostBridge.decodeOpen(data),
                    let url = HostBridge.allowedURL(req.url) else { continue }
              open(url)
          }
      }

      private func files(in dir: URL) -> [URL] {
          let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
          return items.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
      }
  }
  ```
- [ ] Add `#if canImport(Darwin)` import at the top of `Dory/Net/HostBridge.swift` (below `import Foundation`):
  ```swift
  #if canImport(Darwin)
  import Darwin
  #endif
  ```
- [ ] Run `scripts/test.sh -only-testing:DoryTests/HostBridgeTests` — expected PASS (12 tests).
- [ ] Commit: `git add Dory/Net/HostBridge.swift DoryTests/HostBridgeTests.swift && git commit -m "feat(bridge): per-machine DispatchSource watcher + scan"`

---

### Task 8: MachineService bridge bind + BROWSER env

**Files:**
- Modify `Dory/Runtime/Machines/MachineService.swift` (`createBody` at lines 61-91; add `bridgeHostDir` near `containerName` at line 31)
- Modify `DoryTests/HostBridgeTests.swift`

**Interfaces:**
- Consumes: `MachineSettings`
- Produces:
  - `static func bridgeHostDir(for name: String) -> String` (returns `~/.dory/bridge/<name>`, absolute)
  - `createBody` now injects bind `"<bridgeHostDir>:/opt/dory/bridge"` into `HostConfig.Binds` and `"BROWSER=dory-open"` into `Env`

Steps:

- [ ] Add these test methods inside `struct HostBridgeTests` (after `startAndStopTracksWatchedMachines`):
  ```swift
      @Test func createBodyBindsBridgeDir() {
          let body = MachineService.createBody(name: "dev", distro: MachineDistro.forFamily("ubuntu")!, arch: .arm64, imageTag: "img", keepaliveOnly: true)
          let host = body["HostConfig"] as! [String: Any]
          let binds = host["Binds"] as! [String]
          #expect(binds.contains("\(MachineService.bridgeHostDir(for: "dev")):/opt/dory/bridge"))
      }

      @Test func createBodySetsBrowserEnv() {
          let body = MachineService.createBody(name: "dev", distro: MachineDistro.forFamily("ubuntu")!, arch: .arm64, imageTag: "img", keepaliveOnly: true)
          let env = body["Env"] as! [String]
          #expect(env.contains("BROWSER=dory-open"))
      }

      @Test func bridgeHostDirIsUnderDoryBridge() {
          #expect(MachineService.bridgeHostDir(for: "dev").hasSuffix("/.dory/bridge/dev"))
      }
  ```
  `MachineDistro` is a struct with `static func forFamily(_ family: String) -> MachineDistro?` and `MachineArch` is an enum with `case arm64` — both verified against `Dory/Runtime/Machines/MachineDistro.swift` / `Dory/Runtime/Machines/MachineArch.swift`; use `MachineDistro.forFamily("ubuntu")!` and `.arm64` exactly as written above.
- [ ] Run `scripts/test.sh -only-testing:DoryTests/HostBridgeTests` — expected FAIL: `type 'MachineService' has no member 'bridgeHostDir'`.
- [ ] In `Dory/Runtime/Machines/MachineService.swift`, add this method directly after `containerName(for:)` (line 31):
  ```swift
      static func bridgeHostDir(for name: String) -> String {
          URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".dory/bridge").appendingPathComponent(name).path
      }
  ```
- [ ] In `Dory/Runtime/Machines/MachineService.swift` `createBody`, after `var hostConfig = self.hostConfig(base: baseHostConfig, settings: settings)` (line 78) and before `hostConfig.removeValue(forKey: "ExposedPorts")` (line 79), insert:
  ```swift
          var binds = (hostConfig["Binds"] as? [String]) ?? []
          binds.append("\(bridgeHostDir(for: name)):/opt/dory/bridge")
          hostConfig["Binds"] = binds
  ```
- [ ] In `Dory/Runtime/Machines/MachineService.swift` `createBody`, change the `"Env"` value (line 84) from
  ```swift
          "Env": (["container=docker"] + settings.env.map { "\($0.key)=\($0.value)" }).sorted(),
  ```
  to
  ```swift
          "Env": (["container=docker", "BROWSER=dory-open"] + settings.env.map { "\($0.key)=\($0.value)" }).sorted(),
  ```
- [ ] Run `scripts/test.sh -only-testing:DoryTests/HostBridgeTests` — expected PASS (15 tests).
- [ ] Commit: `git add Dory/Runtime/Machines/MachineService.swift DoryTests/HostBridgeTests.swift && git commit -m "feat(bridge): mount /opt/dory/bridge + BROWSER=dory-open"`

---

### Task 9: DoryOpenShim script + install commands (Swift side)

**Files:**
- Create `Dory/Runtime/Machines/DoryOpenShim.swift`
- Create `DoryTests/DoryOpenShimTests.swift`

**Interfaces:**
- Consumes: (none)
- Produces:
  - `enum DoryOpenShim { static let script: String }`
  - `enum DoryOpenShim { static let path = "/usr/local/bin/dory-open" }`
  - `enum DoryOpenShim { static let bridgeGuestDir = "/opt/dory/bridge" }`
  - `enum DoryOpenShim { static func installCommands() -> [String] }`

The `script` is the POSIX-sh `dory-open` (defined literally in Task 10's fixture and reused byte-for-byte here). It drops a leading `open` argument (`[ "$1" = "open" ] && shift`) so `gio open <url>` works when `gio` is symlinked to the shim. `installCommands()` returns shell lines that: `install -d /usr/local/bin`; write `script` to `path` via a heredoc; `chmod +x`; symlink `xdg-open`, `sensible-browser`, `www-browser` → `dory-open`; best-effort symlink `gio` → `dory-open` (only when a real `gio` is absent: `command -v gio >/dev/null 2>&1 || ln -sf …`); ensure `socat` (best-effort). No guest-provided strings are interpolated.

Steps:

- [ ] Create `DoryTests/DoryOpenShimTests.swift` with this exact content:
  ```swift
  import Testing
  @testable import Dory

  struct DoryOpenShimTests {
      @Test func scriptTargetsBridgeDirAndForwardFirst() {
          let s = DoryOpenShim.script
          #expect(s.contains("/opt/dory/bridge"))
          #expect(s.contains("forward/"))
          #expect(s.contains("open/"))
          let forwardIdx = s.range(of: "forward/")!.lowerBound
          let openIdx = s.range(of: "\"$BRIDGE/open")!.lowerBound
          #expect(forwardIdx < openIdx)
      }

      @Test func scriptScansProcNetTcp() {
          let s = DoryOpenShim.script
          #expect(s.contains("/proc/net/tcp"))
          #expect(s.contains("/proc/net/tcp6"))
          #expect(s.contains("0100007F"))
      }

      @Test func scriptWritesAtomicallyViaRename() {
          let s = DoryOpenShim.script
          #expect(s.contains(".tmp"))
          #expect(s.contains("mv "))
      }

      @Test func installCommandsSymlinkBrowsers() {
          let cmds = DoryOpenShim.installCommands().joined(separator: "\n")
          #expect(cmds.contains("/usr/local/bin/dory-open"))
          #expect(cmds.contains("chmod +x /usr/local/bin/dory-open"))
          #expect(cmds.contains("ln -sf /usr/local/bin/dory-open"))
          #expect(cmds.contains("xdg-open"))
          #expect(cmds.contains("sensible-browser"))
          #expect(cmds.contains("www-browser"))
          #expect(cmds.contains("/usr/local/bin/gio"))
      }

      @Test func scriptDropsLeadingOpenArg() {
          #expect(DoryOpenShim.script.contains(#"[ "$1" = "open" ] && shift"#))
      }

      @Test func installEnsuresSocat() {
          let cmds = DoryOpenShim.installCommands().joined(separator: "\n")
          #expect(cmds.contains("socat"))
      }
  }
  ```
- [ ] Run `scripts/test.sh -only-testing:DoryTests/DoryOpenShimTests` — expected FAIL: `cannot find 'DoryOpenShim' in scope`.
- [ ] Create `Dory/Runtime/Machines/DoryOpenShim.swift` with this exact content:
  ```swift
  import Foundation

  enum DoryOpenShim {
      static let path = "/usr/local/bin/dory-open"
      static let bridgeGuestDir = "/opt/dory/bridge"

      static let script = ##"""
  #!/bin/sh
  BRIDGE="/opt/dory/bridge"
  [ "$1" = "open" ] && shift
  URL="$1"
  [ -n "$URL" ] || exit 0
  mkdir -p "$BRIDGE/forward/" "$BRIDGE/open/" 2>/dev/null || true
  TS=$(date +%s 2>/dev/null || echo 0)

  emit_forward() {
    p="$1"
    [ -n "$p" ] || return 0
    [ "$p" -ge 1024 ] 2>/dev/null || return 0
    [ "$p" -le 65535 ] 2>/dev/null || return 0
    f="$BRIDGE/forward/$p.json"
    t="$f.tmp.$$"
    printf '{"port":%s,"ts":%s,"ttlSec":300}\n' "$p" "$TS" > "$t" && mv "$t" "$f"
  }

  DECODED=$(printf '%s' "$URL" | sed 's/%3[Aa]/:/g; s/%2[Ff]/\//g')
  URLPORT=$(printf '%s' "$DECODED" | grep -Eo '127\.0\.0\.1:[0-9]+|localhost:[0-9]+' | head -n1 | sed 's/.*://')
  [ -n "$URLPORT" ] && emit_forward "$URLPORT"

  for tcp in /proc/net/tcp /proc/net/tcp6; do
    [ -r "$tcp" ] || continue
    awk 'NR>1 && $4=="0A" {print $2}' "$tcp" | while read -r local; do
      addr=$(printf '%s' "$local" | cut -d: -f1)
      hexp=$(printf '%s' "$local" | cut -d: -f2)
      case "$addr" in
        0100007F|00000000000000000000000001000000|00000000000000000000000000000000) ;;
        *) continue ;;
      esac
      dp=$(printf '%d' "0x$hexp" 2>/dev/null)
      emit_forward "$dp"
    done
  done

  UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "$TS-$$")
  of="$BRIDGE/open/$UUID.json"
  ot="$of.tmp.$$"
  ESC=$(printf '%s' "$URL" | sed 's/\\/\\\\/g; s/"/\\"/g')
  printf '{"url":"%s","cwd":"%s","ts":%s}\n' "$ESC" "$PWD" "$TS" > "$ot" && mv "$ot" "$of"
  printf 'Opening %s on your Mac…\n' "$URL"
  exit 0
  """##

      static func installCommands() -> [String] {
          [
              "install -d /usr/local/bin",
              "cat > /usr/local/bin/dory-open <<'DORYOPENEOF'\n\(script)\nDORYOPENEOF",
              "chmod +x /usr/local/bin/dory-open",
              "ln -sf /usr/local/bin/dory-open /usr/local/bin/xdg-open",
              "ln -sf /usr/local/bin/dory-open /usr/local/bin/sensible-browser",
              "ln -sf /usr/local/bin/dory-open /usr/local/bin/www-browser",
              "command -v gio >/dev/null 2>&1 || ln -sf /usr/local/bin/dory-open /usr/local/bin/gio",
              "command -v socat >/dev/null 2>&1 || (apt-get install -y socat 2>/dev/null || dnf install -y socat 2>/dev/null || apk add socat 2>/dev/null || zypper -n install socat 2>/dev/null || pacman -Sy --noconfirm socat 2>/dev/null || true)",
          ]
      }
  }
  ```
- [ ] Run `scripts/test.sh -only-testing:DoryTests/DoryOpenShimTests` — expected PASS (8 tests).
- [ ] Commit: `git add Dory/Runtime/Machines/DoryOpenShim.swift DoryTests/DoryOpenShimTests.swift && git commit -m "feat(bridge): dory-open shim script + install commands"`

---

### Task 10: Shim behavior — bash test with fixtures

**Files:**
- Create `scripts/test-dory-open.sh`

**Interfaces:**
- Consumes: `Dory/Runtime/Machines/DoryOpenShim.swift` (extracts `script` byte-for-byte via awk between the `##"""` and `"""##` delimiters), fixture `/proc/net/tcp` and `/proc/net/tcp6` files
- Produces: shell contract asserted — (a) a URL whose `redirect_uri` carries a percent-encoded loopback host:port (`127.0.0.1%3A<port>`) is URL-decoded and yields `forward/<port>.json`; (b) fixture `/proc/net/tcp` and `/proc/net/tcp6` LISTEN (state `0A`) loopback sockets have their hex ports converted to decimal and emitted, while ESTABLISHED sockets are skipped; `open/<uuid>.json` is written last and atomically (no `.tmp` residue).

The awk extraction is FINAL and correct: `awk '/static let script = ##"""/{f=1;next} f && $0 ~ /^[[:space:]]*"""##[[:space:]]*$/{f=0;next} f'` starts capturing on the line AFTER `static let script = ##"""` and stops at the closing line whose only content is `"""##` (tolerant of any leading/trailing whitespace, so it works regardless of the Swift file's indentation), so `$WORK/dory-open` is the shim body. The BRIDGE-rewrite `sed` anchor is likewise whitespace-tolerant (`^[[:space:]]*BRIDGE=`). There is NO first-run failure to iterate away — the fixtures below pass as written.

Port encodings used in the fixtures below (hex in `/proc/net/*` is uppercase; the shim converts via `printf '%d' 0x<hex>`):
- `D2A4` = 53924 (tcp LISTEN, loopback `0100007F`) → forwarded.
- `1F90` = 8080 (tcp ESTABLISHED, state `01`) → skipped.
- `CFE7` = 53223 (tcp6 LISTEN, loopback `00000000000000000000000001000000`) → forwarded.

Steps:

- [ ] Create `scripts/test-dory-open.sh` with this exact content:
  ```bash
  #!/bin/bash
  set -u
  ROOT="$(cd "$(dirname "$0")/.." && pwd)"
  SRC="$ROOT/Dory/Runtime/Machines/DoryOpenShim.swift"
  WORK="$(mktemp -d)"
  trap 'rm -rf "$WORK"' EXIT
  PASS=0; FAIL=0
  ok() { PASS=$((PASS+1)); echo "  [PASS] $1"; }
  no() { FAIL=$((FAIL+1)); echo "  [FAIL] $1"; }

  # Extract the sh script literal between the ##""" and """## delimiters.
  # Start capturing after the opener; stop at a line that is exactly """## (tolerant of any
  # leading/trailing whitespace, so the extraction works regardless of the Swift file's indentation).
  awk '/static let script = ##"""/{f=1;next} f && $0 ~ /^[[:space:]]*"""##[[:space:]]*$/{f=0;next} f' "$SRC" > "$WORK/dory-open"
  chmod +x "$WORK/dory-open"
  [ -s "$WORK/dory-open" ] && ok "extracted shim script" || no "extracted shim script"

  BRIDGE="$WORK/bridge"
  # Redirect the shim's fixed bridge path to our sandbox by editing a temp copy
  # (anchor tolerates any leading whitespace on the BRIDGE= line).
  sed "s#^[[:space:]]*BRIDGE=\"/opt/dory/bridge\"#BRIDGE=\"$BRIDGE\"#" "$WORK/dory-open" > "$WORK/dory-open.local"
  chmod +x "$WORK/dory-open.local"

  # Case 1: plain URL-embedded loopback port -> forward/<port>.json
  ( cd "$WORK" && "$WORK/dory-open.local" "http://127.0.0.1:53219/cb?code=abc" >/dev/null )
  [ -f "$BRIDGE/forward/53219.json" ] && ok "url port -> forward file" || no "url port -> forward file"
  grep -q '"port":53219' "$BRIDGE/forward/53219.json" 2>/dev/null && ok "forward json has port" || no "forward json has port"

  # Case 1b: percent-encoded redirect_uri (127.0.0.1%3A<port>) is URL-decoded then extracted.
  rm -rf "$BRIDGE"
  ( cd "$WORK" && "$WORK/dory-open.local" "https://auth.example.com/authorize?redirect_uri=http%3A%2F%2F127.0.0.1%3A61234%2Fcallback&code=1" >/dev/null )
  [ -f "$BRIDGE/forward/61234.json" ] && ok "encoded redirect_uri -> forward file" || no "encoded redirect_uri -> forward file"

  # Case 2: open request written atomically, no .tmp residue
  ls "$BRIDGE/open/"*.json >/dev/null 2>&1 && ok "open request written" || no "open request written"
  ! ls "$BRIDGE"/open/*.tmp* >/dev/null 2>&1 && ok "no tmp residue (open)" || no "no tmp residue (open)"
  ! ls "$BRIDGE"/forward/*.tmp* >/dev/null 2>&1 && ok "no tmp residue (forward)" || no "no tmp residue (forward)"

  # Case 3: /proc/net/tcp fixture — LISTEN (0A) loopback D2A4=53924 forwarded; ESTABLISHED (01) 1F90 skipped.
  rm -rf "$BRIDGE"
  PROC="$WORK/proc"; mkdir -p "$PROC"
  cat > "$PROC/tcp" <<'EOF'
  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 0100007F:D2A4 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 12345 1 ffff 100 0 0 10 0
   1: 0100007F:1F90 0100007F:C001 01 00000000:00000000 00:00000000 00000000  1000        0 12346 1 ffff 100 0 0 10 0
  EOF
  # Case 3b: /proc/net/tcp6 fixture — LISTEN (0A) loopback CFE7=53223 forwarded.
  cat > "$PROC/tcp6" <<'EOF'
  sl  local_address                         remote_address                        st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 00000000000000000000000001000000:CFE7 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 22345 1 ffff 100 0 0 10 0
  EOF
  # Rewrite the shim to read our fixture proc files instead of /proc (tcp6 first so its substring isn't clobbered).
  sed "s#/proc/net/tcp6#$PROC/tcp6#g; s#/proc/net/tcp#$PROC/tcp#g" "$WORK/dory-open.local" > "$WORK/dory-open.proc"
  chmod +x "$WORK/dory-open.proc"
  ( cd "$WORK" && "$WORK/dory-open.proc" "https://example.com/login" >/dev/null )
  [ -f "$BRIDGE/forward/53924.json" ] && ok "tcp LISTEN loopback -> forward file" || no "tcp LISTEN loopback -> forward file"
  [ -f "$BRIDGE/forward/53223.json" ] && ok "tcp6 LISTEN loopback -> forward file" || no "tcp6 LISTEN loopback -> forward file"
  # ESTABLISHED (st=01) socket on port 0x1F90 (8080) must NOT be forwarded.
  [ ! -f "$BRIDGE/forward/8080.json" ] && ok "established socket skipped" || no "established socket skipped"

  # Case 4: non-http scheme still writes an open request (host rejects; shim is dumb).
  rm -rf "$BRIDGE"
  ( cd "$WORK" && "$WORK/dory-open.local" "vscode://x" >/dev/null )
  ls "$BRIDGE/open/"*.json >/dev/null 2>&1 && ok "custom scheme still queued (host validates)" || no "custom scheme still queued (host validates)"

  # Case 5: leading "open" arg (gio open <url>) is dropped, URL still parsed.
  rm -rf "$BRIDGE"
  ( cd "$WORK" && "$WORK/dory-open.local" open "http://127.0.0.1:52001/cb" >/dev/null )
  [ -f "$BRIDGE/forward/52001.json" ] && ok "leading open arg dropped" || no "leading open arg dropped"

  echo "dory-open: $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]
  ```
- [ ] `chmod +x scripts/test-dory-open.sh`
- [ ] Run `bash scripts/test-dory-open.sh` — expected on first run (extraction is final/correct): `dory-open: 12 passed, 0 failed`.
- [ ] Commit: `git add scripts/test-dory-open.sh && git commit -m "test(bridge): dory-open shim port-extraction + proc scan fixtures"`

---

### Task 11: MachineProvisioner installs the shim + socat

**Files:**
- Modify `Dory/Runtime/Machines/MachineProvisioner.swift` (`script(identity:pkg:isSystemd:includeSSH:)` at lines 4-29)
- Modify `DoryTests/MachineProvisionerTests.swift`

**Interfaces:**
- Consumes: `DoryOpenShim.installCommands()`
- Produces: `MachineProvisioner.script(...)` output now contains the shim install lines — write `dory-open`, `chmod +x`, symlink `xdg-open`/`sensible-browser`/`www-browser`, best-effort `gio` symlink, ensure `socat` — appended after identity/SSH setup, before `return`.

Steps:

- [ ] Add these test methods inside `struct MachineProvisionerTests` in `DoryTests/MachineProvisionerTests.swift` (after `sanitizesSudoersFilenameSlug`):
  ```swift
      @Test func installsDoryOpenShim() {
          let s = MachineProvisioner.script(identity: id(), pkg: .apt, isSystemd: true, includeSSH: false)
          #expect(s.contains("/usr/local/bin/dory-open"))
          #expect(s.contains("ln -sf /usr/local/bin/dory-open /usr/local/bin/xdg-open"))
          #expect(s.contains("/usr/local/bin/gio"))
      }

      @Test func ensuresSocatInstalled() {
          let s = MachineProvisioner.script(identity: id(), pkg: .apt, isSystemd: true, includeSSH: false)
          #expect(s.contains("socat"))
      }
  ```
- [ ] Run `scripts/test.sh -only-testing:DoryTests/MachineProvisionerTests` — expected FAIL: three `#expect` assertions fail (shim strings absent).
- [ ] In `Dory/Runtime/Machines/MachineProvisioner.swift`, in `script(...)`, insert immediately before `return lines.joined(separator: "\n")` (line 28) — this appends `DoryOpenShim.installCommands()`, which includes the `xdg-open`/`sensible-browser`/`www-browser` and best-effort `gio` symlinks alongside the shim:
  ```swift
          lines.append(contentsOf: DoryOpenShim.installCommands())
  ```
- [ ] Run `scripts/test.sh -only-testing:DoryTests/MachineProvisionerTests` — expected PASS (all prior + 2 new).
- [ ] Commit: `git add Dory/Runtime/Machines/MachineProvisioner.swift DoryTests/MachineProvisionerTests.swift && git commit -m "feat(bridge): provision dory-open shim + socat in machines"`

---

### Task 12: AppStore owns HostBridge + registers machines

**Files:**
- Modify `Dory/Models/AppStore.swift` (add `hostBridge` near `portForwarder` line 379; start watchers for running machines in `startLocalNetworking` line 421; tear down in `stopLocalNetworking` line 460; register in `toggleMachine` line 1636, `createMachine` at line 1719, `deleteMachine` line 1943). AppKit and SwiftUI are already imported at the top of the file (lines 1-2) — no import edits.

**Interfaces:**
- Consumes: `HostBridgeWatcher`, `HostPortForwarder` (existing `portForwarder`), `MachineService.bridgeHostDir`
- Produces:
  - `AppStore.registerMachineBridge(_ name: String)`
  - `AppStore.unregisterMachineBridge(_ name: String)`
  - The `hostBridge` watcher is started in `startLocalNetworking()` (for already-running machines) and torn down in `stopLocalNetworking()`; per-machine register/unregister covers start/stop/create/delete.

Note: this task has no unit test (it wires UI-side lifecycle into `@MainActor` `AppStore`); it is verified by build + the Task 14 `--bridge` integration test. Keep the diff minimal.

Steps:

- [ ] In `Dory/Models/AppStore.swift`, after the `portForwarder` property (line 379), add:
  ```swift
      @ObservationIgnored private lazy var hostBridge = HostBridgeWatcher(
          bridgeRoot: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".dory/bridge"),
          forwarder: portForwarder,
          open: { url in DispatchQueue.main.async { NSWorkspace.shared.open(url) } }
      )
  ```
- [ ] In `Dory/Models/AppStore.swift`, add these two methods immediately after `stopLocalNetworking()` (after line 466):
  ```swift
      func registerMachineBridge(_ name: String) {
          try? FileManager.default.createDirectory(atPath: MachineService.bridgeHostDir(for: name), withIntermediateDirectories: true)
          hostBridge.startWatching(machine: name)
      }

      func unregisterMachineBridge(_ name: String) {
          hostBridge.stopWatching(machine: name)
      }
  ```
- [ ] In `Dory/Models/AppStore.swift` `startLocalNetworking()` (lines 421-430), start the HostBridge watcher for every already-running machine by inserting immediately after `networkingStarted = true` (line 427):
  ```swift
          for machine in machines where machine.status == .running { registerMachineBridge(machine.name) }
  ```
  (`hostBridge` is `lazy`, so its first access here creates the `HostBridgeWatcher`; `startWatching` is idempotent per machine, so re-entry is safe.)
- [ ] In `Dory/Models/AppStore.swift` `stopLocalNetworking()` (line 460-466), add bridge teardown by inserting before `networkingStarted = false` (line 465):
  ```swift
          for machine in hostBridge.watchedMachines() { hostBridge.stopWatching(machine: machine) }
  ```
- [ ] In `Dory/Models/AppStore.swift` `toggleMachine` (lines 1642-1650), inside the `Task { … }` after the `if wasRunning { … } else { … }` branch (line 1645), add registration:
  ```swift
                  if wasRunning { unregisterMachineBridge(name) } else { registerMachineBridge(name) }
  ```
- [ ] In `Dory/Models/AppStore.swift` `createMachine(...)` (a `@MainActor async` method — `AppStore` is `@MainActor`), the `try await machineService.create(...)` await runs on the main actor, so call `registerMachineBridge` directly (no actor hop). Insert immediately after the `appendMachineCreationLog("Machine created and started.")` line (line 1719):
  ```swift
              registerMachineBridge(trimmedName)
  ```
- [ ] In `Dory/Models/AppStore.swift` `deleteMachine` (lines 1943-1948), before the `Task { try? await service.delete(...) }` line, add:
  ```swift
          unregisterMachineBridge(name)
  ```
- [ ] Run `scripts/build.sh` — expected: build succeeds, no errors.
- [ ] Commit: `git add Dory/Models/AppStore.swift && git commit -m "feat(bridge): AppStore owns HostBridge + per-machine registration"`

---

### Task 13: "Open logins on my Mac" toggle (persisted + gates the bridge)

**Files:**
- Modify `Dory/Net/HostBridge.swift` (add an `isEnabled` gate to `HostBridgeWatcher`)
- Modify `Dory/Models/AppStore.swift` (persisted `openLoginsOnMac` state + setter; pass the gate into `hostBridge`)
- Modify `Dory/Features/Settings/SettingsView.swift` (add the toggle row)
- Create `DoryTests/OpenLoginsOnMacTests.swift`

**Interfaces:**
- Consumes: `HostBridgeWatcher`, `AppStore`
- Produces:
  - `HostBridgeWatcher.init(bridgeRoot:forwarder:isEnabled:open:)` — a `@Sendable () -> Bool` gate consulted in `scanOnce`; when it returns `false`, the watcher drains and deletes request files but performs NEITHER `forwarder.forwardLoopback` NOR `open(url)`.
  - `AppStore.openLoginsOnMac: Bool` (default `true`), `AppStore.setOpenLoginsOnMac(_:)`, `AppStore.openLoginsOnMacKey = "dory.openLoginsOnMac"`.

Steps:

- [ ] Add these test methods inside `struct HostBridgeTests` in `DoryTests/HostBridgeTests.swift` (after `startAndStopTracksWatchedMachines`):
  ```swift
      @Test func watcherSkipsOpenAndForwardWhenDisabled() throws {
          let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
          defer { try? FileManager.default.removeItem(at: root) }
          let recorded = OpenRecorder()
          let fwd = HostPortForwarder(targetHost: "127.0.0.1", containerBinary: nil, engineName: "")
          let watcher = HostBridgeWatcher(bridgeRoot: root, forwarder: fwd, isEnabled: { false }) { url in recorded.append(url) }
          watcher.startWatching(machine: "dev")
          defer { watcher.stopWatching(machine: "dev"); fwd.stopAll() }
          let openFile = root.appendingPathComponent("dev/open/\(UUID().uuidString).json")
          try Data(#"{"url":"https://example.com/cb","cwd":null,"ts":1}"#.utf8).write(to: openFile)
          let fwdFile = root.appendingPathComponent("dev/forward/54030.json")
          try Data(#"{"port":54030,"ts":1,"ttlSec":300}"#.utf8).write(to: fwdFile)
          watcher.scanOnce(machine: "dev")
          #expect(recorded.urls.isEmpty)
          #expect(fwd.activeLoopbackKeys().isEmpty)
          #expect(!FileManager.default.fileExists(atPath: openFile.path))
          #expect(!FileManager.default.fileExists(atPath: fwdFile.path))
      }
  ```
- [ ] In the existing `HostBridgeTests` watcher constructions (`watcherOpensValidURLAndDeletesRequest`, `watcherRejectsFileSchemeButStillDeletes`, `watcherWiresForwardForValidPort`, `startAndStopTracksWatchedMachines`) add the enabled gate argument so they still compile: change each `HostBridgeWatcher(bridgeRoot: root, forwarder: fwd) { … }` to `HostBridgeWatcher(bridgeRoot: root, forwarder: fwd, isEnabled: { true }) { … }`.
- [ ] Create `DoryTests/OpenLoginsOnMacTests.swift` with this exact content:
  ```swift
  import Testing
  @testable import Dory

  @MainActor
  struct OpenLoginsOnMacTests {
      @Test func defaultsToTrue() {
          let store = AppStore()
          #expect(store.openLoginsOnMac == true)
      }

      @Test func setterTogglesState() {
          let store = AppStore()
          store.setOpenLoginsOnMac(false)
          #expect(store.openLoginsOnMac == false)
          store.setOpenLoginsOnMac(true)
          #expect(store.openLoginsOnMac == true)
      }
  }
  ```
- [ ] Run `scripts/test.sh -only-testing:DoryTests/HostBridgeTests -only-testing:DoryTests/OpenLoginsOnMacTests` — expected FAIL: `HostBridgeWatcher` has no `isEnabled` parameter and `AppStore` has no member `openLoginsOnMac`.
- [ ] In `Dory/Net/HostBridge.swift`, add the gate to `HostBridgeWatcher`. Add the stored property after `private let open: @Sendable (URL) -> Void`:
  ```swift
      private let isEnabled: @Sendable () -> Bool
  ```
  Replace the initializer signature/body:
  ```swift
      init(bridgeRoot: URL, forwarder: HostPortForwarder, isEnabled: @escaping @Sendable () -> Bool = { true }, open: @escaping @Sendable (URL) -> Void) {
          self.bridgeRoot = bridgeRoot
          self.forwarder = forwarder
          self.isEnabled = isEnabled
          self.open = open
      }
  ```
  Add an early gate at the top of `scanOnce(machine:)`, after the `let base = …` line — drain-and-delete without acting when disabled:
  ```swift
      func scanOnce(machine: String) {
          let base = bridgeRoot.appendingPathComponent(machine)
          guard isEnabled() else {
              for dir in ["forward", "open"] {
                  for file in files(in: base.appendingPathComponent(dir)) { _ = HostBridge.consume(at: file) }
              }
              return
          }
          drainForward(base.appendingPathComponent("forward"), machine: machine)
          drainOpen(base.appendingPathComponent("open"))
      }
  ```
- [ ] In `Dory/Models/AppStore.swift`, add the state property immediately after the `var routeDockerCLI = true` line (line 52):
  ```swift
      var openLoginsOnMac = true
  ```
- [ ] In `Dory/Models/AppStore.swift`, add the persistence key immediately after the `static let routeDockerKey = "dory.routeDockerCLI"` line (line 156):
  ```swift
      static let openLoginsOnMacKey = "dory.openLoginsOnMac"
  ```
- [ ] In `Dory/Models/AppStore.swift`, add the load line inside the `init`/`realLaunch` load block immediately after the `if let v = UserDefaults.standard.object(forKey: Self.routeDockerKey) as? Bool { routeDockerCLI = v }` line (line 114):
  ```swift
              if let v = UserDefaults.standard.object(forKey: Self.openLoginsOnMacKey) as? Bool { openLoginsOnMac = v }
  ```
- [ ] In `Dory/Models/AppStore.swift`, add the setter immediately after `setRouteDockerCLI(_:)` (after line ~195):
  ```swift
      func setOpenLoginsOnMac(_ on: Bool) {
          openLoginsOnMac = on
          UserDefaults.standard.set(on, forKey: Self.openLoginsOnMacKey)
      }
  ```
- [ ] In `Dory/Models/AppStore.swift`, wire the gate + open guard into the `hostBridge` construction (from Task 12). Replace the `hostBridge` lazy property with:
  ```swift
      @ObservationIgnored private lazy var hostBridge = HostBridgeWatcher(
          bridgeRoot: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".dory/bridge"),
          forwarder: portForwarder,
          isEnabled: { [weak self] in self?.openLoginsOnMac ?? true },
          open: { url in DispatchQueue.main.async { NSWorkspace.shared.open(url) } }
      )
  ```
- [ ] In `Dory/Features/Settings/SettingsView.swift`, add a "BROWSER LOGINS" group into the `general` view immediately after the `.padding(.bottom, 22)` that closes the STARTUP card (after line 202), before `dockerHostCallout` (line 204):
  ```swift
              groupLabel("BROWSER LOGINS")
              VStack(spacing: 0) {
                  toggleRow("Open logins on my Mac", "Let CLIs inside a machine open the login page in your Mac browser and complete the localhost callback.", isOn: Binding(get: { store.openLoginsOnMac }, set: { store.setOpenLoginsOnMac($0) }), divider: false)
              }
              .background(p.bgElevated, in: RoundedRectangle(cornerRadius: 11))
              .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(p.border))
              .padding(.bottom, 22)
  ```
  This uses the `toggleRow` helper whose signature was changed by the menu-bar-background plan (A) to add a `disabled: Bool = false` parameter; the call above omits `disabled`, so it works on both the pre-A and post-A signatures.
- [ ] Run `scripts/test.sh -only-testing:DoryTests/HostBridgeTests -only-testing:DoryTests/OpenLoginsOnMacTests` — expected PASS (all HostBridgeTests including the new gate test + 2 OpenLoginsOnMacTests).
- [ ] Run `scripts/build.sh` — expected: build succeeds, no errors.
- [ ] Commit: `git add Dory/Net/HostBridge.swift Dory/Models/AppStore.swift Dory/Features/Settings/SettingsView.swift DoryTests/HostBridgeTests.swift DoryTests/OpenLoginsOnMacTests.swift && git commit -m "feat(bridge): open-logins-on-my-Mac toggle gates the host bridge"`

---

### Task 14: readiness.sh `--bridge` integration test

**Files:**
- Modify `scripts/readiness.sh` (arg-parse block lines 69-84; the `RUN_*` defaults near line 30; usage near line 63; the per-engine runner near line 530)

**Interfaces:**
- Consumes: `dory-open` shim (installed in the machine), `~/.dory/bridge/<machine>/{open,forward}` (host side)
- Produces: shell contract — after a fake login inside the machine calls `dory-open`, the host `~/.dory/bridge/<machine>/open/*.json` request is observed (opener stubbed by reading the file directly instead of launching), and `forward/<port>.json` is observed and the port is reachable guest-side.

Note: the app's `HostBridge` deletes requests on consume, so the readiness test asserts against the request files directly by scanning `~/.dory/bridge/<machine>` in a tight poll BEFORE the app consumes them, OR (preferred, deterministic) runs with the app not watching that machine so the drop files persist. The test drops the files by invoking `dory-open` inside the machine and asserts they appear on the host; it does not require the GUI app to be running.

Steps:

- [ ] In `scripts/readiness.sh`, add the default near the other `RUN_*` defaults (after line 30, `RUN_MACHINES=...`):
  ```bash
  RUN_BRIDGE="${RUN_BRIDGE:-0}"
  ```
- [ ] In `scripts/readiness.sh` usage text, add a line after `--machines           Run Linux machine CLI checks` (line 63):
  ```
  --bridge             Run guest→host bridge (dory-open) check
  ```
- [ ] In `scripts/readiness.sh` arg-parse `case` (after the `--machines) RUN_MACHINES=1; shift ;;` line, line 79):
  ```bash
      --bridge) RUN_BRIDGE=1; shift ;;
  ```
- [ ] In `scripts/readiness.sh`, add the `test_bridge` function immediately before the per-engine runner block (before line ~484 where `run_case`s begin; place it after `require_socket`, near line 205). Exact content:
  ```bash
  test_bridge() {
    local mname="dory-brdg-$RUN_SLUG"
    local cname="dory-machine-$mname"
    local hbridge="$HOME/.dory/bridge/$mname"
    rm -rf "$hbridge"; mkdir -p "$hbridge/open" "$hbridge/forward"
    docker_e rm -f "$cname" >/dev/null 2>&1 || true
    docker_e run -d --name "$cname" --label "$LABEL_KEY=$RUN_ID" \
      -v "$hbridge:/opt/dory/bridge" -e BROWSER=dory-open \
      "$ALPINE_IMAGE" tail -f /dev/null >/dev/null
    # Install the shim from source into the running machine (whitespace-tolerant extraction).
    awk '/static let script = ##"""/{f=1;next} f && $0 ~ /^[[:space:]]*"""##[[:space:]]*$/{f=0;next} f' \
      "$ROOT/Dory/Runtime/Machines/DoryOpenShim.swift" \
      | docker_e exec -i "$cname" sh -c 'cat > /usr/local/bin/dory-open && chmod +x /usr/local/bin/dory-open'
    # Fake login: start a loopback server on a known port, then call dory-open with that URL.
    docker_e exec "$cname" sh -c 'command -v nc >/dev/null 2>&1 || (apk add --no-cache netcat-openbsd >/dev/null 2>&1 || true)'
    docker_e exec -d "$cname" sh -c '(printf "HTTP/1.0 200 OK\r\n\r\nok" | nc -l -p 53219) >/dev/null 2>&1'
    docker_e exec "$cname" sh -c '/usr/local/bin/dory-open "http://127.0.0.1:53219/cb?code=xyz"' >/dev/null
    # Assert host saw the open + forward requests (opener stubbed = we read the files directly).
    local seen_open=0 seen_forward=0
    for _ in $(seq 1 20); do
      ls "$hbridge/open/"*.json >/dev/null 2>&1 && seen_open=1
      [ -f "$hbridge/forward/53219.json" ] && seen_forward=1
      [ "$seen_open" = 1 ] && [ "$seen_forward" = 1 ] && break
      sleep 0.25
    done
    grep -q 'http://127.0.0.1:53219/cb?code=xyz' "$hbridge/open/"*.json 2>/dev/null || { echo "open request missing"; return 1; }
    [ "$seen_forward" = 1 ] || { echo "forward request missing"; return 1; }
    # Wire host<->guest exactly as HostBridge would, then hit the loopback port.
    ( echo -e "GET /cb HTTP/1.0\r\n\r" | docker_e exec -i "$cname" nc 127.0.0.1 53219 ) | grep -q 'ok' \
      || { echo "guest loopback server unreachable via exec-nc"; return 1; }
    docker_e rm -f "$cname" >/dev/null 2>&1 || true
    rm -rf "$hbridge"
    return 0
  }
  ```
- [ ] In `scripts/readiness.sh`, insert the runner invocation after the closing `fi` of the machines block. The machines block is:
  ```bash
    if [ "$RUN_MACHINES" = "1" ]; then
      run_case "$CURRENT_ENGINE" "Linux machine build + systemd boot + exec" test_machines
    else
      skip_case "$CURRENT_ENGINE" "Linux machine build + systemd boot + exec" "enable with --machines"
    fi
  ```
  Insert the bridge block AFTER that closing `fi` (line 534) — NOT after the `skip_case` line (line 533), which is inside the `else`:
  ```bash
    if [ "$RUN_BRIDGE" = "1" ]; then
      run_case "$CURRENT_ENGINE" "guest→host bridge (dory-open open + forward)" test_bridge
    else
      skip_case "$CURRENT_ENGINE" "guest→host bridge (dory-open open + forward)" "enable with --bridge"
    fi
  ```
- [ ] Run `bash scripts/readiness.sh --engines dory --bridge --skip-memory --skip-amd64` (requires the dory engine running; if the socket is absent the case SKIPs — acceptable) — expected: the bridge case prints `[PASS]` or `[SKIP] … socket not found`, never `[FAIL]` on a running engine.
- [ ] Commit: `git add scripts/readiness.sh && git commit -m "test(bridge): readiness --bridge open+forward end-to-end check"`

---

### Task 15: Full build + full test suite green

**Files:**
- (none — verification only)

**Interfaces:**
- Consumes: everything above
- Produces: (verification)

Steps:

- [ ] Run `scripts/build.sh` — expected: `** BUILD SUCCEEDED **`, zero warnings introduced by bridge files.
- [ ] Run `scripts/test.sh -only-testing:DoryTests/HostBridgeTests -only-testing:DoryTests/HostBridgeForwardTests -only-testing:DoryTests/DoryOpenShimTests -only-testing:DoryTests/MachineProvisionerTests -only-testing:DoryTests/OpenLoginsOnMacTests` — expected: all pass.
- [ ] Run `bash scripts/test-dory-open.sh` — expected: `dory-open: 12 passed, 0 failed`.
- [ ] Run `scripts/test.sh` (full suite) — expected: no regressions; all tests pass.
- [ ] Commit (if any incidental fixes were needed): `git add -A && git commit -m "chore(bridge): full build + test suite green"`
