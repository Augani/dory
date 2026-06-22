# Foundation + Containers List Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the reusable design-system layer plus a redesigned Containers list and Images list (the "Elevated" bar) — no mock-data flash, a real Running/All/Stopped filter, status pills, port chips, live sparklines, compose grouping, and honest loading/empty states.

**Architecture:** Three layers. (1) `Dory/DesignSystem/` — stateless SwiftUI components, no store dependency. (2) `AppStore` — owns `LoadState`, `ContainerFilter`, grouping, optimistic mutation, port-URL resolution, image-reclaim math (pure, unit-testable). (3) Feature views (`ContainersView`, `ImagesView`, `ContainerDetailView`) — thin renderers. The spec listed `Meter`/`Sparkline`/`DataTable`/`EmptyState` as new; the codebase already has `ThinBar`, `SparkBars`, `TableHeader`/`tableRow()`/`TableEmptyState` — so we **extract and reuse** these rather than duplicate (DRY).

**Tech Stack:** Swift 6 / SwiftUI / macOS, `@Observable @MainActor AppStore`, Swift `Testing` framework, palette via `Environment(\.palette)`.

## Global Constraints

- Build ONLY via `scripts/build.sh`; test ONLY via `scripts/test.sh` (both set the Xcode 27 beta `DEVELOPER_DIR`). Ignore SourceKit/IDE "cannot find" false positives — `scripts/build.sh` is authoritative.
- No inline comments; no docstrings except on public-API surfaces that need them. Self-documenting names.
- Reuse existing shared views — do NOT duplicate: `ThinBar`, `SparkBars`, `StatusDot`, `StatusBadge`, `TableHeader`/`TableHeaderColumn`/`tableRow()`/`TableEmptyState`/`IconTile`, `hoverHighlight`, `CountPill`, `Glyph`, `Color(hex:)` (`Dory/Shared/Color+Hex.swift`), `Font.mono`.
- New action icons use SF Symbols via `Image(systemName:)` — `DoryGlyph` has no stop/restart/terminal/copy/trash glyph.
- Colors come from `Environment(\.palette)` (`DoryPalette`), never raw hex in views (except via existing `Color(hex:)` in shared code).
- Dark mode is the design target. Do not regress light mode; no light-mode pass this cycle.
- Port chips open `https://\(container.domain)` when `container.domain` is non-empty, else `http://localhost:\(hostPort)`.
- `containerFilter` defaults to `.running`, persisted under `UserDefaults` key `"containerFilter"`.
- Tests: `import Testing` + `@testable import Dory`, `@Test`/`#expect`, `@MainActor` where they touch `AppStore`. Place in `DoryTests/`.
- Out of scope (do not touch): light-mode correctness, detail-pane deep rework (logs/stats logic), terminal pop-out, volumes/networks/k8s/compose/machines/settings/onboarding redesign.

---

### Task 1: Design tokens

**Files:**
- Create: `Dory/DesignSystem/Tokens.swift`
- Test: `DoryTests/TokensTests.swift`

**Interfaces:**
- Produces: `enum DoryType: CGFloat { case label, caption, body, title, heading, display; func font(_ weight: Font.Weight = .regular) -> Font }`; `enum DorySpace: CGFloat { case xs, sm, md, lg, xl }`; `enum DoryRadius: CGFloat { case sm, md, lg }`. (Elevation is represented by existing `palette.bgContent < bgElevated < bgInput`; no new enum — YAGNI.)

- [ ] **Step 1: Write the failing test**

`DoryTests/TokensTests.swift`:
```swift
import Testing
import SwiftUI
@testable import Dory

struct TokensTests {
    @Test func typeScaleSizes() {
        #expect(DoryType.label.rawValue == 11)
        #expect(DoryType.body.rawValue == 13)
        #expect(DoryType.display.rawValue == 22)
    }

    @Test func spacingScale() {
        #expect(DorySpace.xs.rawValue == 4)
        #expect(DorySpace.md.rawValue == 12)
        #expect(DorySpace.xl.rawValue == 24)
    }

    @Test func radiusScale() {
        #expect(DoryRadius.sm.rawValue == 6)
        #expect(DoryRadius.lg.rawValue == 12)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test.sh -only-testing:DoryTests/TokensTests`
Expected: FAIL — `cannot find 'DoryType' in scope` (build error).

- [ ] **Step 3: Write the implementation**

`Dory/DesignSystem/Tokens.swift`:
```swift
import SwiftUI

enum DoryType: CGFloat {
    case label = 11
    case caption = 12
    case body = 13
    case title = 15
    case heading = 18
    case display = 22

    func font(_ weight: Font.Weight = .regular) -> Font {
        .system(size: rawValue, weight: weight)
    }
}

enum DorySpace: CGFloat {
    case xs = 4
    case sm = 8
    case md = 12
    case lg = 16
    case xl = 24
}

enum DoryRadius: CGFloat {
    case sm = 6
    case md = 8
    case lg = 12
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/test.sh -only-testing:DoryTests/TokensTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Dory/DesignSystem/Tokens.swift DoryTests/TokensTests.swift
git commit -m "feat(ui): design tokens — type/space/radius scales"
```

---

### Task 2: Published-port parsing + PortChip

**Files:**
- Create: `Dory/DesignSystem/Ports.swift` (model + parser), `Dory/DesignSystem/PortChip.swift` (view)
- Test: `DoryTests/PublishedPortParsingTests.swift`

**Interfaces:**
- Produces: `struct PublishedPort: Equatable, Identifiable, Sendable { let hostPort: Int; let containerPort: Int; let proto: String; var id: String { "\(hostPort)/\(proto)" }; var label: String { ":\(hostPort)" } }`; `func parsePublishedPorts(_ raw: String) -> [PublishedPort]`; `struct PortChip: View` (`init(label: String, action: @escaping () -> Void)`).

- [ ] **Step 1: Write the failing test**

`DoryTests/PublishedPortParsingTests.swift`:
```swift
import Testing
@testable import Dory

struct PublishedPortParsingTests {
    @Test func parsesSinglePort() {
        let ports = parsePublishedPorts("0.0.0.0:8080->80/tcp")
        #expect(ports == [PublishedPort(hostPort: 8080, containerPort: 80, proto: "tcp")])
    }

    @Test func dedupesIPv4AndIPv6() {
        let ports = parsePublishedPorts("0.0.0.0:8080->80/tcp, :::8080->80/tcp")
        #expect(ports.count == 1)
        #expect(ports.first?.hostPort == 8080)
    }

    @Test func keepsDistinctHostPortsSorted() {
        let ports = parsePublishedPorts("0.0.0.0:5432->5432/tcp, 0.0.0.0:8080->80/tcp")
        #expect(ports.map(\.hostPort) == [5432, 8080])
    }

    @Test func ignoresExposedOnlyAndEmpty() {
        #expect(parsePublishedPorts("80/tcp").isEmpty)
        #expect(parsePublishedPorts("").isEmpty)
    }

    @Test func parsesUdp() {
        let ports = parsePublishedPorts("0.0.0.0:53->53/udp")
        #expect(ports.first?.proto == "udp")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test.sh -only-testing:DoryTests/PublishedPortParsingTests`
Expected: FAIL — `cannot find 'parsePublishedPorts' in scope`.

- [ ] **Step 3: Write the implementation**

`Dory/DesignSystem/Ports.swift`:
```swift
import Foundation

struct PublishedPort: Equatable, Identifiable, Sendable {
    let hostPort: Int
    let containerPort: Int
    let proto: String
    var id: String { "\(hostPort)/\(proto)" }
    var label: String { ":\(hostPort)" }
}

func parsePublishedPorts(_ raw: String) -> [PublishedPort] {
    var seen = Set<String>()
    var result: [PublishedPort] = []
    for entry in raw.split(separator: ",") {
        let part = entry.trimmingCharacters(in: .whitespaces)
        guard let arrow = part.range(of: "->") else { continue }
        let lhs = part[..<arrow.lowerBound]
        let rhs = part[arrow.upperBound...]
        guard let hostColon = lhs.lastIndex(of: ":"),
              let hostPort = Int(lhs[lhs.index(after: hostColon)...]) else { continue }
        let rhsParts = rhs.split(separator: "/")
        guard let containerPort = Int(rhsParts.first ?? "") else { continue }
        let proto = rhsParts.count > 1 ? String(rhsParts[1]) : "tcp"
        let key = "\(hostPort)/\(proto)"
        guard !seen.contains(key) else { continue }
        seen.insert(key)
        result.append(PublishedPort(hostPort: hostPort, containerPort: containerPort, proto: proto))
    }
    return result.sorted { $0.hostPort < $1.hostPort }
}
```

`Dory/DesignSystem/PortChip.swift`:
```swift
import SwiftUI

struct PortChip: View {
    @Environment(\.palette) private var p
    let label: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(label).font(.mono(10.5))
                Image(systemName: "arrow.up.right").font(.system(size: 8.5, weight: .bold))
            }
            .foregroundStyle(p.accentText)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(hover ? p.accentWeak : p.bgElevated, in: RoundedRectangle(cornerRadius: DoryRadius.sm.rawValue))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel("Open \(label)")
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/test.sh -only-testing:DoryTests/PublishedPortParsingTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Build to verify PortChip compiles**

Run: `scripts/build.sh`
Expected: `BUILD SUCCEEDED`, `xcodebuild_exit=0`.

- [ ] **Step 6: Commit**

```bash
git add Dory/DesignSystem/Ports.swift Dory/DesignSystem/PortChip.swift DoryTests/PublishedPortParsingTests.swift
git commit -m "feat(ui): published-port parser + PortChip"
```

---

### Task 3: StatusPill, IconButton, DoryButtonStyle, SkeletonRows

**Files:**
- Create: `Dory/DesignSystem/StatusPill.swift`, `Dory/DesignSystem/Buttons.swift`, `Dory/DesignSystem/LoadingSkeleton.swift`
- Test: `DoryTests/StatusPillTests.swift`

**Interfaces:**
- Produces: `struct StatusPill: View` with `init(_ status: RunState)` and `init(inUse: Bool)`; `struct IconButton: View` (`init(systemImage: String, label: String, size: CGFloat = 28, action: () -> Void)`); `struct DoryButtonStyle: ButtonStyle` with `enum Kind { case primary, secondary, destructive }`; `struct SkeletonRows: View` (`init(count: Int = 6)`). Helper on `RunState` used by tests: `var pillText: String`.

- [ ] **Step 1: Write the failing test**

`DoryTests/StatusPillTests.swift`:
```swift
import Testing
@testable import Dory

struct StatusPillTests {
    @Test func runStatePillText() {
        #expect(RunState.running.pillText == "Running")
        #expect(RunState.stopped.pillText == "Stopped")
        #expect(RunState.paused.pillText == "Paused")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test.sh -only-testing:DoryTests/StatusPillTests`
Expected: FAIL — `value of type 'RunState' has no member 'pillText'`.

- [ ] **Step 3: Write the implementation**

Add to `Dory/DesignSystem/StatusPill.swift`:
```swift
import SwiftUI

extension RunState {
    var pillText: String { label }
}

struct StatusPill: View {
    @Environment(\.palette) private var p
    let text: String
    let color: Color
    let background: Color
    var showsDot: Bool = true

    init(_ status: RunState) {
        self.text = status.label
        self.colorKey = .status(status)
        self.showsDot = true
        self.color = .clear
        self.background = .clear
    }

    init(inUse: Bool) {
        self.text = inUse ? "In use" : "Unused"
        self.colorKey = .inUse(inUse)
        self.showsDot = false
        self.color = .clear
        self.background = .clear
    }

    private enum ColorKey { case status(RunState), inUse(Bool) }
    private let colorKey: ColorKey

    private var fg: Color {
        switch colorKey {
        case .status(let s): return s.dotColor(p)
        case .inUse(let used): return used ? p.green : p.text3
        }
    }
    private var bg: Color {
        switch colorKey {
        case .status(let s): return s.badgeBackground(p)
        case .inUse(let used): return used ? p.greenWeak : p.pill
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            if showsDot { Circle().fill(fg).frame(width: 5, height: 5) }
            Text(text).font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(fg)
        .fixedSize()
        .padding(.horizontal, 9).padding(.vertical, 3)
        .background(bg, in: RoundedRectangle(cornerRadius: DoryRadius.md.rawValue))
        .accessibilityLabel(text)
    }
}
```

`Dory/DesignSystem/Buttons.swift`:
```swift
import SwiftUI

struct IconButton: View {
    @Environment(\.palette) private var p
    let systemImage: String
    let label: String
    var size: CGFloat = 28
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(p.text2)
                .frame(width: size, height: size)
                .background(hover ? p.bgHover : Color.clear, in: RoundedRectangle(cornerRadius: DoryRadius.sm.rawValue))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel(label)
    }
}

struct DoryButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, destructive }
    @Environment(\.palette) private var p
    var kind: Kind = .secondary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(background, in: RoundedRectangle(cornerRadius: DoryRadius.md.rawValue))
            .overlay(RoundedRectangle(cornerRadius: DoryRadius.md.rawValue).strokeBorder(border))
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }

    private var foreground: Color {
        switch kind {
        case .primary: return .white
        case .secondary: return p.text
        case .destructive: return p.red
        }
    }
    private var background: Color {
        switch kind {
        case .primary: return p.accent
        case .secondary: return p.bgElevated
        case .destructive: return p.redWeak
        }
    }
    private var border: Color {
        kind == .secondary ? p.border : .clear
    }
}
```

`Dory/DesignSystem/LoadingSkeleton.swift`:
```swift
import SwiftUI

struct SkeletonRows: View {
    @Environment(\.palette) private var p
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var count: Int = 6
    @State private var shimmer = false

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { _ in
                HStack(spacing: 11) {
                    Circle().fill(p.bgElevated).frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 5) {
                        bar(width: 160)
                        bar(width: 96)
                    }
                    Spacer()
                    bar(width: 54)
                }
                .padding(.horizontal, 16).padding(.vertical, 11)
                .overlay(alignment: .bottom) { Rectangle().fill(p.border).frame(height: 1) }
            }
        }
        .opacity(reduceMotion ? 1 : (shimmer ? 0.55 : 1))
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { shimmer = true }
        }
        .accessibilityLabel("Loading containers")
    }

    private func bar(width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 3).fill(p.bgElevated).frame(width: width, height: 9)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/test.sh -only-testing:DoryTests/StatusPillTests`
Expected: PASS (1 test).

- [ ] **Step 5: Build to verify the views compile**

Run: `scripts/build.sh`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 6: Commit**

```bash
git add Dory/DesignSystem/StatusPill.swift Dory/DesignSystem/Buttons.swift Dory/DesignSystem/LoadingSkeleton.swift DoryTests/StatusPillTests.swift
git commit -m "feat(ui): StatusPill, IconButton, DoryButtonStyle, SkeletonRows"
```

---

### Task 4: Extract table primitives into DesignSystem

**Files:**
- Create: `Dory/DesignSystem/Table.swift`
- Modify: `Dory/Features/Tables/ImagesView.swift` (remove the moved structs; keep `ImagesView` itself)

**Interfaces:**
- Produces (moved verbatim, unchanged behavior): `struct TableHeaderColumn`, `struct TableHeader`, `struct TableRowBackground` + `extension View { func tableRow() }`, `struct IconTile`, `struct TableEmptyState`. (`TableSort` stays in `Models.swift` — do not move it.)

This is a pure relocation so every table screen can share these. No behavior change; verified by build + existing tests.

- [ ] **Step 1: Create the new file with the moved structs**

`Dory/DesignSystem/Table.swift` — move `TableHeaderColumn`, `TableHeader`, `TableRowBackground`, the `extension View { func tableRow() }`, `IconTile`, and `TableEmptyState` from `ImagesView.swift` into this new file **verbatim** (lines 3–111 of the current `ImagesView.swift`). Prepend `import SwiftUI`.

- [ ] **Step 2: Delete the moved structs from ImagesView.swift**

`Dory/Features/Tables/ImagesView.swift` now begins directly with `struct ImagesView` (keep `import SwiftUI`). Everything above `struct ImagesView` (the six moved types) is removed.

- [ ] **Step 3: Build to verify nothing broke**

Run: `scripts/build.sh`
Expected: `BUILD SUCCEEDED` (the types are now found in `Table.swift`; `VolumesView`/`NetworksView` that also use `tableRow()`/`TableHeader` still resolve).

- [ ] **Step 4: Run the full existing suite to confirm no regression**

Run: `scripts/test.sh`
Expected: all existing tests PASS (no behavior changed).

- [ ] **Step 5: Commit**

```bash
git add Dory/DesignSystem/Table.swift Dory/Features/Tables/ImagesView.swift
git commit -m "refactor(ui): extract table primitives into DesignSystem/Table"
```

---

### Task 5: AppStore — LoadState, ContainerFilter, grouping, de-mock

**Files:**
- Modify: `Dory/Models/AppStore.swift` (lines 13, 38–39, 44 for defaults; 442–455 `reload()`; 521–524 `filteredContainers`)
- Test: `DoryTests/ContainerListStateTests.swift`

**Interfaces:**
- Consumes: `AppStore(runtime:)`, `RunState`, `Container.composeProject`, `Container.isRunning`.
- Produces: `enum LoadState: Sendable { case connecting, ready, engineOff }`; `var loadState: LoadState`; `enum ContainerFilter: String, CaseIterable, Sendable { case running, all, stopped; var label: String }`; `var containerFilter: ContainerFilter` (persisted); rewritten `var filteredContainers: [Container]` (applies filter + search); `struct ContainerGroup: Identifiable, Sendable { let id: String; let project: String?; let containers: [Container] }`; `var groupedContainers: [ContainerGroup]`.

- [ ] **Step 1: Write the failing test**

`DoryTests/ContainerListStateTests.swift`:
```swift
import Testing
@testable import Dory

@MainActor
struct ContainerListStateTests {
    private func make(_ containers: [Container]) -> AppStore {
        let store = AppStore()
        store.containers = containers
        return store
    }

    private func container(_ id: String, running: Bool, project: String? = nil) -> Container {
        var labels: [String: String] = [:]
        if let project { labels["com.docker.compose.project"] = project }
        return Container(id: id, name: id, image: "img:\(id)", status: running ? .running : .stopped,
                         cpuPercent: 0, memoryDisplay: "0", memoryLimitDisplay: "0", memoryFraction: 0,
                         ports: "", uptime: "", created: "", ipAddress: "", domain: "", command: "",
                         restartPolicy: "", labels: labels)
    }

    @Test func noMockRowsAtInit() {
        let store = AppStore()
        #expect(store.containers.isEmpty)
        #expect(store.loadState == .connecting)
        #expect(store.selectedContainerID == nil)
    }

    @Test func runningFilterShowsOnlyRunning() {
        let store = make([container("a", running: true), container("b", running: false)])
        store.containerFilter = .running
        #expect(store.filteredContainers.map(\.id) == ["a"])
    }

    @Test func stoppedFilterShowsOnlyStopped() {
        let store = make([container("a", running: true), container("b", running: false)])
        store.containerFilter = .stopped
        #expect(store.filteredContainers.map(\.id) == ["b"])
    }

    @Test func allFilterWithSearch() {
        let store = make([container("alpha", running: true), container("beta", running: false)])
        store.containerFilter = .all
        store.filter = "alph"
        #expect(store.filteredContainers.map(\.id) == ["alpha"])
    }

    @Test func groupingByComposeProjectThenUngrouped() {
        let store = make([
            container("web", running: true, project: "shop"),
            container("db", running: true, project: "shop"),
            container("solo", running: true),
        ])
        store.containerFilter = .all
        let groups = store.groupedContainers
        #expect(groups.count == 2)
        #expect(groups[0].project == "shop")
        #expect(groups[0].containers.map(\.id) == ["web", "db"])
        #expect(groups[1].project == nil)
        #expect(groups[1].containers.map(\.id) == ["solo"])
    }

    @Test func filterPersists() {
        let store = AppStore()
        store.containerFilter = .stopped
        #expect(UserDefaults.standard.string(forKey: "containerFilter") == "stopped")
        store.containerFilter = .running
    }

    @Test func reloadBecomesReadyWithMockRuntime() async {
        let store = AppStore()
        await store.reload()
        #expect(store.loadState == .ready)
        #expect(!store.containers.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test.sh -only-testing:DoryTests/ContainerListStateTests`
Expected: FAIL — `cannot find type 'LoadState'` / `value of type 'AppStore' has no member 'containerFilter'`, and `noMockRowsAtInit` fails on the old `MockData.containers` default.

- [ ] **Step 3: Add the new types and state**

In `Dory/Models/AppStore.swift`, add near the other top-level enums (e.g. just above `final class AppStore`):
```swift
enum LoadState: Sendable { case connecting, ready, engineOff }

enum ContainerFilter: String, CaseIterable, Sendable {
    case running, all, stopped
    var label: String {
        switch self {
        case .running: "Running"
        case .all: "All"
        case .stopped: "Stopped"
        }
    }
}

struct ContainerGroup: Identifiable, Sendable {
    let id: String
    let project: String?
    let containers: [Container]
}
```

- [ ] **Step 4: Change the seeded defaults**

`AppStore.swift:13`: `var selectedContainerID: String? = "c1"` → `var selectedContainerID: String? = nil`
`AppStore.swift:38`: `var containers: [Container] = MockData.containers` → `var containers: [Container] = []`
`AppStore.swift:39`: `var images: [DockerImage] = MockData.images` → `var images: [DockerImage] = []`
`AppStore.swift:44`: `var engineRunning = true` → `var engineRunning = false`

Add these stored properties next to the others (after line 44):
```swift
    var loadState: LoadState = .connecting
    var containerFilter: ContainerFilter =
        ContainerFilter(rawValue: UserDefaults.standard.string(forKey: "containerFilter") ?? "") ?? .running
    {
        didSet { UserDefaults.standard.set(containerFilter.rawValue, forKey: "containerFilter") }
    }
```

- [ ] **Step 5: Set loadState inside reload()**

`AppStore.swift:442–443`, replace the guard so a failed snapshot marks the engine off:
```swift
    func reload() async {
        guard let snap = try? await runtime.snapshot() else {
            if loadState != .engineOff { loadState = .engineOff }
            return
        }
```
And at the end of `reload()` (after the `selectedContainerID` reconciliation block, before the closing brace at line 455):
```swift
        let newState: LoadState = snap.engineRunning ? .ready : .engineOff
        if loadState != newState { loadState = newState }
```

- [ ] **Step 6: Rewrite filteredContainers and add groupedContainers**

Replace `filteredContainers` (AppStore.swift:521–524):
```swift
    private func matchesSearch(_ c: Container) -> Bool {
        filter.isEmpty
            || c.name.localizedCaseInsensitiveContains(filter)
            || c.image.localizedCaseInsensitiveContains(filter)
    }

    var filteredContainers: [Container] {
        containers.filter { c in
            let stateOK: Bool
            switch containerFilter {
            case .running: stateOK = c.isRunning
            case .stopped: stateOK = !c.isRunning
            case .all: stateOK = true
            }
            return stateOK && matchesSearch(c)
        }
    }

    var groupedContainers: [ContainerGroup] {
        var order: [String] = []
        var byProject: [String: [Container]] = [:]
        var ungrouped: [Container] = []
        for c in filteredContainers {
            if let project = c.composeProject {
                if byProject[project] == nil { order.append(project) }
                byProject[project, default: []].append(c)
            } else {
                ungrouped.append(c)
            }
        }
        var groups = order.map { ContainerGroup(id: "proj:\($0)", project: $0, containers: byProject[$0] ?? []) }
        if !ungrouped.isEmpty { groups.append(ContainerGroup(id: "ungrouped", project: nil, containers: ungrouped)) }
        return groups
    }
```

- [ ] **Step 7: Run test to verify it passes**

Run: `scripts/test.sh -only-testing:DoryTests/ContainerListStateTests`
Expected: PASS (7 tests). If `ContainersView` references `filteredContainers` directly it still compiles (same name).

- [ ] **Step 8: Build to confirm the app still compiles with empty defaults**

Run: `scripts/build.sh`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 9: Commit**

```bash
git add Dory/Models/AppStore.swift DoryTests/ContainerListStateTests.swift
git commit -m "feat(ui): container LoadState + Running/All/Stopped filter + compose grouping, drop mock seeding"
```

---

### Task 6: AppStore — port URLs, CPU history, optimistic busy, image reclaim

**Files:**
- Modify: `Dory/Models/AppStore.swift` (`toggle` 651–681; add new members)
- Test: `DoryTests/ContainerActionsTests.swift`

**Interfaces:**
- Consumes: `Container.domain`, `PublishedPort`, `parsePublishedPorts`, `DockerImage.isUsed`/`.sizeBytes`.
- Produces: `func portURL(for container: Container, port: PublishedPort) -> URL`; `var cpuHistory: [String: [Double]]`; `func recordCPU(_ id: String, _ value: Double)`; `var pendingContainerIDs: Set<String>`; `func performToggle(_ container: Container) async`; `var reclaimableImageBytes: Int64`; `var reclaimLabel: String?`.

- [ ] **Step 1: Write the failing test**

`DoryTests/ContainerActionsTests.swift`:
```swift
import Testing
import Foundation
@testable import Dory

@MainActor
struct ContainerActionsTests {
    private func container(_ id: String, running: Bool, domain: String = "", ports: String = "") -> Container {
        Container(id: id, name: id, image: "img", status: running ? .running : .stopped,
                  cpuPercent: 0, memoryDisplay: "0", memoryLimitDisplay: "0", memoryFraction: 0,
                  ports: ports, uptime: "", created: "", ipAddress: "", domain: domain, command: "",
                  restartPolicy: "", labels: [:])
    }

    @Test func portURLPrefersDomain() {
        let store = AppStore()
        let c = container("a", running: true, domain: "web-api.dory.local")
        let url = store.portURL(for: c, port: PublishedPort(hostPort: 8080, containerPort: 80, proto: "tcp"))
        #expect(url.absoluteString == "https://web-api.dory.local")
    }

    @Test func portURLFallsBackToLocalhost() {
        let store = AppStore()
        let c = container("a", running: true, domain: "")
        let url = store.portURL(for: c, port: PublishedPort(hostPort: 8080, containerPort: 80, proto: "tcp"))
        #expect(url.absoluteString == "http://localhost:8080")
    }

    @Test func cpuHistoryAppendsAndCaps() {
        let store = AppStore()
        for i in 0..<30 { store.recordCPU("a", Double(i)) }
        #expect((store.cpuHistory["a"]?.count ?? 0) <= 20)
        #expect(store.cpuHistory["a"]?.last == 29)
    }

    @Test func reclaimableSumsUnusedOnly() {
        let store = AppStore()
        store.images = [
            DockerImage(repository: "a", tag: "1", imageID: "1", size: "", created: "", usedByCount: 0, sizeBytes: 100),
            DockerImage(repository: "b", tag: "1", imageID: "2", size: "", created: "", usedByCount: 2, sizeBytes: 500),
            DockerImage(repository: "c", tag: "1", imageID: "3", size: "", created: "", usedByCount: 0, sizeBytes: 400),
        ]
        #expect(store.reclaimableImageBytes == 500)
        #expect(store.reclaimLabel != nil)
    }

    @Test func reclaimLabelNilWhenNothingToReclaim() {
        let store = AppStore()
        store.images = [DockerImage(repository: "b", tag: "1", imageID: "2", size: "", created: "", usedByCount: 1, sizeBytes: 500)]
        #expect(store.reclaimLabel == nil)
    }

    @Test func performToggleClearsPending() async {
        let store = AppStore()
        store.containers = [container("a", running: false)]
        await store.performToggle(store.containers[0])
        #expect(!store.pendingContainerIDs.contains("a"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test.sh -only-testing:DoryTests/ContainerActionsTests`
Expected: FAIL — missing `portURL`, `cpuHistory`, `recordCPU`, `reclaimableImageBytes`, `reclaimLabel`, `pendingContainerIDs`, `performToggle`.

- [ ] **Step 3: Add the port-URL, CPU history, and reclaim members**

Add to `AppStore` (near the other container helpers, e.g. after `runningCount` at line 492):
```swift
    var pendingContainerIDs: Set<String> = []
    var cpuHistory: [String: [Double]] = [:]

    func recordCPU(_ id: String, _ value: Double) {
        var samples = cpuHistory[id] ?? []
        samples.append(value)
        if samples.count > 20 { samples.removeFirst(samples.count - 20) }
        cpuHistory[id] = samples
    }

    func portURL(for container: Container, port: PublishedPort) -> URL {
        if !container.domain.isEmpty, let url = URL(string: "https://\(container.domain)") {
            return url
        }
        return URL(string: "http://localhost:\(port.hostPort)") ?? URL(string: "http://localhost")!
    }

    func openPort(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    var reclaimableImageBytes: Int64 {
        images.filter { !$0.isUsed }.reduce(0) { $0 + max(0, $1.sizeBytes) }
    }

    var reclaimLabel: String? {
        let bytes = reclaimableImageBytes
        guard bytes > 0 else { return nil }
        let formatted = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return "Reclaim \(formatted)"
    }
```

- [ ] **Step 4: Make toggle optimistic-with-busy and extract performToggle**

Replace `toggle(_:)` (AppStore.swift:651–681) with a thin wrapper plus an awaitable body:
```swift
    func toggle(_ container: Container) {
        Task { await performToggle(container) }
    }

    func performToggle(_ container: Container) async {
        guard let idx = containers.firstIndex(where: { $0.id == container.id }) else { return }
        let wasRunning = container.status == .running
        pendingContainerIDs.insert(container.id)
        defer { pendingContainerIDs.remove(container.id) }

        var c = containers[idx]
        if wasRunning {
            c.status = .stopped
            c.cpuPercent = 0
            c.memoryDisplay = "0 MB"
            c.memoryFraction = 0
            c.memoryBytes = 0
            c.uptime = "—"
        } else {
            c.status = .running
            c.cpuPercent = runtimeKind == .mock ? 1.2 : 0
            c.memoryDisplay = c.memoryLimitDisplay == "2 GB" ? "128 MB" : "96 MB"
            c.memoryFraction = 0.08
            c.memoryBytes = c.memoryLimitDisplay == "2 GB" ? 134_217_728 : 100_663_296
            c.uptime = "just now"
        }
        containers[idx] = c

        do {
            if wasRunning { try await runtime.stop(containerID: container.id) }
            else { try await runtime.start(containerID: container.id) }
        } catch {
            actionError = "Couldn't \(wasRunning ? "stop" : "start") \(container.name): \(error.localizedDescription)"
        }
        if runtimeKind != .mock { await reload() }
    }
```

- [ ] **Step 5: Run test to verify it passes**

Run: `scripts/test.sh -only-testing:DoryTests/ContainerActionsTests`
Expected: PASS (6 tests).

- [ ] **Step 6: Build**

Run: `scripts/build.sh`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 7: Commit**

```bash
git add Dory/Models/AppStore.swift DoryTests/ContainerActionsTests.swift
git commit -m "feat(ui): port-URL resolution, per-row CPU history, optimistic busy, image-reclaim math"
```

---

### Task 7: Rebuild the Containers list

**Files:**
- Modify: `Dory/Features/Containers/ContainersView.swift` (full rewrite of the list + rows + header; keep the detail split + resize handle from lines 10–52)

**Interfaces:**
- Consumes: `store.loadState`, `store.containerFilter`, `store.runningCount`, `store.groupedContainers`, `store.filteredContainers`, `store.pendingContainerIDs`, `store.cpuHistory`, `store.portURL(for:port:)`, `store.openPort(_:)`, `parsePublishedPorts`, `StatusPill`, `PortChip`, `IconButton`, `DoryButtonStyle`, `SkeletonRows`, `TableEmptyState`, `SparkBars`, `ThinBar`.

- [ ] **Step 1: Write the new ContainersView**

Replace the entire contents of `Dory/Features/Containers/ContainersView.swift`:
```swift
import SwiftUI
import AppKit

struct ContainersView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var p
    @State private var dragStartWidth: Double?
    private let resizeHandleWidth: Double = 9

    var body: some View {
        GeometryReader { geo in
            let maxDetail = max(320, geo.size.width - 360 - resizeHandleWidth)
            let detailWidth = min(max(store.containerDetailWidth, 320), maxDetail)
            HStack(alignment: .top, spacing: 0) {
                listColumn
                if let selected = store.selectedContainer {
                    resizeHandle(currentWidth: detailWidth, maxDetail: maxDetail)
                    ContainerDetailView(container: selected)
                        .frame(width: detailWidth)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .background(p.bgContent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    @ViewBuilder private var listColumn: some View {
        VStack(spacing: 0) {
            toolbar
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .trailing) {
            if store.selectedContainer == nil { Rectangle().fill(p.border).frame(width: 1) }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text("Containers").font(DoryType.title.font(.semibold)).foregroundStyle(p.text)
            if store.runningCount > 0 {
                HStack(spacing: 5) {
                    Circle().fill(p.green).frame(width: 6, height: 6)
                    Text("\(store.runningCount) running").font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(p.green)
                .padding(.horizontal, 9).padding(.vertical, 2)
                .background(p.greenWeak, in: Capsule())
            }
            Spacer()
            filterControl
            Button { store.activeSheet = .newContainer } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                    Text("New")
                }
            }
            .buttonStyle(DoryButtonStyle(kind: .primary))
            .accessibilityIdentifier("new-container")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(p.border).frame(height: 1) }
    }

    private var filterControl: some View {
        HStack(spacing: 2) {
            ForEach(ContainerFilter.allCases, id: \.self) { f in
                let selected = store.containerFilter == f
                Button { store.containerFilter = f } label: {
                    Text(f.label)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(selected ? .white : p.text2)
                        .padding(.horizontal, 11).padding(.vertical, 4)
                        .background(selected ? p.accent : Color.clear, in: RoundedRectangle(cornerRadius: DoryRadius.sm.rawValue))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("filter-\(f.rawValue)")
            }
        }
        .padding(2)
        .background(p.bgInput, in: RoundedRectangle(cornerRadius: DoryRadius.md.rawValue))
    }

    @ViewBuilder private var content: some View {
        if store.loadState == .connecting && store.containers.isEmpty {
            SkeletonRows()
            Spacer(minLength: 0)
        } else if store.loadState == .engineOff {
            TableEmptyState(glyph: .containers, title: "Engine not running",
                            message: "Dory's container engine isn't running yet. It starts automatically when Dory connects.")
        } else if store.containers.isEmpty {
            TableEmptyState(glyph: .containers, title: "No containers yet",
                            message: "Run a container from an image, or start one with `docker run`.",
                            actionLabel: "New Container", action: { store.activeSheet = .newContainer })
        } else if store.filteredContainers.isEmpty {
            TableEmptyState(glyph: .search, title: "No matches",
                            message: "No containers match the current filter.")
        } else {
            listHeader
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: []) {
                    ForEach(store.groupedContainers) { group in
                        if let project = group.project {
                            groupHeader(project, count: group.containers.count)
                        }
                        ForEach(group.containers) { ContainerRow(container: $0) }
                    }
                }
            }
            .defaultScrollAnchor(.top)
        }
    }

    private func groupHeader(_ project: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "square.stack.3d.up").font(.system(size: 11)).foregroundStyle(p.text3)
            Text(project).font(.system(size: 11, weight: .semibold)).foregroundStyle(p.text)
            Text("compose · \(count) service\(count == 1 ? "" : "s")").font(.system(size: 10.5)).foregroundStyle(p.text3)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .background(p.bgContent)
        .overlay(alignment: .bottom) { Rectangle().fill(p.border).frame(height: 1) }
    }

    private var listHeader: some View {
        HStack(spacing: 0) {
            Text("NAME").frame(maxWidth: .infinity, alignment: .leading)
            Text("CPU").frame(width: 92, alignment: .leading)
            Text("MEMORY").frame(width: 70, alignment: .leading)
            Color.clear.frame(width: 96)
        }
        .font(.system(size: 10.5, weight: .bold)).tracking(0.5)
        .foregroundStyle(p.text3)
        .padding(.horizontal, 16).padding(.vertical, 7)
        .background(p.bgContent)
        .overlay(alignment: .bottom) { Rectangle().fill(p.border).frame(height: 1) }
    }

    private func resizeHandle(currentWidth: Double, maxDetail: Double) -> some View {
        Rectangle()
            .fill(p.border)
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .padding(.horizontal, 4)
            .background(p.bgContent)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if dragStartWidth == nil { dragStartWidth = currentWidth }
                        let start = dragStartWidth ?? currentWidth
                        store.containerDetailWidth = min(max(start - value.translation.width, 320), maxDetail)
                    }
                    .onEnded { _ in
                        dragStartWidth = nil
                        store.setContainerDetailWidth(store.containerDetailWidth)
                    }
            )
            .accessibilityIdentifier("container-detail-resize")
    }
}

private struct ContainerRow: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var p
    let container: Container
    @State private var hover = false

    private var selected: Bool { store.selectedContainerID == container.id }
    private var pending: Bool { store.pendingContainerIDs.contains(container.id) }
    private var ports: [PublishedPort] { parsePublishedPorts(container.ports) }
    private var spark: [Double] { (store.cpuHistory[container.id] ?? []).map { min(100, max(0, $0 * 7)) } }

    var body: some View {
        HStack(spacing: 0) {
            StatusPill(container.status).padding(.trailing, 10)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(container.name).font(DoryType.body.font(.semibold)).foregroundStyle(p.text).lineLimit(1)
                    ForEach(ports.prefix(3)) { port in
                        PortChip(label: port.label) { store.openPort(store.portURL(for: container, port: port)) }
                    }
                }
                Text(container.image).font(.mono(11)).foregroundStyle(p.text3).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                if container.isRunning && !spark.isEmpty {
                    SparkBars(heights: spark, tint: p.accent).frame(width: 30, height: 14)
                }
                Text(container.isRunning ? String(format: "%.1f%%", container.cpuPercent) : "—")
                    .font(.system(size: 12)).monospacedDigit().foregroundStyle(p.text2)
            }
            .frame(width: 92, alignment: .leading)

            Text(container.isRunning ? container.memoryDisplay : "—")
                .font(.system(size: 12)).monospacedDigit().foregroundStyle(p.text2)
                .frame(width: 70, alignment: .leading)

            rowActions.frame(width: 96, alignment: .trailing)
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .background(rowBackground)
        .overlay(alignment: .leading) {
            if selected { Capsule().fill(p.accent).frame(width: 2.5).padding(.vertical, 6) }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(p.border).frame(height: 1) }
        .contentShape(Rectangle())
        .onTapGesture { store.selectedContainerID = container.id }
        .onHover { hover = $0 }
        .accessibilityIdentifier("container-\(container.id)")
    }

    @ViewBuilder private var rowActions: some View {
        HStack(spacing: 2) {
            if pending {
                ProgressView().controlSize(.small).frame(width: 28, height: 28)
            } else if hover || selected {
                IconButton(systemImage: container.isRunning ? "stop.fill" : "play.fill",
                           label: container.isRunning ? "Stop \(container.name)" : "Start \(container.name)") {
                    store.toggle(container)
                }
                IconButton(systemImage: "terminal", label: "Open terminal for \(container.name)") {
                    store.openContainerTerminal(container)
                }
            } else {
                Image(systemName: container.isRunning ? "circle.fill" : "circle")
                    .font(.system(size: 7)).foregroundStyle(container.isRunning ? p.green : p.text3)
                    .frame(width: 28, height: 28)
            }
        }
    }

    private var rowBackground: Color {
        if selected { return p.accentWeak }
        return hover ? p.bgRowHover : Color.clear
    }
}
```

- [ ] **Step 2: Build**

Run: `scripts/build.sh`
Expected: `BUILD SUCCEEDED`. (`AppSheet.newContainer` is the verified case for the New button + empty-state action; the engine-off state is intentionally informational because there is no engine-start entry point to wire.)

- [ ] **Step 3: Visual check via snapshot**

Run: `scripts/shots.sh` (captures app screens). Confirm the Containers screen shows the new toolbar (title + running chip + Running/All/Stopped + New), elevated rows with pills, and — when empty — a `TableEmptyState`. No mock rows appear at cold launch.

- [ ] **Step 4: Commit**

```bash
git add Dory/Features/Containers/ContainersView.swift
git commit -m "feat(ui): rebuild Containers list — filter, states, pills, port chips, sparkline, grouping, hover actions"
```

---

### Task 8: Redesign the Images list

**Files:**
- Modify: `Dory/Features/Tables/ImagesView.swift` (header gains Reclaim button; rows gain hover actions on the extracted `tableRow()`)

**Interfaces:**
- Consumes: `store.filteredImages`, `store.images`, `store.imagesSort`, `store.toggleSort(.images,_)`, `store.reclaimLabel`, `store.pruneImages()`, `store.removeImage(_:)`, `store.inspect(_:)`, `store.createContainer(...)`, `StatusPill(inUse:)`, `TableHeader`, `TableEmptyState`, `IconTile`, `IconButton`, `tableRow()`.

- [ ] **Step 1: Add a Reclaim affordance and hover row actions**

Replace the body of `struct ImagesView` (`Dory/Features/Tables/ImagesView.swift`) with:
```swift
struct ImagesView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var p
    @State private var confirmingPrune = false

    var body: some View {
        VStack(spacing: 0) {
            if let reclaim = store.reclaimLabel {
                HStack {
                    Spacer()
                    Button { confirmingPrune = true } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "trash").font(.system(size: 11, weight: .semibold))
                            Text(reclaim)
                        }
                    }
                    .buttonStyle(DoryButtonStyle(kind: .secondary))
                    .accessibilityIdentifier("reclaim-images")
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .overlay(alignment: .bottom) { Rectangle().fill(p.border).frame(height: 1) }
            }
            TableHeader(columns: [
                .init("REPOSITORY", sort: "repository"), .init("IMAGE ID", 120), .init("SIZE", 90, sort: "size"),
                .init("CREATED", 120, sort: "created"), .init("IN USE", 92, sort: "used"), .init("", 84),
            ], sort: store.imagesSort, onSort: { store.toggleSort(.images, $0) })
            if store.filteredImages.isEmpty {
                TableEmptyState(
                    glyph: .images,
                    title: store.images.isEmpty ? "No images yet" : "No matches",
                    message: store.images.isEmpty
                        ? "Pull an image from a registry, or build one from a Dockerfile."
                        : "No images match \u{201C}\(store.filter)\u{201D}.",
                    actionLabel: store.images.isEmpty ? "Pull Image" : nil,
                    action: store.images.isEmpty ? { store.activeSheet = .pullImage } : nil
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.filteredImages) { image in ImageRow(image: image) }
                    }
                }
            }
        }
        .confirmationDialog("Reclaim unused images?", isPresented: $confirmingPrune, titleVisibility: .visible) {
            Button("Reclaim", role: .destructive) { store.pruneImages() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes images not used by any container. This cannot be undone.")
        }
    }
}

private struct ImageRow: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var p
    let image: DockerImage
    @State private var hover = false

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 11) {
                IconTile(glyph: .images, tint: p.accentText, background: p.accentWeak)
                HStack(spacing: 0) {
                    Text(image.repository).font(.system(size: 13, weight: .semibold)).foregroundStyle(p.text)
                        .lineLimit(1).truncationMode(.middle)
                    Text(":\(image.tag)").font(.system(size: 13)).foregroundStyle(p.text3).lineLimit(1).fixedSize()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(image.imageID).font(.mono(12)).foregroundStyle(p.text3).frame(width: 120, alignment: .leading)
            Text(image.size).font(.system(size: 12.5)).monospacedDigit().foregroundStyle(p.text2).frame(width: 90, alignment: .leading)
            Text(image.created).font(.system(size: 12.5)).foregroundStyle(p.text3).frame(width: 120, alignment: .leading)
            StatusPill(inUse: image.isUsed).frame(width: 92, alignment: .leading)
            rowActions.frame(width: 84, alignment: .trailing)
        }
        .tableRow()
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { store.inspect(image) }
        .onHover { hover = $0 }
        .contextMenu { menu }
    }

    @ViewBuilder private var rowActions: some View {
        HStack(spacing: 2) {
            if hover {
                IconButton(systemImage: "play.fill", label: "Run \(image.repository)") { runImage() }
                IconButton(systemImage: "info.circle", label: "Inspect \(image.repository)") { store.inspect(image) }
                IconButton(systemImage: "trash", label: "Delete \(image.repository)") { store.removeImage(image) }
            }
        }
    }

    @ViewBuilder private var menu: some View {
        Button("Inspect") { store.inspect(image) }
        Button("Run") { runImage() }
        Button("Copy Image ID") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(image.imageID, forType: .string)
        }
        Divider()
        Button("Delete Image", role: .destructive) { store.removeImage(image) }
    }

    private func runImage() {
        Task {
            if let err = await store.createContainer(name: "", image: "\(image.repository):\(image.tag)", ports: [], env: [:]) {
                store.actionError = err
            } else { store.section = .containers }
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `scripts/build.sh`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Visual check**

Run: `scripts/shots.sh`. Confirm the Images screen shows the `In use`/`Unused` pill, hover row actions (Run / Inspect / Delete), the "Reclaim N GB" button when unused images exist, and the empty state when there are none.

- [ ] **Step 4: Commit**

```bash
git add Dory/Features/Tables/ImagesView.swift
git commit -m "feat(ui): redesign Images list — in-use pill, hover actions, reclaim affordance"
```

---

### Task 9: Adopt new components in the container detail pane

**Files:**
- Modify: `Dory/Features/Containers/ContainerDetailView.swift` (header badge → `StatusPill`; action buttons → `DoryButtonStyle`; overflow menu → `IconButton`)

This is component adoption only — no change to stats/logs/terminal logic (those are WS3/WS5).

- [ ] **Step 1: Swap the header badge to StatusPill**

In `ContainerDetailView.swift`, `header` (line 70), replace:
```swift
            StatusBadge(label: container.status.label, color: container.status.dotColor(p), background: container.status.badgeBackground(p))
```
with:
```swift
            StatusPill(container.status)
```

- [ ] **Step 2: Swap the Start/Stop/Restart buttons to DoryButtonStyle**

Replace the `actions` HStack contents (lines 75–77) and delete the private `actionButton` helper (lines 105–113); use:
```swift
        HStack(spacing: 7) {
            Button(container.isRunning ? "Stop" : "Start") { store.toggle(container) }
                .buttonStyle(DoryButtonStyle(kind: .secondary))
            Button("Restart") { store.restart(container) }
                .buttonStyle(DoryButtonStyle(kind: .secondary))
            Spacer(minLength: 0)
            Menu {
                Button("Open Terminal") { store.openContainerTerminal(container) }
                    .disabled(!container.isRunning)
                Button("Copy Container ID") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(container.id, forType: .string)
                }
                Divider()
                Button("Delete Container", role: .destructive) { confirmingDelete = true }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .bold)).foregroundStyle(p.text2)
                    .frame(width: 32, height: 30)
                    .background(p.bgElevated, in: RoundedRectangle(cornerRadius: DoryRadius.sm.rawValue))
                    .overlay(RoundedRectangle(cornerRadius: DoryRadius.sm.rawValue).strokeBorder(p.border))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityIdentifier("container-menu")
        }
        .confirmationDialog("Delete \(container.name)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { store.remove(container) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes the container. This cannot be undone.")
        }
```

- [ ] **Step 3: Build**

Run: `scripts/build.sh`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Run the full test suite**

Run: `scripts/test.sh`
Expected: all suites PASS (Tokens, PublishedPortParsing, StatusPill, ContainerListState, ContainerActions, plus all pre-existing tests).

- [ ] **Step 5: Visual check**

Run: `scripts/shots.sh`. Confirm the detail pane header shows the `StatusPill`, the Start/Stop/Restart buttons use the new style, and the overflow menu icon is the SF Symbol ellipsis.

- [ ] **Step 6: Commit**

```bash
git add Dory/Features/Containers/ContainerDetailView.swift
git commit -m "feat(ui): adopt StatusPill + DoryButtonStyle in container detail pane"
```

---

## Self-review notes (addressed)

- **Spec coverage:** tokens (T1), components incl. EmptyState/Skeleton/Buttons/PortChip/StatusPill (T1–T4, reusing ThinBar/SparkBars/Table*), LoadState + filter + grouping + de-mock (T5), port-URL/cpuHistory/optimistic/reclaim (T6), Containers list states+rows (T7), Images redesign (T8), detail-pane adoption (T9). All spec sections map to a task.
- **DRY deviation from spec (intentional):** spec's `Meter`/`Sparkline`/`DataTable`/`EmptyState` already exist as `ThinBar`/`SparkBars`/`TableHeader`+`tableRow()`/`TableEmptyState`; the plan extracts/reuses (T4) instead of creating duplicates.
- **Type consistency:** `ContainerFilter`, `LoadState`, `ContainerGroup`, `PublishedPort`, `StatusPill`, `IconButton`, `DoryButtonStyle`, `SkeletonRows`, `portURL`, `recordCPU`, `pendingContainerIDs`, `reclaimLabel`, `performToggle` are defined once (T1–T6) and consumed by the exact same names in T7–T9.
- **Sheet cases resolved:** the New button + empty-state action use the verified `AppSheet.newContainer`; there is no engine-start entry point, so the engine-off state is informational (no button) by design.
```
