# Credential Bootstrap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** Give each Dory machine the user's curated shell secrets (default `ANTHROPIC_API_KEY`) and preinstall `gh`, `claude`, and `socat` so browser-based CLI logins and AI tooling work out of the box.

**Architecture:** A login-shell env probe (same `loginShell -lic` pattern as `DockerHostConflict.detect`) resolves a persisted allow-list of variable names to non-empty values, which `AppStore` merges into `MachineSettings.env` at machine creation so `MachineService.createBody` injects them via the container `Env`. `MachineProvisioner` gains a best-effort, per-`PackageManager` install script for `gh` / `claude` / `socat` that runs after identity setup and never fails machine creation. `SettingsView` surfaces an editable allow-list with an explicit "secrets are copied into machines" warning.

**Tech Stack:** Swift 6, SwiftUI (macOS), `@Observable @MainActor AppStore`, Environment-based DI (no ViewModels), Swift Testing (`@Test`/`#expect`), `Foundation.Process` via the existing `Shell` helper.

## Global Constraints
- Env propagation reuses the `loginShell -lic` probe pattern from `Dory/Runtime/Docker/DockerHostConflict.swift`; default allow-list is `["ANTHROPIC_API_KEY"]` with opt-in extras `["OPENAI_API_KEY","GH_TOKEN","HF_TOKEN"]` the user can edit.
- Resolved non-empty vars are injected into the machine via `MachineService.createBody`'s `Env` (the existing injection point through `MachineSettings.env`).
- Tool install lives in `MachineProvisioner`: best-effort, non-fatal, progress-reported; a failure logs a warning and does not fail machine creation.
- `gh` install branches per `MachineDistro.PackageManager` (apt/dnf/zypper/apk/pacman) with a release-tarball fallback; `claude` via the official installer with `npm i -g @anthropic-ai/claude-code` fallback when Node is present; also ensure `socat`.
- SwiftUI macOS app, `@Observable` AppStore, Environment-based DI, NO ViewModels. NO line comments; no docstrings except on public API.
- Build via `scripts/build.sh` (auto-detects Xcode; `DEVELOPER_DIR` override). NEVER open the Xcode GUI — it re-bumps project objectVersion 77→110 and breaks CI. Any pbxproj edits are CLI/text edits only.
- The Xcode project uses `PBXFileSystemSynchronizedRootGroup` for `Dory/` and `DoryTests/`; new `.swift` files added under those folders are auto-included — do NOT edit `project.pbxproj` to register new source or test files.
- Tests are Swift Testing (`@Test`/`#expect`) run via `scripts/test.sh`.
- Work happens on the existing git branch `feat/host-bridge`; commit frequently.
- Docker/machine engine is reached through the dory socket (`~/.dory/dory.sock`); machines are `dory-machine-<name>` containers.

---

## Sequencing

Global execution order across the three related plans:

1. menu-bar-background (A) — executed FIRST.
2. host-bridge (B) — builds on A.
3. **credential-bootstrap (C) — THIS PLAN — executed LAST.**

This plan MUST be executed AFTER both the menu-bar-background plan (`docs/superpowers/plans/2026-07-01-menu-bar-background.md`) and the host-bridge plan (`docs/superpowers/plans/2026-07-01-host-bridge.md`), and rebased on their edits. The shared files across the three plans are `Dory/Models/AppStore.swift`, `Dory/Runtime/Machines/MachineService.swift`, `Dory/Runtime/Machines/MachineProvisioner.swift`, and `Dory/Features/Settings/SettingsView.swift`. It shares these files with the prior plans:

- `Dory/Models/AppStore.swift` — menu-bar-background (A) adds `isAgentMode`/`shouldOpenWindowOnLaunch`, force-on logic in `setShowMenuBarIcon`, and an `if isAgentMode { showMenuBarIcon = true }` line in the `init`/`realLaunch` load block (~line 112); host-bridge (B) adds `HostBridge` start/stop, machine-bridge registration, and the persisted `openLoginsOnMac` state loaded in the same init block; this plan adds the env allow-list state, probe wiring, and injection into `createMachine`. Because BOTH A (line ~112) and B touch the init/realLaunch load block, this plan must rebase its load-line insertion there on top of A's and B's insertions.
- `Dory/Runtime/Machines/MachineService.swift` — host-bridge adds the `/opt/dory/bridge` bind and `BROWSER` env; this plan adds the resolved secret vars to `settings.env` (already flows through `createBody`, so no new `createBody` signature is needed here).
- `Dory/Runtime/Machines/MachineProvisioner.swift` — host-bridge adds `dory-open` install + symlinks and ensures `socat`; this plan adds `gh` and `claude` install and (if host-bridge already ensures `socat`) reuses that step rather than duplicating it.
- `Dory/Features/Settings/SettingsView.swift` — menu-bar-background (A) changes the `toggleRow` helper signature (adds a `disabled: Bool = false` parameter); host-bridge (B) adds an "open logins on my Mac" toggle row; this plan adds the "MACHINE SECRETS" allow-list editor group. This plan MUST rebase its SettingsView edits on plan A's `toggleRow` signature change and plan B's "open logins on my Mac" row (place the "MACHINE SECRETS" group after B's toggle row without disturbing it).

Before starting: run `git log --oneline feat/host-bridge` and confirm the menu-bar-background and host-bridge tasks are merged into the branch. If `MachineProvisioner` already contains an `ensureSocat`/`toolInstallScript` entry point from host-bridge, extend it instead of creating a duplicate; Task 4 below assumes the entry point does not yet exist and creates `MachineProvisioner.toolInstallScript(...)` — if host-bridge already created a tool-install script string, add the `gh`/`claude` branches to it and skip the socat step.

---

## File Structure

| File | Responsibility |
| --- | --- |
| `Dory/Runtime/Machines/MachineEnvImport.swift` | NEW. Pure type owning the env allow-list model (default + extras, parse/merge/serialize) and the async login-shell probe that resolves listed names to non-empty values. |
| `Dory/Runtime/Machines/MachineProvisioner.swift` | MODIFY. Add `toolInstallScript(pkg:hasNode:)` producing the best-effort `gh` + `claude` + `socat` install shell, and per-`PackageManager` `gh` command generation. |
| `Dory/Models/AppStore.swift` | MODIFY. Persisted `machineEnvAllowList` state (load/set/reset), resolve it via `MachineEnvImport.probe` and merge into `MachineSettings.env` in `createMachine`; run `toolInstallScript` after create via a progress-reported exec. |
| `Dory/Features/Settings/SettingsView.swift` | MODIFY. Add a "MACHINE SECRETS" group: editable allow-list rows + a warning note that listed secrets are copied into machines. |
| `DoryTests/MachineEnvImportTests.swift` | NEW. Swift Testing for allow-list parse/merge/serialize and probe-output parsing. |
| `DoryTests/MachineProvisionerToolInstallTests.swift` | NEW. Swift Testing for per-`PackageManager` `gh` command generation and `claude`/`socat` presence in the install script. |

---

## Task 1: Allow-list model + parse/merge (MachineEnvImport)

**Files:**
- Create: `Dory/Runtime/Machines/MachineEnvImport.swift`
- Create: `DoryTests/MachineEnvImportTests.swift`

**Interfaces:**
- Produces:
  - `nonisolated enum MachineEnvImport`
  - `static let defaultNames: [String]` = `["ANTHROPIC_API_KEY"]`
  - `static let optionalExtras: [String]` = `["OPENAI_API_KEY", "GH_TOKEN", "HF_TOKEN"]`
  - `static func normalize(_ names: [String]) -> [String]` (trim, uppercase-safe, drop empties, dedupe preserving order, always includes `defaultNames` first)
  - `static func parse(_ raw: String) -> [String]` (split on commas/newlines/whitespace → `normalize`)
  - `static func serialize(_ names: [String]) -> String` (comma-join `normalize`)

**Steps:**
- [ ] Write the failing test file `DoryTests/MachineEnvImportTests.swift` with COMPLETE code:
```swift
import Testing
@testable import Dory

struct MachineEnvImportTests {
    @Test func defaultsContainAnthropicOnly() {
        #expect(MachineEnvImport.defaultNames == ["ANTHROPIC_API_KEY"])
        #expect(MachineEnvImport.optionalExtras == ["OPENAI_API_KEY", "GH_TOKEN", "HF_TOKEN"])
    }

    @Test func normalizeAlwaysIncludesDefaultFirstAndDedupes() {
        let result = MachineEnvImport.normalize(["GH_TOKEN", "gh_token", "  ", "ANTHROPIC_API_KEY"])
        #expect(result == ["ANTHROPIC_API_KEY", "GH_TOKEN"])
    }

    @Test func normalizeUppercasesAndTrims() {
        #expect(MachineEnvImport.normalize(["  openai_api_key  "]) == ["ANTHROPIC_API_KEY", "OPENAI_API_KEY"])
    }

    @Test func parseSplitsOnCommasNewlinesAndSpaces() {
        let result = MachineEnvImport.parse("GH_TOKEN, HF_TOKEN\nOPENAI_API_KEY foo_bar")
        #expect(result == ["ANTHROPIC_API_KEY", "GH_TOKEN", "HF_TOKEN", "OPENAI_API_KEY", "FOO_BAR"])
    }

    @Test func serializeRoundTrips() {
        #expect(MachineEnvImport.serialize(["HF_TOKEN", "ANTHROPIC_API_KEY"]) == "ANTHROPIC_API_KEY,HF_TOKEN")
    }
}
```
- [ ] Run `scripts/test.sh -only-testing:DoryTests/MachineEnvImportTests` and confirm it FAILS to build with `cannot find 'MachineEnvImport' in scope`.
- [ ] Create `Dory/Runtime/Machines/MachineEnvImport.swift` with COMPLETE code for the model half only (probe added in Task 2):
```swift
import Foundation

nonisolated enum MachineEnvImport {
    static let defaultNames: [String] = ["ANTHROPIC_API_KEY"]
    static let optionalExtras: [String] = ["OPENAI_API_KEY", "GH_TOKEN", "HF_TOKEN"]

    static func normalize(_ names: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for name in defaultNames + names {
            let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard !cleaned.isEmpty, seen.insert(cleaned).inserted else { continue }
            ordered.append(cleaned)
        }
        return ordered
    }

    static func parse(_ raw: String) -> [String] {
        let separators = CharacterSet(charactersIn: ", \t\n")
        return normalize(raw.components(separatedBy: separators))
    }

    static func serialize(_ names: [String]) -> String {
        normalize(names).joined(separator: ",")
    }
}
```
- [ ] Run `scripts/test.sh -only-testing:DoryTests/MachineEnvImportTests` and confirm all 5 tests PASS.
- [ ] Commit: `git add Dory/Runtime/Machines/MachineEnvImport.swift DoryTests/MachineEnvImportTests.swift && git commit -m "feat(machines): env allow-list model for credential bootstrap"`

## Task 2: Login-shell env probe (MachineEnvImport.probe + output parsing)

**Files:**
- Modify: `Dory/Runtime/Machines/MachineEnvImport.swift`
- Modify: `DoryTests/MachineEnvImportTests.swift`

**Interfaces:**
- Produces:
  - `static let sentinel: String` = `"@@DORYENV@@"`
  - `static func probeCommand(for names: [String]) -> String` (builds one `printf` line that emits `sentinel NAME = value sentinel` per normalized name)
  - `static func parseProbeOutput(_ output: String) -> [String: String]` (extracts sentinel-delimited `NAME=value`, drops empty values)
  - `static func resolve(names: [String]) async -> [String: String]` (runs the login shell with `-lic probeCommand` via `Shell.runAsyncResult`, 6s timeout, returns non-empty vars)

**Steps:**
- [ ] Add failing tests to `DoryTests/MachineEnvImportTests.swift` (append inside the struct) with COMPLETE code:
```swift
    @Test func probeCommandEmitsSentinelPerName() {
        let command = MachineEnvImport.probeCommand(for: ["ANTHROPIC_API_KEY", "GH_TOKEN"])
        #expect(command.contains("@@DORYENV@@ANTHROPIC_API_KEY=%s@@DORYENV@@"))
        #expect(command.contains("@@DORYENV@@GH_TOKEN=%s@@DORYENV@@"))
        #expect(command.contains("\"${ANTHROPIC_API_KEY:-}\""))
        #expect(command.contains("\"${GH_TOKEN:-}\""))
    }

    @Test func parseProbeOutputExtractsNonEmptyVars() {
        let output = "noise@@DORYENV@@ANTHROPIC_API_KEY=sk-ant-123@@DORYENV@@@@DORYENV@@GH_TOKEN=@@DORYENV@@tail"
        let vars = MachineEnvImport.parseProbeOutput(output)
        #expect(vars["ANTHROPIC_API_KEY"] == "sk-ant-123")
        #expect(vars["GH_TOKEN"] == nil)
    }

    @Test func parseProbeOutputIgnoresMalformed() {
        #expect(MachineEnvImport.parseProbeOutput("no sentinels here").isEmpty)
        #expect(MachineEnvImport.parseProbeOutput("@@DORYENV@@BROKEN_NO_EQ@@DORYENV@@").isEmpty)
    }
```
- [ ] Run `scripts/test.sh -only-testing:DoryTests/MachineEnvImportTests` and confirm the 3 new tests FAIL to build with `type 'MachineEnvImport' has no member 'probeCommand'`.
- [ ] Add the probe half to `Dory/Runtime/Machines/MachineEnvImport.swift` (insert before the closing brace of the enum) with COMPLETE code:
```swift
    static let sentinel = "@@DORYENV@@"

    static func probeCommand(for names: [String]) -> String {
        normalize(names).map { name in
            "printf '\(sentinel)\(name)=%s\(sentinel)' \"${\(name):-}\""
        }.joined(separator: "; ")
    }

    static func parseProbeOutput(_ output: String) -> [String: String] {
        var result: [String: String] = [:]
        let segments = output.components(separatedBy: sentinel)
        for segment in segments {
            guard let eq = segment.firstIndex(of: "="), segment.hasSuffix("=") == false else { continue }
            let key = String(segment[segment.startIndex..<eq]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(segment[segment.index(after: eq)...])
            guard !key.isEmpty, !value.isEmpty else { continue }
            result[key] = value
        }
        return result
    }

    static func resolve(names: [String]) async -> [String: String] {
        let normalized = normalize(names)
        guard !normalized.isEmpty else { return [:] }
        let command = probeCommand(for: normalized)
        let result = await withTimeout(seconds: 6) {
            await Shell.runAsyncResult(loginShell(), ["-lic", command])
        }
        guard let output = result?.output else { return [:] }
        return parseProbeOutput(output)
    }

    private static func loginShell() -> String {
        if let shell = ProcessInfo.processInfo.environment["SHELL"],
           FileManager.default.isExecutableFile(atPath: shell) { return shell }
        return Shell.find("zsh", candidates: ["/bin/zsh", "/opt/homebrew/bin/zsh", "/usr/local/bin/zsh"]) ?? "/bin/zsh"
    }

    private static func withTimeout<T: Sendable>(seconds: Double, _ operation: @escaping @Sendable () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
```
- [ ] Run `scripts/test.sh -only-testing:DoryTests/MachineEnvImportTests` and confirm all 8 tests PASS.
- [ ] Commit: `git add Dory/Runtime/Machines/MachineEnvImport.swift DoryTests/MachineEnvImportTests.swift && git commit -m "feat(machines): login-shell env probe for allow-listed secrets"`

## Task 3: Per-PackageManager gh install command generation

**Files:**
- Modify: `Dory/Runtime/Machines/MachineProvisioner.swift`
- Create: `DoryTests/MachineProvisionerToolInstallTests.swift`

**Interfaces:**
- Produces:
  - `static func ghInstall(pkg: MachineDistro.PackageManager) -> String` (per-manager `gh` install command; internal, exercised by tests)

**Steps:**
- [ ] Write the failing test file `DoryTests/MachineProvisionerToolInstallTests.swift` with COMPLETE code:
```swift
import Testing
@testable import Dory

struct MachineProvisionerToolInstallTests {
    @Test func aptAddsGitHubRepoAndInstallsGh() {
        let command = MachineProvisioner.ghInstall(pkg: .apt)
        #expect(command.contains("cli.github.com/packages"))
        #expect(command.contains("apt-get install -y gh"))
    }

    @Test func dnfInstallsGh() {
        #expect(MachineProvisioner.ghInstall(pkg: .dnf).contains("dnf install -y gh"))
    }

    @Test func apkInstallsGithubCli() {
        #expect(MachineProvisioner.ghInstall(pkg: .apk).contains("apk add github-cli"))
    }

    @Test func zypperInstallsGh() {
        #expect(MachineProvisioner.ghInstall(pkg: .zypper).contains("zypper -n install gh"))
    }

    @Test func pacmanInstallsGithubCli() {
        #expect(MachineProvisioner.ghInstall(pkg: .pacman).contains("pacman -Sy --noconfirm github-cli"))
    }

    @Test func everyPackageManagerHasNonEmptyGhInstall() {
        for pkg in [MachineDistro.PackageManager.apt, .dnf, .zypper, .apk, .pacman] {
            #expect(!MachineProvisioner.ghInstall(pkg: pkg).isEmpty)
        }
    }
}
```
- [ ] Run `scripts/test.sh -only-testing:DoryTests/MachineProvisionerToolInstallTests` and confirm it FAILS to build with `type 'MachineProvisioner' has no member 'ghInstall'`.
- [ ] Add `ghInstall` to `Dory/Runtime/Machines/MachineProvisioner.swift` (insert before the closing brace of `enum MachineProvisioner`, after `shellInstall`) with COMPLETE code:
```swift
    static func ghInstall(pkg: MachineDistro.PackageManager) -> String {
        switch pkg {
        case .apt:
            return [
                "apt-get update -qq",
                "apt-get install -y curl ca-certificates",
                "install -d -m 0755 /etc/apt/keyrings",
                "curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg",
                "chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg",
                "printf 'deb [arch=%s signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main\\n' \"$(dpkg --print-architecture)\" > /etc/apt/sources.list.d/github-cli.list",
                "apt-get update -qq",
                "apt-get install -y gh",
            ].joined(separator: " && ")
        case .dnf:
            return "dnf install -y 'dnf-command(config-manager)' && dnf config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo && dnf install -y gh"
        case .zypper:
            return "zypper -n install gh || (zypper -n addrepo https://cli.github.com/packages/rpm/gh-cli.repo && zypper -n --gpg-auto-import-keys install gh)"
        case .apk:
            return "apk add github-cli"
        case .pacman:
            return "pacman -Sy --noconfirm github-cli"
        }
    }
```
- [ ] Run `scripts/test.sh -only-testing:DoryTests/MachineProvisionerToolInstallTests` and confirm all 6 tests PASS.
- [ ] Commit: `git add Dory/Runtime/Machines/MachineProvisioner.swift DoryTests/MachineProvisionerToolInstallTests.swift && git commit -m "feat(machines): per-package-manager gh install command"`

## Task 4: toolInstallScript (gh + claude + socat) assembly

**Files:**
- Modify: `Dory/Runtime/Machines/MachineProvisioner.swift`
- Modify: `DoryTests/MachineProvisionerToolInstallTests.swift`

**Interfaces:**
- Produces:
  - `static func toolInstallScript(pkg: MachineDistro.PackageManager, hasNode: Bool) -> String` (best-effort composite: each tool guarded by `command -v` short-circuit and `|| true`, so no single failure aborts; installs `gh` via `ghInstall`, `claude` via official installer with npm fallback when `hasNode`, and `socat`)

**Steps:**
- [ ] Add failing tests to `DoryTests/MachineProvisionerToolInstallTests.swift` (append inside the struct) with COMPLETE code:
```swift
    @Test func scriptSkipsAlreadyPresentTools() {
        let script = MachineProvisioner.toolInstallScript(pkg: .apt, hasNode: false)
        #expect(script.contains("command -v gh >/dev/null 2>&1 ||"))
        #expect(script.contains("command -v claude >/dev/null 2>&1 ||"))
        #expect(script.contains("command -v socat >/dev/null 2>&1 ||"))
    }

    @Test func scriptIsBestEffortAndNeverAborts() {
        let script = MachineProvisioner.toolInstallScript(pkg: .dnf, hasNode: false)
        #expect(!script.contains("set -e"))
        #expect(script.contains("|| true"))
    }

    @Test func claudeUsesOfficialInstallerWithNpmFallbackWhenNode() {
        let withNode = MachineProvisioner.toolInstallScript(pkg: .apt, hasNode: true)
        #expect(withNode.contains("claude.ai/install.sh"))
        #expect(withNode.contains("npm i -g @anthropic-ai/claude-code"))
        let withoutNode = MachineProvisioner.toolInstallScript(pkg: .apt, hasNode: false)
        #expect(withoutNode.contains("claude.ai/install.sh"))
        #expect(!withoutNode.contains("npm i -g @anthropic-ai/claude-code"))
    }

    @Test func socatInstalledViaPackageManager() {
        #expect(MachineProvisioner.toolInstallScript(pkg: .apk, hasNode: false).contains("apk add socat"))
        #expect(MachineProvisioner.toolInstallScript(pkg: .apt, hasNode: false).contains("apt-get install -y socat"))
    }
```
- [ ] Run `scripts/test.sh -only-testing:DoryTests/MachineProvisionerToolInstallTests` and confirm the 4 new tests FAIL to build with `type 'MachineProvisioner' has no member 'toolInstallScript'`.
- [ ] Add `toolInstallScript` and its two private helpers to `Dory/Runtime/Machines/MachineProvisioner.swift` (insert before the closing brace of `enum MachineProvisioner`, after `ghInstall`) with COMPLETE code:
```swift
    static func toolInstallScript(pkg: MachineDistro.PackageManager, hasNode: Bool) -> String {
        var lines: [String] = []
        lines.append("(command -v gh >/dev/null 2>&1 || (\(ghInstall(pkg: pkg)))) || true")
        lines.append("(command -v claude >/dev/null 2>&1 || (\(claudeInstall(hasNode: hasNode)))) || true")
        lines.append("(command -v socat >/dev/null 2>&1 || (\(socatInstall(pkg: pkg)))) || true")
        return lines.joined(separator: "\n")
    }

    private static func claudeInstall(hasNode: Bool) -> String {
        let official = "curl -fsSL https://claude.ai/install.sh | sh"
        guard hasNode else { return official }
        return "\(official) || npm i -g @anthropic-ai/claude-code"
    }

    private static func socatInstall(pkg: MachineDistro.PackageManager) -> String {
        switch pkg {
        case .apt: return "apt-get update -qq && apt-get install -y socat"
        case .dnf: return "dnf install -y socat"
        case .zypper: return "zypper -n install socat"
        case .apk: return "apk add socat"
        case .pacman: return "pacman -Sy --noconfirm socat"
        }
    }
```
- [ ] Run `scripts/test.sh -only-testing:DoryTests/MachineProvisionerToolInstallTests` and confirm all 10 tests PASS.
- [ ] Commit: `git add Dory/Runtime/Machines/MachineProvisioner.swift DoryTests/MachineProvisionerToolInstallTests.swift && git commit -m "feat(machines): best-effort gh/claude/socat install script"`

## Task 5: Persisted allow-list state in AppStore

**Files:**
- Modify: `Dory/Models/AppStore.swift` (add property near line 49-56 with `launchAtLogin`/`showMenuBarIcon`; add key near line 152-158; add load near line 112-114; add setters near line 248-251)

**Interfaces:**
- Produces:
  - `var machineEnvAllowList: [String]` (defaults to `MachineEnvImport.defaultNames`)
  - `func setMachineEnvAllowList(_ names: [String])` (normalizes, persists, updates state)
  - `static let machineEnvAllowListKey: String` = `"dory.machineEnvAllowList"`

**Steps:**
- [ ] Add a failing test file `DoryTests/AppStoreEnvAllowListTests.swift` with COMPLETE code:
```swift
import Testing
@testable import Dory

@MainActor
struct AppStoreEnvAllowListTests {
    @Test func defaultAllowListIsAnthropicOnly() {
        let store = AppStore(runtime: MockRuntime())
        #expect(store.machineEnvAllowList == ["ANTHROPIC_API_KEY"])
    }

    @Test func setAllowListNormalizesAndKeepsAnthropicFirst() {
        let store = AppStore(runtime: MockRuntime())
        store.setMachineEnvAllowList(["gh_token", "  ", "gh_token"])
        #expect(store.machineEnvAllowList == ["ANTHROPIC_API_KEY", "GH_TOKEN"])
    }
}
```
- [ ] Run `scripts/test.sh -only-testing:DoryTests/AppStoreEnvAllowListTests` and confirm it FAILS to build with `value of type 'AppStore' has no member 'machineEnvAllowList'`.
- [ ] In `Dory/Models/AppStore.swift`, add the state property immediately after the `var routeDockerCLI = true` line (line 52):
```swift
    var machineEnvAllowList: [String] = MachineEnvImport.defaultNames
```
- [ ] In `Dory/Models/AppStore.swift`, add the persistence key immediately after the `static let routeDockerKey = "dory.routeDockerCLI"` line (line 156):
```swift
    static let machineEnvAllowListKey = "dory.machineEnvAllowList"
```
- [ ] In `Dory/Models/AppStore.swift`, add the load line inside the `realLaunch` block immediately after the `if let v = UserDefaults.standard.object(forKey: Self.routeDockerKey) as? Bool { routeDockerCLI = v }` line (line 114):
```swift
            if let raw = UserDefaults.standard.string(forKey: Self.machineEnvAllowListKey) {
                machineEnvAllowList = MachineEnvImport.parse(raw)
            }
```
- [ ] In `Dory/Models/AppStore.swift`, add the setter immediately after the `setShowMenuBarIcon(_:)` function (after line 251):
```swift
    func setMachineEnvAllowList(_ names: [String]) {
        let normalized = MachineEnvImport.normalize(names)
        machineEnvAllowList = normalized
        UserDefaults.standard.set(MachineEnvImport.serialize(normalized), forKey: Self.machineEnvAllowListKey)
    }
```
- [ ] Run `scripts/test.sh -only-testing:DoryTests/AppStoreEnvAllowListTests` and confirm both tests PASS.
- [ ] Commit: `git add Dory/Models/AppStore.swift DoryTests/AppStoreEnvAllowListTests.swift && git commit -m "feat(settings): persist machine env allow-list in AppStore"`

## Task 6: Merge resolved secrets into createMachine settings

**Files:**
- Modify: `Dory/Models/AppStore.swift` (`createMachine`, lines 1690-1731; add a static merge helper near `withIdentity` at line 1674)

**Interfaces:**
- Produces:
  - `nonisolated static func mergingEnv(_ settings: MachineSettings, resolved: [String: String]) -> MachineSettings` (adds resolved vars into `settings.env`, existing user-set keys win)

**Steps:**
- [ ] Add a failing test to `DoryTests/AppStoreEnvAllowListTests.swift` (append inside the struct) with COMPLETE code:
```swift
    @Test func mergingEnvAddsResolvedButUserKeysWin() {
        var settings = MachineSettings.default
        settings.env = ["ANTHROPIC_API_KEY": "user-set"]
        let merged = AppStore.mergingEnv(settings, resolved: ["ANTHROPIC_API_KEY": "probed", "GH_TOKEN": "gh-123"])
        #expect(merged.env["ANTHROPIC_API_KEY"] == "user-set")
        #expect(merged.env["GH_TOKEN"] == "gh-123")
    }

    @Test func mergingEnvIgnoresEmptyResolved() {
        let merged = AppStore.mergingEnv(.default, resolved: [:])
        #expect(merged.env.isEmpty)
    }
```
- [ ] Run `scripts/test.sh -only-testing:DoryTests/AppStoreEnvAllowListTests` and confirm the 2 new tests FAIL to build with `type 'AppStore' has no member 'mergingEnv'`.
- [ ] In `Dory/Models/AppStore.swift`, add the merge helper immediately before the `nonisolated static func withIdentity` function (line 1674):
```swift
    nonisolated static func mergingEnv(_ settings: MachineSettings, resolved: [String: String]) -> MachineSettings {
        guard !resolved.isEmpty else { return settings }
        var copy = settings
        for (key, value) in resolved where copy.env[key] == nil && !value.isEmpty {
            copy.env[key] = value
        }
        return copy
    }
```
- [ ] Run `scripts/test.sh -only-testing:DoryTests/AppStoreEnvAllowListTests` and confirm the 2 new tests PASS.
- [ ] In `Dory/Models/AppStore.swift`, wire the probe into `createMachine`: replace the line `var effectiveSettings = identity.map { Self.withIdentity(settings, $0) } ?? settings` (line 1708) with:
```swift
        var effectiveSettings = identity.map { Self.withIdentity(settings, $0) } ?? settings
        let resolvedSecrets = await MachineEnvImport.resolve(names: machineEnvAllowList)
        effectiveSettings = Self.mergingEnv(effectiveSettings, resolved: resolvedSecrets)
        if !resolvedSecrets.isEmpty {
            appendMachineCreationLog("Copying \(resolvedSecrets.keys.sorted().joined(separator: ", ")) into \(trimmedName)…")
        }
```
- [ ] Run `scripts/build.sh` and confirm the app target builds with no errors.
- [ ] Commit: `git add Dory/Models/AppStore.swift DoryTests/AppStoreEnvAllowListTests.swift && git commit -m "feat(machines): inject allow-listed secrets into new machine env"`

## Task 7: Run tool install after machine creation

**Files:**
- Modify: `Dory/Runtime/Machines/MachineService.swift` (`create`, after the identity-setup block ends at line 179, before `progress("Machine \(name) is ready.")` at line 180)

**Interfaces:**
- Consumes:
  - `MachineProvisioner.toolInstallScript(pkg:hasNode:) -> String` (Task 4)
  - `runtime.exec(containerID:command:) async throws -> ExecResult`
- Produces:
  - (behavioral) `MachineService.create` runs `toolInstallScript` best-effort and reports progress; failures are swallowed.

**Steps:**
- [ ] In `Dory/Runtime/Machines/MachineService.swift`, insert the tool-install block immediately after the closing brace of the `if let identity = settings.identity { … }` block (after line 179), before `progress("Machine \(name) is ready.")`:
```swift
        progress("Installing gh, claude, and socat (best-effort)…")
        let nodeProbe = try? await runtime.exec(containerID: Self.containerName(for: name),
                                                command: ["/bin/sh", "-c", "command -v node >/dev/null 2>&1 && echo yes || echo no"])
        let hasNode = (nodeProbe?.output ?? "").contains("yes")
        let toolScript = MachineProvisioner.toolInstallScript(pkg: distro.pkg, hasNode: hasNode)
        let toolResult = try? await runtime.exec(containerID: Self.containerName(for: name), command: ["/bin/sh", "-c", toolScript])
        if let toolResult, !toolResult.succeeded {
            progress("Tool install reported: \(toolResult.output)")
        }
```
- [ ] Run `scripts/build.sh` and confirm the app target builds with no errors.
- [ ] Run `scripts/test.sh -only-testing:DoryTests/MachineTests` and confirm existing machine tests still PASS.
- [ ] Commit: `git add Dory/Runtime/Machines/MachineService.swift && git commit -m "feat(machines): run best-effort tool install after create"`

## Task 8: Settings allow-list editor

**Files:**
- Modify: `Dory/Features/Settings/SettingsView.swift` (`general` computed view, lines 191-212; add a helper view near `toggleRow` at line 273)

**Interfaces:**
- Consumes:
  - `store.machineEnvAllowList: [String]`
  - `store.setMachineEnvAllowList(_:)`
  - `MachineEnvImport.serialize(_:)` / `MachineEnvImport.parse(_:)`

**Steps:**
- [ ] In `Dory/Features/Settings/SettingsView.swift`, add the editor state property at the top of `SettingsView` (immediately after the `@Environment(\.palette) private var p` line at line 5):
```swift
    @State private var envAllowListDraft = ""
```
- [ ] In `Dory/Features/Settings/SettingsView.swift`, add the section into the `general` view immediately after the `.padding(.bottom, 22)` that closes the STARTUP card (after line 202), before `dockerHostCallout` (line 204):
```swift
            groupLabel("MACHINE SECRETS")
            VStack(alignment: .leading, spacing: 8) {
                Text("Comma-separated env var names to copy from your shell into new machines. \(MachineEnvImport.defaultNames.joined(separator: ", ")) is always included; common extras: \(MachineEnvImport.optionalExtras.joined(separator: ", ")).")
                    .font(.system(size: 11.5)).foregroundStyle(p.text3).lineSpacing(3)
                TextField("ANTHROPIC_API_KEY, GH_TOKEN", text: $envAllowListDraft, onCommit: {
                    store.setMachineEnvAllowList(MachineEnvImport.parse(envAllowListDraft))
                    envAllowListDraft = MachineEnvImport.serialize(store.machineEnvAllowList)
                })
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .accessibilityIdentifier("machine-env-allowlist")
                Text("These secrets are copied into every machine's environment. They are visible to processes inside the machine.")
                    .font(.system(size: 11)).foregroundStyle(p.amber).lineSpacing(3)
            }
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(p.bgElevated, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(p.border))
            .padding(.bottom, 22)
            .onAppear { if envAllowListDraft.isEmpty { envAllowListDraft = MachineEnvImport.serialize(store.machineEnvAllowList) } }
```
- [ ] Run `scripts/build.sh` and confirm the app target builds with no errors.
- [ ] Run `scripts/test.sh` (full suite) and confirm the whole suite PASSES.
- [ ] Commit: `git add Dory/Features/Settings/SettingsView.swift && git commit -m "feat(settings): machine env allow-list editor with secret-copy warning"`
