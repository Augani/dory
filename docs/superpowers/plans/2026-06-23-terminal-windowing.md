# Terminal Windowing Implementation Plan (WS3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Terminals open in real, independent, minimizable macOS windows (not a modal) for both containers and machines, so the user can multitask while shells are open.

**Architecture:** A Codable/Hashable `TerminalSession` drives a `WindowGroup(for: TerminalSession.self)` scene; views open it via `@Environment(\.openWindow)`. The machine modal sheet is removed; the container detail keeps its inline terminal tab plus a "pop out" button.

**Tech Stack:** Swift 6 / SwiftUI / macOS; SwiftTerm (`ContainerTerminalView`); Swift `Testing`.

## Global Constraints

- Build ONLY with `scripts/build.sh`; test ONLY with `scripts/test.sh` (Xcode 27 beta `DEVELOPER_DIR`). Never call `xcodebuild` directly. Minutes per run.
- Synchronized Xcode folders — new `.swift` files under `Dory/`/`DoryTests/` auto-include; do NOT edit `Dory.xcodeproj/project.pbxproj`.
- IGNORE SourceKit/IDE diagnostics — false positives. `scripts/build.sh`/`scripts/test.sh` are authoritative.
- No inline comments; no docstrings. Self-documenting names. Tests use Swift `Testing`.
- Reuse `ContainerTerminalView(socketPath:containerID:user:shell:home:)` (WS4-A6) — do NOT create a new terminal NSView.
- Containers open a root session (`user "root"`, `shell "/bin/sh"`, `home "/root"`); machines use their identity (`username`/`loginShell`, home `/Users/<user>` or `/root`).
- Window id keys: `"container:<id>"` / `"machine:<containerID>"` (stable → reopening focuses the same window).

---

### Task W1: TerminalSession model + factories

**Files:**
- Create: `Dory/Runtime/TerminalSession.swift`
- Modify: `Dory/Models/AppStore.swift` (add `terminalSession(for:)` factories)
- Test: `DoryTests/TerminalSessionTests.swift`

**Interfaces:**
- Produces: `struct TerminalSession: Identifiable, Hashable, Codable { let id: String; let title: String; let subtitle: String; let logo: String?; let socketPath: String; let containerID: String; let user: String; let shell: String; let home: String }`; `func AppStore.terminalSession(for container: Container) -> TerminalSession`; `func AppStore.terminalSession(for machine: Machine) -> TerminalSession`.

- [ ] **Step 1: Write the failing test**

`DoryTests/TerminalSessionTests.swift`:
```swift
import Testing
import Foundation
@testable import Dory

@MainActor
struct TerminalSessionTests {
    @Test func containerSessionIsRootShell() {
        let store = AppStore()
        let c = Container(id: "c1", name: "web", image: "nginx:latest", status: .running, cpuPercent: 0,
                          memoryDisplay: "0", memoryLimitDisplay: "0", memoryFraction: 0, ports: "", uptime: "",
                          created: "", ipAddress: "", domain: "", command: "", restartPolicy: "")
        let s = store.terminalSession(for: c)
        #expect(s.id == "container:c1")
        #expect(s.containerID == "c1")
        #expect(s.user == "root")
        #expect(s.home == "/root")
        #expect(s.title == "web")
    }

    @Test func machineSessionUsesIdentity() {
        let store = AppStore()
        var m = Machine(name: "ubuntu", distro: "Ubuntu", version: "24.04 LTS", status: .running, cpuPercent: 0,
                        memoryDisplay: "0", ip: "1.2.3.4", letter: "U", badgeHex: 0, containerID: "abc")
        m.username = "augustusotu"; m.loginShell = "/bin/bash"
        let s = store.terminalSession(for: m)
        #expect(s.id == "machine:abc")
        #expect(s.user == "augustusotu")
        #expect(s.shell == "/bin/bash")
        #expect(s.home == "/Users/augustusotu")
        #expect(s.containerID == "abc")
    }

    @Test func rootMachineUsesRootHome() {
        let store = AppStore()
        let m = Machine(name: "legacy", distro: "Ubuntu", version: "24.04", status: .running, cpuPercent: 0,
                        memoryDisplay: "0", ip: "-", letter: "U", badgeHex: 0, containerID: "x")
        #expect(store.terminalSession(for: m).home == "/root")
    }

    @Test func sessionCodableRoundTrips() throws {
        let s = TerminalSession(id: "container:c1", title: "web", subtitle: "nginx", logo: nil,
                                socketPath: "/tmp/x.sock", containerID: "c1", user: "root", shell: "/bin/sh", home: "/root")
        let data = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(TerminalSession.self, from: data) == s)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test.sh -only-testing:DoryTests/TerminalSessionTests`
Expected: FAIL — `TerminalSession` / `terminalSession(for:)` not found.

- [ ] **Step 3: Implement**

`Dory/Runtime/TerminalSession.swift`:
```swift
import Foundation

struct TerminalSession: Identifiable, Hashable, Codable {
    let id: String
    let title: String
    let subtitle: String
    let logo: String?
    let socketPath: String
    let containerID: String
    let user: String
    let shell: String
    let home: String
}
```

In `Dory/Models/AppStore.swift`, add (near the other machine/terminal helpers):
```swift
    func terminalSession(for container: Container) -> TerminalSession {
        TerminalSession(id: "container:\(container.id)", title: container.name, subtitle: container.image,
                        logo: nil, socketPath: shimSocketPath, containerID: container.id,
                        user: "root", shell: "/bin/sh", home: "/root")
    }

    func terminalSession(for machine: Machine) -> TerminalSession {
        let home = machine.username == "root" ? "/root" : "/Users/\(machine.username)"
        let family = MachineDistro.all.first { $0.display == machine.distro }?.family
        return TerminalSession(id: "machine:\(machine.containerID)", title: machine.name,
                               subtitle: "\(machine.distro) \(machine.version)",
                               logo: family.flatMap { MachineDistro.logoAsset(family: $0) },
                               socketPath: shimSocketPath, containerID: machine.containerID,
                               user: machine.username, shell: machine.loginShell, home: home)
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/test.sh -only-testing:DoryTests/TerminalSessionTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Dory/Runtime/TerminalSession.swift Dory/Models/AppStore.swift DoryTests/TerminalSessionTests.swift
git commit -m "feat(terminal): TerminalSession model + container/machine session factories"
```

---

### Task W2: Terminal window view + scene

**Files:**
- Create: `Dory/Features/Containers/TerminalWindowView.swift`
- Modify: `Dory/DoryApp.swift` (add the `WindowGroup(for:)` scene)

**Interfaces:**
- Consumes: `TerminalSession` (W1), `ContainerTerminalView` (WS4-A6), `TerminalLauncher.execArgs` (WS4-A6), the palette.
- Produces: `struct TerminalWindowView: View` (`init(session: TerminalSession)`); a second `WindowGroup` scene keyed by `TerminalSession`.

- [ ] **Step 1: Create the window view**

`Dory/Features/Containers/TerminalWindowView.swift`:
```swift
import SwiftUI

struct TerminalWindowView: View {
    @Environment(\.palette) private var p
    let session: TerminalSession

    var body: some View {
        VStack(spacing: 0) {
            header
            ContainerTerminalView(socketPath: session.socketPath, containerID: session.containerID,
                                  user: session.user, shell: session.shell, home: session.home)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 480, minHeight: 300)
        .background(p.bgWindow)
        .navigationTitle(session.title)
    }

    private var header: some View {
        HStack(spacing: 10) {
            if let logo = session.logo {
                Image(logo).resizable().aspectRatio(contentMode: .fit).frame(width: 18, height: 18)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(p.text)
                Text(session.subtitle).font(.system(size: 11)).foregroundStyle(p.text3).lineLimit(1)
            }
            Spacer()
            Button {
                TerminalLauncher.open(command: "docker -H unix://\(session.socketPath) " +
                    TerminalLauncher.execArgs(user: session.user, shell: session.shell, home: session.home, container: session.containerID))
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.forward.app").font(.system(size: 11, weight: .semibold))
                    Text("Terminal.app").font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(p.accentText)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(p.bgElevated)
        .overlay(alignment: .bottom) { Rectangle().fill(p.border).frame(height: 1) }
    }
}
```

- [ ] **Step 2: Add the WindowGroup scene to DoryApp**

In `Dory/DoryApp.swift`, add a scene after the main `WindowGroup` (before or after `MenuBarExtra`):
```swift
        WindowGroup("Terminal", for: TerminalSession.self) { $session in
            if let session {
                TerminalWindowView(session: session)
                    .environment(store)
                    .environment(\.palette, store.palette)
            }
        }
        .defaultSize(width: 760, height: 480)
```
NOTE: a separate `WindowGroup` does not inherit the main scene's environment, so the palette must be injected here. `RootView` (ContentView.swift:14) sets it as `.environment(\.palette, store.palette)` — use that exact call (`store.palette` is `AppStore.palette`, AppStore.swift:227). `TerminalWindowView` reads `@Environment(\.palette)`.

- [ ] **Step 3: Build**

Run: `scripts/build.sh`
Expected: `BUILD SUCCEEDED`. (`WindowGroup(for:)` compiles because `TerminalSession` is `Codable & Hashable`.)

- [ ] **Step 4: Commit**

```bash
git add Dory/Features/Containers/TerminalWindowView.swift Dory/DoryApp.swift
git commit -m "feat(terminal): windowed terminal view + WindowGroup scene"
```

---

### Task W3: Open windows from containers + machines; remove the modal

**Files:**
- Modify: `Dory/Features/Containers/ContainerDetailView.swift` (overflow "Open Terminal" + terminal-tab "Pop out"), `Dory/Features/Machines/MachinesView.swift` (machine "Terminal" action; remove the modal sheet + `MachineTerminalSheet`), `Dory/Models/AppStore.swift` (remove `machineTerminal`/`openMachineTerminal`)

**Interfaces:**
- Consumes: `AppStore.terminalSession(for:)` (W1), `@Environment(\.openWindow)`.

- [ ] **Step 1: Container open sites → window**

In `Dory/Features/Containers/ContainerDetailView.swift`:
- Add `@Environment(\.openWindow) private var openWindow` to the struct.
- Change the overflow menu item `Button("Open Terminal") { store.openContainerTerminal(container) }` to `Button("Open Terminal") { openWindow(value: store.terminalSession(for: container)) }`.
- In the terminal tab header (next to "Open in Terminal.app ↗"), add a "Pop out ↗" button: `Button { openWindow(value: store.terminalSession(for: container)) } label: { Text("Pop out ↗").font(.system(size: 12, weight: .semibold)).foregroundStyle(p.accentText) }.buttonStyle(.plain)`.

- [ ] **Step 2: Machine "Terminal" action → window; remove the modal**

In `Dory/Features/Machines/MachinesView.swift`:
- Add `@Environment(\.openWindow) private var openWindow` to the struct that renders the machine "Terminal" `actionButton` (the machine card struct — search for `actionButton("terminal", "Terminal"`).
- Change its action from `store.openMachineTerminal(machine)` to `openWindow(value: store.terminalSession(for: machine))`.
- Remove the `.sheet(item: Binding(get: { store.machineTerminal } …)) { … MachineTerminalSheet(machine:) }` modifier from `MachinesView.body`.
- Delete the `private struct MachineTerminalSheet` entirely (it's replaced by `TerminalWindowView`). `logoName(for:)` it used may now be unused — if so, delete it too (otherwise leave it).

In `Dory/Models/AppStore.swift`:
- Delete `var machineTerminal: Machine?` and `func openMachineTerminal(_ machine: Machine) { machineTerminal = machine }`. (Keep `openMachineTerminalApp` — the Terminal.app escape is still used by the window header's button via TerminalLauncher, and any remaining caller.) Grep for any other `machineTerminal`/`openMachineTerminal` references and remove/redirect them.

- [ ] **Step 3: Build**

Run: `scripts/build.sh`
Expected: `BUILD SUCCEEDED`. Fix any dangling references to `machineTerminal`/`MachineTerminalSheet`/`openMachineTerminal` until green.

- [ ] **Step 4: Confirm the terminal logic tests still pass**

Run: `scripts/test.sh -only-testing:DoryTests/TerminalSessionTests`
Expected: PASS (the model/factories are unchanged; this confirms no regression from the wiring).

- [ ] **Step 5: Visual check**

Run: `scripts/shots.sh`. Confirm the app builds and renders; the windowed terminal itself is opened via user action (not reachable by the snapshot harness) — build is the gate for the window wiring.

- [ ] **Step 6: Commit**

```bash
git add Dory/Features/Containers/ContainerDetailView.swift Dory/Features/Machines/MachinesView.swift Dory/Models/AppStore.swift
git commit -m "feat(terminal): open terminals as windows from containers + machines; remove modal"
```

---

## Self-review notes (addressed)

- **Spec coverage:** `TerminalSession` + factories (W1), `TerminalWindowView` + `WindowGroup` scene (W2), open-site wiring + modal removal (W3). All spec components mapped.
- **Type consistency:** `TerminalSession`, `terminalSession(for:)`, `TerminalWindowView`, `openWindow(value:)` — defined once, consumed consistently.
- **Palette in the new scene:** flagged in W2 Step 2 — the terminal scene needs the palette injected the same way `RootView` does (read it to copy the exact call), since a separate `WindowGroup` does not inherit the main scene's environment.
- **`openMachineTerminalApp` kept** (Terminal.app escape) while `openMachineTerminal`/`machineTerminal` (the modal trigger) are removed.
- Non-goals: tabbed terminals, broadcast, window restoration, real-ssh terminal windows.
