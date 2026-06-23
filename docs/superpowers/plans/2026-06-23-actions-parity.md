# Actions Parity & Honest Detail Implementation Plan (WS5, scoped)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** No destructive action runs without a confirm; the CPU sparkline reflects real activity (honest when idle); logs auto-scroll and are copyable.

**Architecture:** A pure `ContainerStatsFormat` (sparkline + logs-text helpers) backs an honest `ContainerDetailView` stats/logs rework; the established `confirmationDialog` pattern is applied to the unprotected image/volume/network destructive ops.

**Tech Stack:** Swift 6 / SwiftUI / macOS; Swift `Testing`.

## Global Constraints

- Build ONLY with `scripts/build.sh`; test ONLY with `scripts/test.sh` (Xcode 27 beta `DEVELOPER_DIR`). Never call `xcodebuild` directly. Minutes per run.
- Synchronized Xcode folders — new `.swift` files auto-include; do NOT edit `Dory.xcodeproj/project.pbxproj`.
- IGNORE SourceKit/IDE diagnostics — false positives. `scripts/build.sh`/`scripts/test.sh` are authoritative.
- No inline comments; no docstrings. Self-documenting names. Colors via `Environment(\.palette)`. Tests use Swift `Testing`.
- Confirmations reuse the existing `.confirmationDialog(...)` pattern already used by container/machine delete.

---

### Task S1: Honest container detail (stats + logs)

**Files:**
- Create: `Dory/Features/Containers/ContainerStatsFormat.swift`
- Modify: `Dory/Features/Containers/ContainerDetailView.swift` (`sparkData`, the `stats` view, the `logs` view)
- Test: `DoryTests/ContainerStatsFormatTests.swift`

**Interfaces:**
- Consumes: `LogLine` (`Models.swift` — has `timestamp: String`, `level` with `.rawValue`, `message: String`).
- Produces: `enum ContainerStatsFormat { static func cpuSparkBars(_ history: [Double]) -> [Double]; static func logsPlainText(_ lines: [LogLine]) -> String }`.

- [ ] **Step 1: Write the failing test**

`DoryTests/ContainerStatsFormatTests.swift`:
```swift
import Testing
@testable import Dory

struct ContainerStatsFormatTests {
    @Test func emptyHistoryYieldsNoBars() {
        #expect(ContainerStatsFormat.cpuSparkBars([]).isEmpty)
    }

    @Test func idleHistoryHasNoFabricatedFloor() {
        #expect(ContainerStatsFormat.cpuSparkBars([0, 0, 0]) == [0, 0, 0])
    }

    @Test func scalesAndClamps() {
        #expect(ContainerStatsFormat.cpuSparkBars([10, 20]) == [50, 100])
        #expect(ContainerStatsFormat.cpuSparkBars([50]) == [100])
    }

    @Test func logsPlainTextJoinsLines() {
        let lines = [
            LogLine(timestamp: "12:00", level: .info, message: "started"),
            LogLine(timestamp: "12:01", level: .error, message: "boom"),
        ]
        #expect(ContainerStatsFormat.logsPlainText(lines) == "12:00 INFO started\n12:01 ERROR boom")
    }

    @Test func logsPlainTextEmpty() {
        #expect(ContainerStatsFormat.logsPlainText([]) == "")
    }
}
```
NOTE: the `LogLine(...)` initializer and the `LogLevel` cases (`.info`/`.error`) + their `.rawValue` ("INFO"/"ERROR") must match the real types in `Models.swift`. Read `Models.swift` for the exact `LogLine` fields and `level.rawValue` values; adjust the FIXTURE (not the type) so the expected `logsPlainText` string matches the real `rawValue` casing.

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test.sh -only-testing:DoryTests/ContainerStatsFormatTests`
Expected: FAIL — `ContainerStatsFormat` not found.

- [ ] **Step 3: Implement the helper**

`Dory/Features/Containers/ContainerStatsFormat.swift`:
```swift
import Foundation

enum ContainerStatsFormat {
    static func cpuSparkBars(_ history: [Double]) -> [Double] {
        history.map { min(100, max(0, $0 * 5)) }
    }

    static func logsPlainText(_ lines: [LogLine]) -> String {
        lines.map { "\($0.timestamp) \($0.level.rawValue) \($0.message)" }.joined(separator: "\n")
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/test.sh -only-testing:DoryTests/ContainerStatsFormatTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Wire the honest stats into ContainerDetailView**

In `Dory/Features/Containers/ContainerDetailView.swift`:
- Replace the `sparkData` computed property:
```swift
    private var sparkData: [Double] { ContainerStatsFormat.cpuSparkBars(cpuHistory) }
```
- In the `stats` view, replace the `SparkBars(...)` block so it shows a "Collecting CPU…" placeholder until there is history:
```swift
            VStack(spacing: 8) {
                Group {
                    if cpuHistory.isEmpty {
                        Text("Collecting CPU…").font(.system(size: 11)).foregroundStyle(p.text3)
                            .frame(maxWidth: .infinity, minHeight: 84)
                    } else {
                        SparkBars(heights: sparkData, tint: p.accent).frame(height: 84)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity)
                .background(p.bgElevated, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(p.border))
                Text("CPU usage · last 60s").font(.system(size: 11)).foregroundStyle(p.text3)
                    .frame(maxWidth: .infinity)
            }
```

- [ ] **Step 6: Wire logs auto-scroll + copy**

In the `logs` view, wrap the line list in a `ScrollViewReader` and add a small header with a "Copy" button. Replace the `logs` view body with:
```swift
    private var logs: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("OUTPUT").font(.system(size: 10.5, weight: .bold)).tracking(0.5).foregroundStyle(p.text3)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(ContainerStatsFormat.logsPlainText(logLines), forType: .string)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.doc").font(.system(size: 10))
                        Text("Copy").font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(p.text3)
                }
                .buttonStyle(.plain)
                .disabled(logLines.isEmpty)
            }
            ScrollViewReader { proxy in
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(logLines) { line in
                        HStack(spacing: 6) {
                            Text(line.timestamp).foregroundStyle(Color(hex: 0x5B6070))
                            Text(line.level.rawValue).font(.mono(11.5, weight: .bold)).foregroundStyle(line.level.color(p))
                            Text(line.message).foregroundStyle(p.monoText)
                            Spacer(minLength: 0)
                        }
                        .font(.mono(11.5)).lineLimit(1).padding(.vertical, 1.5)
                        .id(line.id)
                    }
                    HStack(spacing: 6) {
                        Text("$").foregroundStyle(p.green)
                        BlinkingCursor()
                    }
                    .font(.mono(11.5)).padding(.top, 2).id("logs-cursor")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(13)
                .background(p.monoBg, in: RoundedRectangle(cornerRadius: 10))
                .onChange(of: logLines.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("logs-cursor", anchor: .bottom) }
                }
            }
        }
    }
```
(`LogLine` is `Identifiable` — it is already used in a `ForEach(logLines)` without an explicit id, so it has an `id`. If the build complains that `line.id` is ambiguous, the existing `ForEach` proves `Identifiable`; keep `.id(line.id)`.)

- [ ] **Step 7: Build + visual check**

Run: `scripts/build.sh`
Expected: `BUILD SUCCEEDED`. Fix any `LogLine`/`LogLevel` mismatch until green.
Run: `scripts/shots.sh` (best-effort) — confirm the Stats and Logs tabs render (the "Collecting CPU…" state, the Copy button).

- [ ] **Step 8: Commit**

```bash
git add Dory/Features/Containers/ContainerStatsFormat.swift Dory/Features/Containers/ContainerDetailView.swift DoryTests/ContainerStatsFormatTests.swift
git commit -m "feat(containers): honest CPU sparkline + logs auto-scroll & copy"
```

---

### Task S2: Confirm destructive image/volume/network ops

**Files:**
- Modify: `Dory/Features/Tables/ImagesView.swift`, `Dory/Features/Tables/VolumesView.swift`, `Dory/Features/Tables/NetworksView.swift`

**Interfaces:**
- Consumes: existing store actions `removeImage(_:)`, `deleteVolume(_:)`, `pruneVolumes()`, `deleteNetwork(_:)`, `pruneNetworks()`.

This is a build-verified UI task — apply the SAME `confirmationDialog` pattern container/machine delete already use (`ImagesView` already does it for `confirmingPrune`). For each unprotected destructive call, route the button through a confirm.

- [ ] **Step 1: Images — confirm delete**

In `Dory/Features/Tables/ImagesView.swift`:
- Add `@State private var pendingDeleteImage: DockerImage?` to `ImageRow` (or to `ImagesView` and pass down — `ImageRow` is the natural owner since it has the image).
- Change BOTH the row trash `IconButton(systemImage: "trash", …) { store.removeImage(image) }` and the context-menu `Button("Delete Image", role: .destructive) { store.removeImage(image) }` to set `pendingDeleteImage = image` instead of calling `removeImage` directly.
- Add to `ImageRow`'s body: `.confirmationDialog("Delete \(image.repository):\(image.tag)?", isPresented: Binding(get: { pendingDeleteImage != nil }, set: { if !$0 { pendingDeleteImage = nil } }), titleVisibility: .visible) { Button("Delete", role: .destructive) { if let img = pendingDeleteImage { store.removeImage(img) } }; Button("Cancel", role: .cancel) {} } message: { Text("This permanently removes the image. This cannot be undone.") }`. (Since `ImageRow` has a single `image`, a simple `@State private var confirmingDelete = false` + a guard works too — either is fine; keep it minimal and consistent with the file's existing `confirmingPrune` style.)

- [ ] **Step 2: Volumes — confirm delete + prune**

In `Dory/Features/Tables/VolumesView.swift`:
- Add `@State private var pendingDeleteVolume: Volume?` and `@State private var confirmingPruneVolumes = false`.
- Change `Button("Delete Volume", role: .destructive) { store.deleteVolume(volume) }` → set `pendingDeleteVolume = volume`.
- Change `Button("Prune unused volumes") { store.pruneVolumes() }` → set `confirmingPruneVolumes = true`.
- Add two `.confirmationDialog`s: delete ("Delete volume \(volume.name)? … permanently removes the volume and its data. This cannot be undone." → `store.deleteVolume`), and prune ("Prune unused volumes? Removes volumes not used by any container. This cannot be undone." → `store.pruneVolumes`). Match the file's structure (the `presenting:`/`isPresented:` form, the existing context-menu placement).

- [ ] **Step 3: Networks — confirm delete + prune**

In `Dory/Features/Tables/NetworksView.swift`:
- Add `@State private var pendingDeleteNetwork: DoryNetwork?` and `@State private var confirmingPruneNetworks = false`.
- Change `Button("Delete Network", role: .destructive) { store.deleteNetwork(network) }` → set `pendingDeleteNetwork = network`.
- Change `Button("Prune unused networks") { store.pruneNetworks() }` → set `confirmingPruneNetworks = true`.
- Add the two `.confirmationDialog`s (delete: "Delete network \(network.name)? … This cannot be undone." → `store.deleteNetwork`; prune: "Prune unused networks? … This cannot be undone." → `store.pruneNetworks`).

- [ ] **Step 4: Build + visual check**

Run: `scripts/build.sh`
Expected: `BUILD SUCCEEDED`. (Note the real struct/field names: `Volume.name`, `DoryNetwork.name` — read each view/model to confirm before referencing.)
Run: `scripts/shots.sh` (best-effort) — confirm Images/Volumes/Networks still render.

- [ ] **Step 5: Commit**

```bash
git add Dory/Features/Tables/ImagesView.swift Dory/Features/Tables/VolumesView.swift Dory/Features/Tables/NetworksView.swift
git commit -m "feat(tables): confirm destructive image/volume/network delete + prune"
```

---

## Self-review notes (addressed)

- **Spec coverage:** honest stats + logs auto-scroll/copy (S1, with the `ContainerStatsFormat` pure helpers tested), and confirmations on every unprotected destructive op — image delete, volume delete + prune, network delete + prune (S2).
- **Type consistency:** `ContainerStatsFormat.cpuSparkBars`/`logsPlainText` defined once and consumed by `ContainerDetailView`; the confirm states are per-view-local.
- **Real type names flagged:** S1 Step 1 and S2 Step 4 both instruct reading `Models.swift`/the views for the exact `LogLine`/`LogLevel.rawValue`, `Volume`, `DoryNetwork` field names before finalizing the fixtures/dialog strings.
- Non-goals: logs virtualization/search, volume browser get-data-out, k8s/compose actions, create-sheet redesign, undo.
