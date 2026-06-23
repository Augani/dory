# Native Settings + Honest Resources Implementation Plan (WS6, scoped)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the macOS idioms right — ⌘, opens a native Settings window — and stop the Resources tab from faking an adjustable slider for a setting that isn't tunable.

**Architecture:** Add a standard `Settings { … }` scene to `DoryApp` hosting the existing `SettingsView` (so ⌘, + the App-menu "Settings…" work, in addition to the in-app sidebar tab). Replace the Resources tab's non-interactive slider-with-thumb (which implies draggable limits) with an honest read-only meter.

**Design rationale / non-goals:** The audit's WS6 also proposed a full `NavigationSplitView` shell rewrite; the custom shell was already polished in WS1 and rewriting it is high-risk for marginal gain, so it is an explicit **non-goal**. `launchAtLogin` (SMAppService) and `autoUpdate` (`DoryUpdater`) are already wired — no change. Onboarding works (advances on engine-running) — out of scope. Sparkle auto-update plumbing is deployment infra, not redesign.

**Tech Stack:** Swift 6 / SwiftUI / macOS.

## Global Constraints

- Build ONLY with `scripts/build.sh`; test ONLY with `scripts/test.sh` (Xcode 27 beta `DEVELOPER_DIR`). Never call `xcodebuild` directly. Minutes per run.
- Synchronized Xcode folders — no `Dory.xcodeproj/project.pbxproj` edits.
- IGNORE SourceKit/IDE diagnostics — false positives. `scripts/build.sh` (`BUILD SUCCEEDED`) is the authoritative gate.
- No inline comments; no docstrings. Colors via `Environment(\.palette)`.
- This is a build/snapshot-verified UI cycle (no new unit tests — the changes are scene wiring + a read-only view).

---

### Task N1: Native Settings scene + honest Resources meter

**Files:**
- Modify: `Dory/DoryApp.swift` (add the `Settings { … }` scene), `Dory/Features/Settings/SettingsView.swift` (replace `settingsSlider` with a read-only meter in the `resources` view)

**Interfaces:**
- Consumes: `SettingsView` (existing), `store.palette`, `ThinBar` (existing read-only meter in `Dory/DesignSystem/Components.swift`).

- [ ] **Step 1: Add the native Settings scene**

In `Dory/DoryApp.swift`, add a `Settings` scene to the `some Scene` body (alongside the existing `WindowGroup`(s) and `MenuBarExtra`), injecting the store + palette exactly as the main scene does (`.environment(store)` + `.environment(\.palette, store.palette)`):
```swift
        Settings {
            SettingsView()
                .environment(store)
                .environment(\.palette, store.palette)
                .frame(width: 720, height: 560)
        }
```
This gives ⌘, and the App-menu "Settings…" item, opening a native window with the existing settings UI. The in-app sidebar Settings tab is unchanged (both render `SettingsView`).

- [ ] **Step 2: Replace the fake slider with an honest read-only meter**

In `Dory/Features/Settings/SettingsView.swift`, the `resources` view calls `settingsSlider(label, value, fraction)` which renders a draggable-looking thumb over a track with NO interaction (misleading). Replace the `settingsSlider(_:_:_:)` helper with a `resourceMeter(_:_:_:)` that shows the label + value + a non-interactive `ThinBar` (no thumb), and update the two call sites in `resources`:
```swift
    private var resources: some View {
        let cores = ProcessInfo.processInfo.processorCount
        let ramGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        return VStack(alignment: .leading, spacing: 20) {
            groupLabel("THIS MAC")
            resourceMeter("CPU cores", "Engine uses up to 4 of \(cores) cores", min(1, 4.0 / Double(max(cores, 1))))
            resourceMeter("Memory", String(format: "%.0f GB installed · grows on demand", ramGB), min(1, 4.0 / max(ramGB, 1)))
            infoPanel("Dory's engine uses up to 4 CPU cores and allocates memory on demand — it reclaims RAM back to macOS when idle instead of holding a fixed reservation, so there are no manual limits to tune.")
        }
    }

    private func resourceMeter(_ label: String, _ value: String, _ fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(label).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(p.text)
                Spacer()
                Text(value).font(.system(size: 12.5, weight: .bold)).monospacedDigit().foregroundStyle(p.accentText)
            }
            ThinBar(fraction: fraction, tint: p.accent, height: 6)
        }
    }
```
Delete the old `settingsSlider(_:_:_:)` function (the `GeometryReader` + `Circle()` thumb). `ThinBar(fraction:tint:height:)` is the existing read-only meter from `Dory/DesignSystem/Components.swift` (used in the container stats), so it reads as a meter, not a control.

- [ ] **Step 3: Build**

Run: `scripts/build.sh`
Expected: `BUILD SUCCEEDED`. (`Settings` scene compiles; `ThinBar` signature is `ThinBar(fraction:tint:height:)` — confirm against `Components.swift` and match it.)

- [ ] **Step 4: Visual check**

Run: `scripts/shots.sh` (best-effort). Confirm the Settings → Resources tab shows the honest read-only meters (no draggable thumb). The native ⌘, Settings window opens by user action (not snapshot-reachable) — build is the gate for the scene.

- [ ] **Step 5: Commit**

```bash
git add Dory/DoryApp.swift Dory/Features/Settings/SettingsView.swift
git commit -m "feat(settings): native Settings scene (⌘,) + honest read-only Resources meter"
```

---

## Self-review notes (addressed)

- **Scope coverage:** native `Settings{}` scene (⌘,) + honest Resources meter (the two real WS6 gaps). The full shell rewrite, onboarding polish, and Sparkle auto-update are explicitly out of scope per the design rationale (already wired / high-risk / deployment infra).
- **Type consistency:** `resourceMeter` replaces `settingsSlider`; `ThinBar(fraction:tint:height:)` reused (confirm its exact signature in `Components.swift` at build time). The Settings scene injects store + palette like every other scene in `DoryApp`.
- Build/snapshot-verified (no unit tests — pure scene + read-only view changes).
