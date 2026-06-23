# Truthful Lists Implementation Plan (WS2 completion)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax for tracking. The governing spec is the committed audit digest `docs/superpowers/specs/2026-06-22-ui-redesign-audit-digest.md` §3 WS2.

**Goal:** Finish WS2's "list truth & liveness" — kill the remaining mock-data flash on Volumes/Networks/Machines, stop the Networks list mislabeling a truly-empty state as "No matches", and make the menu-bar list honor its "N running" header instead of dumping every container flat.

**Architecture:** Three independent, mechanical changes following patterns already established elsewhere in the app (containers/images/pods are already de-mocked; Volumes already branches its empty state on `store.volumes.isEmpty`). No new types.

**Tech Stack:** Swift 6 / SwiftUI / macOS.

## Global Constraints

- Build ONLY with `scripts/build.sh` (Xcode 27 beta `DEVELOPER_DIR`); `BUILD SUCCEEDED` / `xcodebuild_exit=0` is the authoritative gate. Never call `xcodebuild` directly. Minutes per run.
- IGNORE SourceKit/IDE diagnostics — always false positives in this project (toolchain mismatch).
- Synchronized Xcode folders — no `Dory.xcodeproj/project.pbxproj` edits.
- No inline comments; no docstrings. Colors via `Environment(\.palette)` (`p`) or `store.palette`.
- Build/snapshot-verified UI cycle — no new unit tests (these are seed + view changes; the reload paths that repopulate the de-mocked collections already exist and are exercised at runtime).

---

### Task L1: De-mock the Volumes / Networks / Machines seeds

**Files:**
- Modify: `Dory/Models/AppStore.swift` (the property seeds at the `var volumes` / `var networks` / `var machines` declarations)

**Context:** `containers`, `images`, and `pods` already seed `[]` (lines ~58-62) and `engineRunning` already defaults `false`. Only `volumes`, `networks`, `machines` still seed from `MockData`, so those three surfaces flash fabricated rows on cold launch before the first `reload()`. The reload paths already reassign all three unconditionally: volumes/networks via the snapshot apply (`if volumes != snap.volumes { volumes = snap.volumes }`, `if networks != snap.networks { networks = snap.networks }`), and machines via `reloadMachines()` (`machines = list`, with the non-docker guard setting `machines = []`). So seeding `[]` is safe — the collections populate from the engine on first load.

- [ ] **Step 1: Change the three seeds to empty**

In `Dory/Models/AppStore.swift`, change:
```swift
    var volumes: [Volume] = MockData.volumes
    var networks: [DoryNetwork] = MockData.networks
    var pods: [Pod] = []
    var machines: [Machine] = MockData.machines
```
to:
```swift
    var volumes: [Volume] = []
    var networks: [DoryNetwork] = []
    var pods: [Pod] = []
    var machines: [Machine] = []
```
Do NOT touch `pods` (already `[]`) or any other property. Leave `MockData` itself in place (still used by the mock runtime). Do not remove any `MockData` members.

- [ ] **Step 2: Confirm the reload paths still populate these**

Read the reload/snapshot code in `AppStore.swift` and confirm (no edit needed) that `volumes`, `networks` are set from the snapshot and `machines` from `reloadMachines()` on a real reload — so a non-mock engine repopulates all three. If any of the three is NOT reassigned anywhere on reload, STOP and report it (that would mean de-mocking leaves it permanently empty).

- [ ] **Step 3: Build**

Run: `scripts/build.sh`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
git add Dory/Models/AppStore.swift
git commit -m "fix(lists): seed volumes/networks/machines empty (kill mock flash on cold launch)"
```

---

### Task L2: Honest Networks empty state (truly-empty vs filter-miss)

**Files:**
- Modify: `Dory/Features/Tables/NetworksView.swift` (the empty-state branch)

**Context:** `NetworksView` currently shows a hardcoded `TableEmptyState(title: "No matches", message: "No networks match …")` whenever `filteredNetworks.isEmpty`, even when there are genuinely zero networks (now common after L1's de-mock). `VolumesView` already does this correctly by branching on `store.volumes.isEmpty` — mirror that exact pattern. `TableEmptyState`'s init is `TableEmptyState(glyph:title:message:actionLabel:action:)` where `actionLabel`/`action` are optional.

- [ ] **Step 1: Branch the empty state on the unfiltered count**

In `Dory/Features/Tables/NetworksView.swift`, replace:
```swift
            if store.filteredNetworks.isEmpty {
                TableEmptyState(
                    glyph: .networks,
                    title: "No matches",
                    message: "No networks match \u{201C}\(store.filter)\u{201D}."
                )
            } else {
```
with:
```swift
            if store.filteredNetworks.isEmpty {
                TableEmptyState(
                    glyph: .networks,
                    title: store.networks.isEmpty ? "No networks yet" : "No matches",
                    message: store.networks.isEmpty
                        ? "Networks created by your containers and Compose projects appear here."
                        : "No networks match \u{201C}\(store.filter)\u{201D}."
                )
            } else {
```
(No action button — networks are typically created by the runtime, not a New-Network sheet. Match `VolumesView`'s branching shape, just without `actionLabel`/`action`.)

- [ ] **Step 2: Build**

Run: `scripts/build.sh`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add Dory/Features/Tables/NetworksView.swift
git commit -m "fix(networks): honest empty state — distinguish truly-empty from filter-miss"
```

---

### Task L3: Menu-bar list honors its "N running" header

**Files:**
- Modify: `Dory/Features/MenuBar/MenuBarContentView.swift` (the `list` view)

**Context:** The header reads "`\(store.runningCount) running · …`" but `list` does `ForEach(store.containers)` — every container, running and stopped, flat — contradicting the header. Reorder so running containers come first (matching the header), and cap the visible rows with an overflow row that opens the main window. Keep the existing per-row layout (StatusDot + name + cpu% + play/pause toggle) exactly; only change which rows are shown and their order.

- [ ] **Step 1: Add an ordered, capped row model and an overflow row**

In `Dory/Features/MenuBar/MenuBarContentView.swift`, replace the `list` computed property:
```swift
    private var list: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(store.containers) { container in
                    HStack(spacing: 9) {
                        StatusDot(color: container.status.dotColor(store.palette), size: 7)
                        Text(container.name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(store.palette.text).lineLimit(1)
                        Spacer(minLength: 0)
                        Text("\(container.cpuPercent, specifier: "%.1f")%").font(.system(size: 11)).monospacedDigit().foregroundStyle(store.palette.text3)
                        Glyph(glyph: container.isRunning ? .pause : .play, size: 11, color: store.palette.text2)
                            .frame(width: 26, height: 22)
                            .contentShape(Rectangle())
                            .onTapGesture { store.toggle(container) }
                    }
                    .padding(.horizontal, 9).padding(.vertical, 7)
                }
            }
            .padding(6)
        }
        .frame(maxHeight: 260)
    }
```
with:
```swift
    private var orderedContainers: [Container] {
        store.containers.sorted { lhs, rhs in
            if lhs.isRunning != rhs.isRunning { return lhs.isRunning }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private var list: some View {
        let ordered = orderedContainers
        let cap = 8
        let visible = Array(ordered.prefix(cap))
        let overflow = ordered.count - visible.count
        return ScrollView {
            VStack(spacing: 0) {
                if visible.isEmpty {
                    Text("No containers")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(store.palette.text3)
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                }
                ForEach(visible) { container in
                    HStack(spacing: 9) {
                        StatusDot(color: container.status.dotColor(store.palette), size: 7)
                        Text(container.name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(store.palette.text).lineLimit(1)
                        Spacer(minLength: 0)
                        Text("\(container.cpuPercent, specifier: "%.1f")%").font(.system(size: 11)).monospacedDigit().foregroundStyle(store.palette.text3)
                        Glyph(glyph: container.isRunning ? .pause : .play, size: 11, color: store.palette.text2)
                            .frame(width: 26, height: 22)
                            .contentShape(Rectangle())
                            .onTapGesture { store.toggle(container) }
                    }
                    .padding(.horizontal, 9).padding(.vertical, 7)
                }
                if overflow > 0 {
                    Button { NSApp.activate(ignoringOtherApps: true) } label: {
                        Text("+\(overflow) more in Dory")
                            .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(store.palette.accentText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 9).padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
        }
        .frame(maxHeight: 260)
    }
```
Use the real `Container` running accessor: the existing row already uses `container.isRunning` — reuse it. If `Container` exposes running differently, match the existing `container.isRunning` usage already in this file (it is used at the play/pause glyph). Do not invent a new property.

- [ ] **Step 2: Build**

Run: `scripts/build.sh`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Visual check (best-effort)**

Run: `scripts/shots.sh` (best-effort; the menu-bar popover may not be snapshot-reachable — note if so, build is the gate).

- [ ] **Step 4: Commit**

```bash
git add Dory/Features/MenuBar/MenuBarContentView.swift
git commit -m "feat(menubar): running-first ordering + capped list with overflow row"
```

---

## Self-review notes (addressed)

- **Spec coverage (WS2 §3/§39-44):** mock-flash on volumes/networks/machines (L1), missing/wrong empty states (L2 — Networks was the remaining mislabel; Volumes/Images/Containers/Compose/K8s already branch correctly), menu-bar flat list contradicting its header (L3). The `engineRunning=false` seed and containers/images/pods de-mock were already done in WS1.
- **Type consistency:** `TableEmptyState(glyph:title:message:…)` matches `VolumesView`'s usage; `container.isRunning`, `container.status.dotColor`, `store.runningCount` are all already used in the touched files. L3 reuses the exact existing row layout.
- **Safety:** L1 Step 2 explicitly verifies the reload reassigns each de-mocked collection before trusting the change; if not, the implementer stops and reports.
- Build/snapshot-verified (no unit tests — seed + view-layer changes).
