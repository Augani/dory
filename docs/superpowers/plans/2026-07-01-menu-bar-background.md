# Menu-Bar-Only Background Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** Make Dory a menu-bar-only agent app (no Dock icon) whose engine keeps running when the window closes, while a clean Quit still restores the docker context.

**Architecture:** Set `INFOPLIST_KEY_LSUIElement = YES` in both app-target build configs so macOS launches Dory as an accessory (menu-bar) app; a minimal `NSApplicationDelegateAdaptor` reasserts `.accessory` at launch and opens the main window only on first-launch/onboarding. The menu-bar `MenuBarExtra` becomes the always-present entry point; "Open Dory" and ⌘Q route through SwiftUI `openWindow` and `NSApp.terminate`, and the existing `willTerminateNotification` handler in `ContentView` continues to restore the docker context.

**Tech Stack:** SwiftUI (macOS), AppKit (`NSApplication`, `NSApplicationDelegateAdaptor`), `@Observable @MainActor AppStore`, Swift Testing (`@Test`/`#expect`), Xcode build via `scripts/build.sh`, tests via `scripts/test.sh`.

## Sequencing

Global execution order across the three related plans:

1. **menu-bar-background (A) — THIS PLAN — executed FIRST.**
2. host-bridge (B) — builds on A.
3. credential-bootstrap (C) — builds on A and B.

This plan is executed first; plans B and C rebase their edits to shared files on top of the edits made here. The shared files across the three plans are `Dory/Models/AppStore.swift`, `Dory/Runtime/Machines/MachineService.swift`, `Dory/Runtime/Machines/MachineProvisioner.swift`, and `Dory/Features/Settings/SettingsView.swift`. Edits made by THIS plan that later plans rebase on:

- `Dory/Models/AppStore.swift` — this plan adds `isAgentMode`, `shouldOpenWindowOnLaunch`, force-on logic in `setShowMenuBarIcon`, and an `if isAgentMode { showMenuBarIcon = true }` line in the `init`/`realLaunch` load block (~line 112). Plans B and C add code near the same load block and after `setShowMenuBarIcon`.
- `Dory/Features/Settings/SettingsView.swift` — this plan changes the `toggleRow` helper signature (adds a `disabled: Bool = false` parameter). Plans B and C add new rows/sections and MUST rebase on the new `toggleRow` signature.

## Global Constraints
- Menu bar icon is **always present** in this mode (the `showMenuBarIcon` toggle is forced on / hidden, else the app becomes unreachable).
- On first launch or when onboarding is required, open the main window; otherwise start windowless in the menu bar.
- Closing the window keeps the app + engine running (agent app doesn't terminate on last window close).
- Quit is via the menu bar "Quit Dory" / ⌘Q → `NSApp.terminate` → existing `willTerminateNotification` handler restores the docker context (`DockerContext.deactivateSync`).
- Engine/shim/port-forwarder/bridge lifecycles are unchanged (already independent of window state).
- Set `INFOPLIST_KEY_LSUIElement = YES` in **both** build configs via a text edit to `Dory.xcodeproj/project.pbxproj`; do NOT open the Xcode 27 GUI — it re-bumps objectVersion 77→110 and breaks CI. pbxproj edits are CLI/text edits only.
- SwiftUI macOS app, `@Observable` AppStore, Environment-based DI, NO ViewModels. NO line comments; no docstrings except public API.
- Build via `scripts/build.sh` (auto-detects Xcode; `DEVELOPER_DIR` override). Swift Testing run via `scripts/test.sh`.
- New files under `Dory/` and `DoryTests/` are auto-discovered by the project's `PBXFileSystemSynchronizedRootGroup` — do NOT add file references to `project.pbxproj` for new source/test files; only edit build settings.
- Work happens on the existing git branch `feat/host-bridge`; commit frequently.

---

## File Structure

| File | Responsibility |
| --- | --- |
| `Dory/App/AppDelegate.swift` | **New.** Minimal `NSApplicationDelegate` that forces `.accessory` activation policy at launch and keeps the app alive after the last window closes. |
| `Dory/Models/AppStore.swift` | **Modify.** Add `isAgentMode` (reads `LSUIElement`) and force `showMenuBarIcon` on in agent mode inside `setShowMenuBarIcon` and initial load; add `shouldOpenWindowOnLaunch`. |
| `Dory/DoryApp.swift` | **Modify.** Attach `@NSApplicationDelegateAdaptor`; give the main `WindowGroup` a stable id; open it on launch only when `shouldOpenWindowOnLaunch`. |
| `Dory/App/DoryCommands.swift` | **Modify.** Add an "Open Dory" command that uses `openWindow` to show/focus the main window. |
| `Dory/Features/MenuBar/MenuBarContentView.swift` | **Modify.** "Open Dory" footer button uses `openWindow(id:)` instead of `NSApp.activate`. |
| `Dory/Features/Settings/SettingsView.swift` | **Modify.** Disable the "Show menu bar icon" toggle when `isAgentMode` and explain why. |
| `Dory.xcodeproj/project.pbxproj` | **Modify.** Add `INFOPLIST_KEY_LSUIElement = YES;` to both app-target build configs (Debug + Release). Text edit only. |
| `DoryTests/AgentModeTests.swift` | **New.** Swift Testing unit tests for the forced-menu-bar-icon rule and window-open-on-launch rule. |
| `DoryTests/LSUIElementBuildSettingTests.swift` | **New.** Swift Testing test asserting both app-target configs carry `INFOPLIST_KEY_LSUIElement = YES` in `project.pbxproj`. |

---

### Task 1: LSUIElement build setting in both configs

**Files:**
- Modify `Dory.xcodeproj/project.pbxproj` (Debug app config block starting at line 377 `3E705D0F… Debug configuration for … "Dory"`; Release app config block starting at line 413 `3E705D10… Release configuration for … "Dory"`).
- Create `DoryTests/LSUIElementBuildSettingTests.swift`.

**Interfaces:**
- Consumes: nothing.
- Produces (build-setting contract, consumable by Component 1/3 plans and packaging): the `Dory` app target sets `INFOPLIST_KEY_LSUIElement = YES;` in both `Debug` and `Release` `XCBuildConfiguration` blocks, so `GENERATE_INFOPLIST_FILE = YES` emits `LSUIElement = true` into `Info.plist`.

**Steps:**
- [ ] Create the failing test `DoryTests/LSUIElementBuildSettingTests.swift` with this COMPLETE content:
  ```swift
  import Testing
  import Foundation

  struct LSUIElementBuildSettingTests {
      private func pbxproj() throws -> String {
          let here = URL(fileURLWithPath: #filePath)
          let root = here.deletingLastPathComponent().deletingLastPathComponent()
          let path = root.appendingPathComponent("Dory.xcodeproj/project.pbxproj")
          return try String(contentsOf: path, encoding: .utf8)
      }

      @Test func appTargetConfigsSetLSUIElement() throws {
          let text = try pbxproj()
          let occurrences = text.components(separatedBy: "INFOPLIST_KEY_LSUIElement = YES;").count - 1
          #expect(occurrences >= 2)
      }
  }
  ```
- [ ] Run the test: `DEVELOPER_DIR="$(xcode-select -p)" scripts/test.sh -only-testing:DoryTests/LSUIElementBuildSettingTests`. Expected FAIL with: `Expectation failed: (occurrences → 0) >= 2`.
- [ ] Apply the setting to the Debug app config: in `Dory.xcodeproj/project.pbxproj`, inside the block `3E705D0F2FE37C7B0094B33C /* Debug configuration for PBXNativeTarget "Dory" */`, insert `INFOPLIST_KEY_LSUIElement = YES;` immediately before the existing line `INFOPLIST_KEY_NSHumanReadableCopyright = "";` (currently line 394), so the two consecutive lines read:
  ```
  				INFOPLIST_KEY_LSUIElement = YES;
  				INFOPLIST_KEY_NSHumanReadableCopyright = "";
  ```
- [ ] Apply the setting to the Release app config: in the same file, inside the block `3E705D102FE37C7B0094B33C /* Release configuration for PBXNativeTarget "Dory" */`, insert `INFOPLIST_KEY_LSUIElement = YES;` immediately before the existing line `INFOPLIST_KEY_NSHumanReadableCopyright = "";` (currently line 429), so the two consecutive lines read:
  ```
  				INFOPLIST_KEY_LSUIElement = YES;
  				INFOPLIST_KEY_NSHumanReadableCopyright = "";
  ```
- [ ] Verify the project still parses (do NOT open the GUI): run `plutil -lint Dory.xcodeproj/project.pbxproj`. Expected output ends with `OK`.
- [ ] Run the test: `DEVELOPER_DIR="$(xcode-select -p)" scripts/test.sh -only-testing:DoryTests/LSUIElementBuildSettingTests`. Expected PASS.
- [ ] Commit: `git add Dory.xcodeproj/project.pbxproj DoryTests/LSUIElementBuildSettingTests.swift && git commit -m "feat(background): set LSUIElement=YES in both Dory build configs"`

---

### Task 2: AppStore agent-mode rule + forced menu-bar icon

**Files:**
- Modify `Dory/Models/AppStore.swift` (add `isAgentMode` and `shouldOpenWindowOnLaunch` computed properties; force-on logic in `setShowMenuBarIcon` at lines 248-251 and in `init` load at line 112).
- Create `DoryTests/AgentModeTests.swift`.

**Interfaces:**
- Consumes: `Bundle.main.object(forInfoDictionaryKey: "LSUIElement")` (build-setting contract from Task 1), `AppStore.onboarding: Bool`.
- Produces (consumable by DoryApp, DoryCommands, SettingsView, and later plans):
  - `var isAgentMode: Bool` (true when the bundle's `LSUIElement` is truthy).
  - `func setShowMenuBarIcon(_ on: Bool)` — when `isAgentMode`, forces `showMenuBarIcon = true` regardless of `on`.
  - `var shouldOpenWindowOnLaunch: Bool` — true when `!isAgentMode || onboarding`.

**Steps:**
- [ ] Create the failing test `DoryTests/AgentModeTests.swift` with this COMPLETE content:
  ```swift
  import Testing
  @testable import Dory

  @MainActor
  struct AgentModeTests {
      @Test func setShowMenuBarIconForcesOnInAgentMode() {
          let store = AppStore()
          guard store.isAgentMode else { return }
          store.setShowMenuBarIcon(false)
          #expect(store.showMenuBarIcon == true)
      }

      @Test func windowOpensOnLaunchWhenOnboarding() {
          let store = AppStore()
          store.onboarding = true
          #expect(store.shouldOpenWindowOnLaunch == true)
      }

      @Test func windowSuppressedOnLaunchInAgentModeWhenNotOnboarding() {
          let store = AppStore()
          store.onboarding = false
          #expect(store.shouldOpenWindowOnLaunch == !store.isAgentMode)
      }
  }
  ```
- [ ] Run the test: `DEVELOPER_DIR="$(xcode-select -p)" scripts/test.sh -only-testing:DoryTests/AgentModeTests`. Expected FAIL with: `Value of type 'AppStore' has no member 'isAgentMode'` (compile error).
- [ ] Add the `isAgentMode` property to `AppStore`. In `Dory/Models/AppStore.swift`, immediately after the `var palette: DoryPalette { appearance.palette }` line (currently line 258), insert:
  ```swift
  var isAgentMode: Bool {
      if let value = Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? Bool { return value }
      if let number = Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? NSNumber { return number.boolValue }
      if let string = Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? String { return string == "1" || string.lowercased() == "true" || string.lowercased() == "yes" }
      return false
  }

  var shouldOpenWindowOnLaunch: Bool { !isAgentMode || onboarding }
  ```
- [ ] Force the icon on in `setShowMenuBarIcon`. In `Dory/Models/AppStore.swift`, replace the body of `setShowMenuBarIcon` (currently lines 248-251) so it reads:
  ```swift
  func setShowMenuBarIcon(_ on: Bool) {
      showMenuBarIcon = isAgentMode ? true : on
      UserDefaults.standard.set(showMenuBarIcon, forKey: Self.menuBarIconKey)
  }
  ```
- [ ] Force the icon on when loading the persisted value in `init`. In `Dory/Models/AppStore.swift`, replace the line `if let v = UserDefaults.standard.object(forKey: Self.menuBarIconKey) as? Bool { showMenuBarIcon = v }` (currently line 112) with:
  ```swift
                  if let v = UserDefaults.standard.object(forKey: Self.menuBarIconKey) as? Bool { showMenuBarIcon = v }
                  if isAgentMode { showMenuBarIcon = true }
  ```
- [ ] Run the test: `DEVELOPER_DIR="$(xcode-select -p)" scripts/test.sh -only-testing:DoryTests/AgentModeTests`. Expected PASS.
- [ ] Commit: `git add Dory/Models/AppStore.swift DoryTests/AgentModeTests.swift && git commit -m "feat(background): AppStore agent-mode rule forces menu-bar icon on"`

---

### Task 3: AppDelegate that pins .accessory and keeps the app alive

**Files:**
- Create `Dory/App/AppDelegate.swift`.

**Interfaces:**
- Consumes: `NSApplication`, `NSApplicationDelegate`.
- Produces (consumable by DoryApp Task 4):
  - `final class DoryAppDelegate: NSObject, NSApplicationDelegate`
  - `func applicationDidFinishLaunching(_ notification: Notification)` — calls `NSApp.setActivationPolicy(.accessory)`.
  - `func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool` — returns `false`.

**Steps:**
- [ ] Add a compile-guard failing test to `DoryTests/AgentModeTests.swift`. Append this `@Test` method inside the existing `AgentModeTests` struct (before its closing brace):
  ```swift
      @Test func appDelegateKeepsAppAliveAfterLastWindowCloses() {
          let delegate = DoryAppDelegate()
          #expect(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared) == false)
      }
  ```
- [ ] Add the AppKit import needed by the new test. At the top of `DoryTests/AgentModeTests.swift`, add `import AppKit` on the line after `import Testing`.
- [ ] Run the test: `DEVELOPER_DIR="$(xcode-select -p)" scripts/test.sh -only-testing:DoryTests/AgentModeTests/appDelegateKeepsAppAliveAfterLastWindowCloses`. Expected FAIL with: `Cannot find 'DoryAppDelegate' in scope` (compile error).
- [ ] Create `Dory/App/AppDelegate.swift` with this COMPLETE content:
  ```swift
  import AppKit

  final class DoryAppDelegate: NSObject, NSApplicationDelegate {
      func applicationDidFinishLaunching(_ notification: Notification) {
          NSApp.setActivationPolicy(.accessory)
      }

      func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
          false
      }
  }
  ```
- [ ] Run the test: `DEVELOPER_DIR="$(xcode-select -p)" scripts/test.sh -only-testing:DoryTests/AgentModeTests/appDelegateKeepsAppAliveAfterLastWindowCloses`. Expected PASS.
- [ ] Commit: `git add Dory/App/AppDelegate.swift DoryTests/AgentModeTests.swift && git commit -m "feat(background): add DoryAppDelegate pinning .accessory, no-terminate-on-close"`

---

### Task 4: Wire the delegate + main window id into DoryApp

**Files:**
- Modify `Dory/DoryApp.swift` (add adaptor at struct level near line 5; add `.id` to the main `WindowGroup` at line 14; open the window on launch based on `shouldOpenWindowOnLaunch`).

**Interfaces:**
- Consumes: `DoryAppDelegate` (Task 3), `AppStore.shouldOpenWindowOnLaunch` (Task 2), SwiftUI `openWindow`, `@Environment(\.openWindow)`.
- Produces (consumable by DoryCommands Task 5 and MenuBarContentView Task 6): the main window id constant `DoryApp.mainWindowID = "dory-main"`.

**Steps:**
- [ ] Add a failing test asserting the shared window-id constant. Append this `@Test` inside `AgentModeTests` in `DoryTests/AgentModeTests.swift` (before its closing brace):
  ```swift
      @Test func mainWindowIDIsStable() {
          #expect(DoryApp.mainWindowID == "dory-main")
      }
  ```
- [ ] Run the test: `DEVELOPER_DIR="$(xcode-select -p)" scripts/test.sh -only-testing:DoryTests/AgentModeTests/mainWindowIDIsStable`. Expected FAIL with: `Type 'DoryApp' has no member 'mainWindowID'` (compile error).
- [ ] Add the window-id constant and delegate adaptor to `DoryApp`. In `Dory/DoryApp.swift`, replace the lines from `struct DoryApp: App {` through `@State private var store = AppStore()` (currently lines 4-5) with:
  ```swift
  struct DoryApp: App {
      static let mainWindowID = "dory-main"

      @NSApplicationDelegateAdaptor(DoryAppDelegate.self) private var appDelegate
      @State private var store = AppStore()
  ```
- [ ] Give the main `WindowGroup` the stable id and drive first-launch opening. In `Dory/DoryApp.swift`, replace the main window scene block (currently lines 14-22):
  ```swift
          WindowGroup {
              RootView()
                  .environment(store)
          }
          .windowStyle(.hiddenTitleBar)
          .defaultSize(width: 1180, height: 766)
          .windowResizability(.contentMinSize)
          .commands { DoryCommands(store: store) }
  ```
  with:
  ```swift
          WindowGroup(id: Self.mainWindowID) {
              RootView()
                  .environment(store)
                  .modifier(LaunchWindowGate(store: store))
          }
          .windowStyle(.hiddenTitleBar)
          .defaultSize(width: 1180, height: 766)
          .windowResizability(.contentMinSize)
          .commands { DoryCommands(store: store) }
  ```
- [ ] Add the `LaunchWindowGate` modifier that closes the auto-restored window when it should start windowless. At the end of `Dory/DoryApp.swift` (after the closing brace of `struct DoryApp`), append:
  ```swift
  private struct LaunchWindowGate: ViewModifier {
      let store: AppStore
      @Environment(\.dismissWindow) private var dismissWindow

      func body(content: Content) -> some View {
          content.task {
              if !store.shouldOpenWindowOnLaunch {
                  dismissWindow(id: DoryApp.mainWindowID)
              }
          }
      }
  }
  ```
- [ ] Run the test: `DEVELOPER_DIR="$(xcode-select -p)" scripts/test.sh -only-testing:DoryTests/AgentModeTests/mainWindowIDIsStable`. Expected PASS.
- [ ] Build the whole app to confirm the scene edits compile: `DEVELOPER_DIR="$(xcode-select -p)" scripts/build.sh`. Expected: `** BUILD SUCCEEDED **`.
- [ ] Commit: `git add Dory/DoryApp.swift DoryTests/AgentModeTests.swift && git commit -m "feat(background): wire DoryAppDelegate + windowless launch gate into DoryApp"`

---

### Task 5: "Open Dory" menu command uses openWindow

**Files:**
- Modify `Dory/App/DoryCommands.swift` (add `@Environment(\.openWindow)` and an "Open Dory" button in the `CommandGroup(after: .toolbar)` block, lines 17-29).

**Interfaces:**
- Consumes: `DoryApp.mainWindowID` (Task 4), SwiftUI `@Environment(\.openWindow) openWindow`.
- Produces: a "Window > Open Dory" command (⌘0) that calls `openWindow(id: DoryApp.mainWindowID)`.

**Steps:**
- [ ] Add a failing test for a pure helper that decides the window id to open. Append this `@Test` inside `AgentModeTests` in `DoryTests/AgentModeTests.swift` (before its closing brace):
  ```swift
      @Test func openDoryTargetsMainWindow() {
          #expect(DoryCommands.openDoryWindowID == DoryApp.mainWindowID)
      }
  ```
- [ ] Run the test: `DEVELOPER_DIR="$(xcode-select -p)" scripts/test.sh -only-testing:DoryTests/AgentModeTests/openDoryTargetsMainWindow`. Expected FAIL with: `Type 'DoryCommands' has no member 'openDoryWindowID'` (compile error).
- [ ] Add the `openDoryWindowID` static constant and `openWindow` environment to `DoryCommands`. In `Dory/App/DoryCommands.swift`, replace the lines from `struct DoryCommands: Commands {` through `let store: AppStore` (currently lines 3-4) with:
  ```swift
  struct DoryCommands: Commands {
      static let openDoryWindowID = DoryApp.mainWindowID

      @Environment(\.openWindow) private var openWindow
      let store: AppStore
  ```
- [ ] Add the "Open Dory" button. In `Dory/App/DoryCommands.swift`, inside `CommandGroup(after: .toolbar)`, replace the existing line `Button("Filter") { if store.section != .settings { store.filterFocusToken += 1 } }` and its following `.keyboardShortcut("f", modifiers: .command)` and the `Divider()` (currently lines 26-28) with:
  ```swift
              Button("Filter") { if store.section != .settings { store.filterFocusToken += 1 } }
                  .keyboardShortcut("f", modifiers: .command)
              Divider()
              Button("Open Dory") { openWindow(id: Self.openDoryWindowID) }
                  .keyboardShortcut("0", modifiers: .command)
              Divider()
  ```
- [ ] Run the test: `DEVELOPER_DIR="$(xcode-select -p)" scripts/test.sh -only-testing:DoryTests/AgentModeTests/openDoryTargetsMainWindow`. Expected PASS.
- [ ] Commit: `git add Dory/App/DoryCommands.swift DoryTests/AgentModeTests.swift && git commit -m "feat(background): add ⌘0 Open Dory command via openWindow"`

---

### Task 6: Menu-bar "Open Dory" button opens/focuses the window

**Files:**
- Modify `Dory/Features/MenuBar/MenuBarContentView.swift` (add `@Environment(\.openWindow)`; change the footer "Open Dory" button action at lines 82-86, and the "+N more in Dory" overflow button at line 66).

**Interfaces:**
- Consumes: `DoryApp.mainWindowID` (Task 4), SwiftUI `@Environment(\.openWindow) openWindow`.
- Produces: menu-bar "Open Dory" and overflow buttons that call `openWindow(id: DoryApp.mainWindowID)` then `NSApp.activate(ignoringOtherApps: true)`.

**Steps:**
- [ ] Add the `openWindow` environment to `MenuBarContentView`. In `Dory/Features/MenuBar/MenuBarContentView.swift`, replace the lines from `struct MenuBarContentView: View {` through `@Environment(\.palette) private var p` (currently lines 3-5) with:
  ```swift
  struct MenuBarContentView: View {
      @Environment(AppStore.self) private var store
      @Environment(\.palette) private var p
      @Environment(\.openWindow) private var openWindow

      private func showMainWindow() {
          openWindow(id: DoryApp.mainWindowID)
          NSApp.activate(ignoringOtherApps: true)
      }
  ```
- [ ] Point the footer "Open Dory" button at the window. In `Dory/Features/MenuBar/MenuBarContentView.swift`, replace the line `Button { NSApp.activate(ignoringOtherApps: true) } label: {` inside `footer` (currently line 82) with:
  ```swift
              Button { showMainWindow() } label: {
  ```
- [ ] Point the overflow "+N more in Dory" button at the window. In `Dory/Features/MenuBar/MenuBarContentView.swift`, replace the line `Button { NSApp.activate(ignoringOtherApps: true) } label: {` inside `list` (currently line 66) with:
  ```swift
                  Button { showMainWindow() } label: {
  ```
- [ ] Build the whole app to confirm the two edits resolve `NSApp` and the new environment: `DEVELOPER_DIR="$(xcode-select -p)" scripts/build.sh`. Expected: `** BUILD SUCCEEDED **`.
- [ ] Commit: `git add Dory/Features/MenuBar/MenuBarContentView.swift && git commit -m "feat(background): menu-bar Open Dory opens/focuses the main window"`

---

### Task 7: Disable the menu-bar-icon toggle in SettingsView under agent mode

**Files:**
- Modify `Dory/Features/Settings/SettingsView.swift` (the `toggleRow` for "Show menu bar icon" at line 197 and the private `toggleRow` helper at lines 273-284).

**Interfaces:**
- Consumes: `AppStore.isAgentMode` (Task 2).
- Produces: `private func toggleRow(_ title: String, _ subtitle: String, isOn: Binding<Bool>, divider: Bool, disabled: Bool = false)` — the menu-bar row passes `disabled: store.isAgentMode` and shows a "Always on in background mode" subtitle.

**Steps:**
- [ ] Add a `disabled` parameter to the `toggleRow` helper. In `Dory/Features/Settings/SettingsView.swift`, replace the helper signature line `private func toggleRow(_ title: String, _ subtitle: String, isOn: Binding<Bool>, divider: Bool) -> some View {` (currently line 273) with:
  ```swift
      private func toggleRow(_ title: String, _ subtitle: String, isOn: Binding<Bool>, divider: Bool, disabled: Bool = false) -> some View {
  ```
- [ ] Apply the disabled state and dim the row. In `Dory/Features/Settings/SettingsView.swift`, replace the closing modifiers of `toggleRow` (currently line 282) `.padding(.horizontal, 15).padding(.vertical, 13)` with:
  ```swift
          .padding(.horizontal, 15).padding(.vertical, 13)
          .opacity(disabled ? 0.55 : 1)
          .allowsHitTesting(!disabled)
  ```
- [ ] Wire the menu-bar-icon row to agent mode. In `Dory/Features/Settings/SettingsView.swift`, replace the "Show menu bar icon" row (currently line 197):
  ```swift
                  toggleRow("Show menu bar icon", "Quick access to containers from the menu bar.", isOn: Binding(get: { store.showMenuBarIcon }, set: { store.setShowMenuBarIcon($0) }), divider: true)
  ```
  with:
  ```swift
                  toggleRow("Show menu bar icon", store.isAgentMode ? "Always on — Dory runs in the menu bar in background mode." : "Quick access to containers from the menu bar.", isOn: Binding(get: { store.showMenuBarIcon }, set: { store.setShowMenuBarIcon($0) }), divider: true, disabled: store.isAgentMode)
  ```
- [ ] Build the whole app to confirm the settings edits compile: `DEVELOPER_DIR="$(xcode-select -p)" scripts/build.sh`. Expected: `** BUILD SUCCEEDED **`.
- [ ] Commit: `git add Dory/Features/Settings/SettingsView.swift && git commit -m "feat(background): disable menu-bar-icon toggle in agent mode"`

---

### Task 8: Full suite green + regression guard on docker-context restore

**Files:**
- No new source files. Reads `Dory/ContentView.swift` (the `willTerminateNotification` handler at lines 45-47) to confirm it is untouched.

**Interfaces:**
- Consumes: the whole feature (Tasks 1-7).
- Produces: a green full test run and a documented guarantee that `DockerContext.deactivateSync()` still runs on `NSApp.terminate`.

**Steps:**
- [ ] Confirm the terminate handler is still present and unmodified. Run `git grep -n "willTerminateNotification" Dory/ContentView.swift`. Expected output: `Dory/ContentView.swift:45:        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in`.
- [ ] Confirm the deactivate call is still present. Run `git grep -n "DockerContext.deactivateSync()" Dory/ContentView.swift`. Expected output: `Dory/ContentView.swift:46:            DockerContext.deactivateSync()`.
- [ ] Run the full Dory test suite: `DEVELOPER_DIR="$(xcode-select -p)" scripts/test.sh -only-testing:DoryTests`. Expected: `** TEST SUCCEEDED **`.
- [ ] Commit (no-op safeguard so the tree state is captured even if nothing changed): `git commit --allow-empty -m "test(background): full DoryTests suite green for agent mode"`

---

### Task 9: Manual verification checklist (window / quit / dock behavior)

**Files:**
- No file changes. This task is a human/agent runbook executed against a locally built, signed `Dory.app`.

**Interfaces:**
- Consumes: the built app from `scripts/build.sh`.
- Produces: recorded PASS/FAIL for each acceptance behavior from the spec's "Menu-bar mode" testing line.

**Steps:**
- [ ] Build a runnable app bundle: `DEVELOPER_DIR="$(xcode-select -p)" scripts/build.sh`. Expected: `** BUILD SUCCEEDED **`. Record the emitted `Dory.app` path.
- [ ] Reset first-run state so first-launch behavior is exercised: `defaults delete com.pythonxi.Dory dory.hasCompletedOnboarding 2>/dev/null; true`.
- [ ] Verify `LSUIElement` shipped in the built bundle: run `plutil -extract LSUIElement raw "$DORY_APP/Contents/Info.plist"` (substitute the recorded app path). Expected output: `true`.
- [ ] Launch the built `Dory.app` from Finder. Expected: onboarding/main window opens on this first launch AND no persistent Dock icon appears for a normal accessory app; the menu-bar fish icon is present. Record PASS/FAIL.
- [ ] Complete/skip onboarding, then quit and relaunch. Expected: on this second launch the app starts windowless (no main window auto-opens) and only the menu-bar icon is present. Record PASS/FAIL.
- [ ] Click the menu-bar icon, then click "Open Dory". Expected: the main window appears and comes to the front. Record PASS/FAIL.
- [ ] With the window already open, click "Open Dory" again. Expected: the existing window is focused (no duplicate window spawned). Record PASS/FAIL.
- [ ] Close the main window (red button / ⌘W). In a terminal run `docker ps`. Expected: the window is gone, the app is still running (menu-bar icon present), and `docker ps` still succeeds through Dory. Record PASS/FAIL.
- [ ] Quit via the menu-bar "Quit Dory" (or ⌘Q with the window focused). Then in a terminal run `docker context show`. Expected: the app terminates and the docker context is no longer `dory` (restored by `DockerContext.deactivateSync`); `docker context show` prints the pre-Dory context (e.g. `default`). Record PASS/FAIL.
- [ ] Commit the checklist outcome as an empty marker so the run is traceable: `git commit --allow-empty -m "test(background): manual window/quit/dock checklist recorded"`
