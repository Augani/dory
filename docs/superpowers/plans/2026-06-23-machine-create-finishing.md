# Machine Create Finishing Implementation Plan (WS4 creation gap)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax. Governing spec: audit digest `docs/superpowers/specs/2026-06-22-ui-redesign-audit-digest.md` §3 WS4 + delighter #9.

**Goal:** Close the last machine-creation gaps the user explicitly asked for: make the login **username editable** (it boots as your Mac user but the field was read-only), add a **Rosetta/x86 emulation perf note**, and end creation with an **actionable success card** (Open Terminal + Copy ssh) instead of a bare auto-dismiss.

**Architecture:** Two contained changes. (1) `NewMachineSheet` gains an editable username `TextField` (validated to Linux useradd rules) threaded into the `MacIdentity` it builds — keeping uid (501) and home (the Mac home) Mac-derived so the shared-home ownership alignment is preserved — plus an emulation note under the architecture picker. (2) `AppStore.createMachine` stops auto-dismissing on success: it records the created `Machine` and `MachineCreationSheet` renders a success card with Open-Terminal / Copy-ssh / Done.

**Tech Stack:** Swift 6 / SwiftUI / macOS.

## Global Constraints

- Build ONLY with `scripts/build.sh` (Xcode 27 beta `DEVELOPER_DIR`); `BUILD SUCCEEDED` / `xcodebuild_exit=0` is the authoritative gate. Never call `xcodebuild` directly. Minutes per run.
- IGNORE SourceKit/IDE diagnostics — always false positives in this project (toolchain mismatch).
- Synchronized Xcode folders — no `Dory.xcodeproj/project.pbxproj` edits.
- No inline comments; no docstrings. Colors via `Environment(\.palette)` (`p`) / `store.palette`.
- The shared-home invariant: the provisioned Linux user MUST keep `uid = Int(getuid())` (501) and `homePath = NSHomeDirectory()` so file ownership on the virtiofs-shared Mac home aligns. Only the *name* becomes user-editable. Do not change uid/home derivation.
- Build/snapshot-verified UI cycle — no new unit tests (sheet + store-state changes; `MacIdentity.make` is already unit-covered from WS4-A).

---

### Task M1: Editable username + Rosetta/x86 emulation note (NewMachineSheet)

**Files:**
- Modify: `Dory/Features/Sheets/NewMachineSheet.swift`

**Context:** Today the `identitySection`'s USER field renders `Text(NSUserName())` (read-only, ~lines 133-139); `create()` builds `identity = shareHome ? MacIdentity.current(shell: shell) : nil` (~line 472). The NAME field already demonstrates the validated-`TextField` pattern (red border + error text, ~lines 209-223) and `nameValid`/`nameInvalid`/`createDisabled` (~lines 437-458). `MachineArch` exposes `isNative: Bool` and `MachineArch.host.display`. `MacIdentity.make(username:uid:homePath:shell:sshDir:)` is the pure factory (`current()` is just `make` over `NSUserName()/getuid()/NSHomeDirectory()`).

- [ ] **Step 1: Add username state**

In `NewMachineSheet.swift`, next to the other identity `@State` (near `@State private var shell = "/bin/bash"`, ~line 22), add:
```swift
    @State private var username = NSUserName()
```

- [ ] **Step 2: Make the USER field an editable, validated TextField**

In `identitySection`, replace the read-only USER field:
```swift
                VStack(alignment: .leading, spacing: 6) {
                    Text("USER").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(p.text3).tracking(0.5)
                    Text(NSUserName())
                        .font(.mono(12.5)).foregroundStyle(p.text)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .frame(width: 180, alignment: .leading)
                        .background(p.bgInput, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(p.border))
                }
```
with:
```swift
                VStack(alignment: .leading, spacing: 6) {
                    Text("USER").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(p.text3).tracking(0.5)
                    TextField("username", text: $username)
                        .textFieldStyle(.plain)
                        .font(.mono(12.5)).foregroundStyle(p.text)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .frame(width: 180, alignment: .leading)
                        .background(p.bgInput, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(usernameInvalid ? p.red : p.border))
                        .disabled(!shareHome)
                        .opacity(shareHome ? 1 : 0.5)
                }
```
(The login user is only provisioned when "Share my Mac home" is on — `create()` builds `identity` only when `shareHome`. Disabling the field when `shareHome` is off keeps the UI honest.)

- [ ] **Step 3: Add a username error line and the Rosetta note**

Still in `identitySection`, immediately after the closing `}` of the top `HStack(alignment: .top, spacing: 16) { … }` that holds USER + LOGIN SHELL (before the `Toggle("Share my Mac home…")`), add:
```swift
            if shareHome && usernameInvalid {
                Text("Lowercase letters, digits, _ or -, starting with a letter or _ (max 32).")
                    .font(.system(size: 11)).foregroundStyle(p.red)
            }
```
In `optionsRow`, immediately after the ARCHITECTURE `Picker` block's closing `}` (the `VStack` holding the architecture picker, after its `.disabled(selectedFamily.arches.count < 2)`), add an emulation note inside that same `VStack(alignment: .leading, spacing: 9)`:
```swift
                    if !selectedArch.isNative {
                        Text("Emulated via binfmt — slower than \(MachineArch.host.display). Fine for builds and testing.")
                            .font(.system(size: 11)).foregroundStyle(p.text3)
                            .frame(width: 240, alignment: .leading)
                    }
```

- [ ] **Step 4: Add username validation and gate create on it**

Add computed properties next to `nameValid` (~line 454):
```swift
    private var usernameValid: Bool {
        let trimmed = username.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 32 else { return false }
        return trimmed.range(of: "^[a-z_][a-z0-9_-]*$", options: .regularExpression) != nil
    }

    private var usernameInvalid: Bool {
        !username.trimmingCharacters(in: .whitespaces).isEmpty && !usernameValid
    }
```
Extend `createDisabled` so an invalid username (only when sharing home, since that's when it's used) blocks create. Change:
```swift
    private var createDisabled: Bool {
        name.trimmingCharacters(in: .whitespaces).isEmpty || !nameValid || store.machineBusy || !engineReady || mountsOutsideHome
    }
```
to:
```swift
    private var createDisabled: Bool {
        name.trimmingCharacters(in: .whitespaces).isEmpty || !nameValid || store.machineBusy || !engineReady || mountsOutsideHome || (shareHome && !usernameValid)
    }
```

- [ ] **Step 5: Thread the chosen username into the identity**

In `create()`, replace:
```swift
        let identity = shareHome ? MacIdentity.current(shell: shell) : nil
```
with:
```swift
        let trimmedUser = username.trimmingCharacters(in: .whitespaces)
        let identity = shareHome
            ? MacIdentity.make(username: trimmedUser, uid: Int(getuid()), homePath: NSHomeDirectory(),
                               shell: shell, sshDir: NSHomeDirectory() + "/.ssh")
            : nil
```
(uid and home stay Mac-derived — only the name is user-chosen. If `getuid()` does not resolve, add `import Darwin` at the top; `MacIdentity.current()` already calls `getuid()` under `import Foundation`, so it should resolve transitively.)

- [ ] **Step 6: Build**

Run: `scripts/build.sh`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 7: Visual check (best-effort)**

Run: `scripts/shots.sh` (best-effort). If the New-Machine sheet is snapshot-reachable, confirm the USER field is an editable input and an emulation note appears when a non-native arch is picked. Note if not reachable — build is the gate.

- [ ] **Step 8: Commit**

```bash
git add Dory/Features/Sheets/NewMachineSheet.swift
git commit -m "feat(machines): editable login username + Rosetta/x86 emulation note in create sheet"
```

---

### Task M2: Post-create success card (Open Terminal + Copy ssh) instead of auto-dismiss

**Files:**
- Modify: `Dory/Models/AppStore.swift` (record the created machine; stop auto-dismissing on a fresh create), `Dory/Features/Sheets/MachineCreationSheet.swift` (success branch)

**Context:** `createMachine(...)` (~lines 1239-1278) on success appends "Machine created and started.", sets `activeSheet = nil` (instant dismiss), and `loadMachines()`. The `Machine` model exposes `username: String`, `loginShell`, `sshPort: Int?`. `MachineCreationSheet` currently has only a failure branch (error + Close); on success the sheet just disappears. The established ssh affordance is `"ssh \(machine.username)@localhost -p \(port)"` copied to `NSPasteboard.general`, and opening a terminal window is `openWindow(value: store.terminalSession(for: machine))` with `@Environment(\.openWindow) private var openWindow` (see `MachinesView.swift`).

- [ ] **Step 1: Add the created-machine state to AppStore**

In `Dory/Models/AppStore.swift`, next to the machine-creation state (near `var machineCreationError: String?`, ~line 1114), add:
```swift
    var machineCreated: Machine?
```

- [ ] **Step 2: Reset it when a create starts; record it (and keep the sheet open) on success**

In `createMachine(...)`, where the creation state is initialized (the block setting `machineCreationError = nil` then `activeSheet = .creatingMachine`, ~line 1253), add a reset just before `activeSheet = .creatingMachine`:
```swift
        machineCreated = nil
```
Then in the success path, replace:
```swift
            appendMachineCreationLog("Machine created and started.")
            activeSheet = nil
            loadMachines()
            return nil
```
with:
```swift
            appendMachineCreationLog("Machine created and started.")
            loadMachines()
            machineCreated = machines.first { $0.name == trimmedName }
            if machineCreated == nil { activeSheet = nil }
            return nil
```
(If for any reason the machine isn't found post-reload, fall back to the old auto-dismiss so the sheet never hangs. The other flows — update/clone/restore/import — still set `activeSheet = nil` on their own success and never set `machineCreated`, so they keep auto-dismissing.)

- [ ] **Step 3: Render the success card in MachineCreationSheet**

In `Dory/Features/Sheets/MachineCreationSheet.swift`, add the open-window action at the top of the struct (next to the `@Environment` lines):
```swift
    @Environment(\.openWindow) private var openWindow
```
Add a `succeeded` helper next to `failed`:
```swift
    private var succeeded: Bool { !failed && !store.machineBusy && store.machineCreated != nil }
```
Update the header subtitle line so success reads "Ready". Replace:
```swift
                    Text(failed ? "Creation failed" : "Setting up your Linux machine…")
                        .font(.system(size: 11.5)).foregroundStyle(failed ? p.red : p.text3)
```
with:
```swift
                    Text(failed ? "Creation failed" : (succeeded ? "Ready" : "Setting up your Linux machine…"))
                        .font(.system(size: 11.5)).foregroundStyle(failed ? p.red : (succeeded ? p.green : p.text3))
```
Then add a success branch after the existing `if let error = store.machineCreationError { … }` block (a sibling `if`):
```swift
            if succeeded, let machine = store.machineCreated {
                if let port = machine.sshPort {
                    HStack(spacing: 6) {
                        Image(systemName: "terminal").font(.system(size: 11)).foregroundStyle(p.text3)
                        Text("ssh \(machine.username)@localhost -p \(port)").font(.mono(11)).foregroundStyle(p.text2).lineLimit(1)
                        Spacer(minLength: 0)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("ssh \(machine.username)@localhost -p \(port)", forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc").font(.system(size: 10)).foregroundStyle(p.text3)
                        }.buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(p.bgInput, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(p.border))
                }
                HStack(spacing: 10) {
                    Spacer()
                    Button { dismissSuccess() } label: {
                        Text("Done").font(.system(size: 13, weight: .medium)).foregroundStyle(p.text2)
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .background(p.bgInput, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(p.border))
                    }.buttonStyle(.plain)
                    Button {
                        openWindow(value: store.terminalSession(for: machine))
                        dismissSuccess()
                    } label: {
                        Text("Open Terminal").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 18).padding(.vertical, 8)
                            .background(p.accent, in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain)
                }
            }
```
Add the dismiss helper inside the struct:
```swift
    private func dismissSuccess() {
        store.activeSheet = nil
        store.machineCreated = nil
    }
```
Update the success status icon: replace the `statusIcon` else-branch (the spinner) so a finished machine shows a green check. Change:
```swift
    @ViewBuilder private var statusIcon: some View {
        if failed {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 17)).foregroundStyle(p.red)
                .frame(width: 36, height: 36).background(p.redWeak, in: RoundedRectangle(cornerRadius: 10))
        } else {
            ProgressView().controlSize(.small)
                .frame(width: 36, height: 36).background(p.accentSoft, in: RoundedRectangle(cornerRadius: 10))
        }
    }
```
to:
```swift
    @ViewBuilder private var statusIcon: some View {
        if failed {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 17)).foregroundStyle(p.red)
                .frame(width: 36, height: 36).background(p.redWeak, in: RoundedRectangle(cornerRadius: 10))
        } else if succeeded {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 18)).foregroundStyle(p.green)
                .frame(width: 36, height: 36).background(p.accentSoft, in: RoundedRectangle(cornerRadius: 10))
        } else {
            ProgressView().controlSize(.small)
                .frame(width: 36, height: 36).background(p.accentSoft, in: RoundedRectangle(cornerRadius: 10))
        }
    }
```

- [ ] **Step 4: Build**

Run: `scripts/build.sh`
Expected: `BUILD SUCCEEDED`. (`p.green`, `p.bgInput`, `p.accentSoft`, `p.border` are existing palette tokens; `store.terminalSession(for:)` and the Terminal `WindowGroup` scene exist from WS3.)

- [ ] **Step 5: Visual check (best-effort)**

Run: `scripts/shots.sh` (best-effort — the live creation sheet may not be snapshot-reachable; build is the gate for the scene wiring).

- [ ] **Step 6: Commit**

```bash
git add Dory/Models/AppStore.swift Dory/Features/Sheets/MachineCreationSheet.swift
git commit -m "feat(machines): post-create success card with Open Terminal + Copy ssh"
```

---

## Self-review notes (addressed)

- **Spec coverage (WS4 §3/§55-57 + delighter #9):** editable username (M1 — the explicit "setting usernames" ask), Rosetta/x86 explicit toggle-w/-perf-note (M1 — the note half; the picker already exists), and "creation success → start of work" end card with Open-terminal / Copy-ssh (M2 — delighter #9). The `advancedExpanded` data-loss bug and default-visible file sharing were already fixed in WS4-A.
- **Shared-home invariant preserved:** M1 keeps `uid = Int(getuid())` and `homePath = NSHomeDirectory()`; only the username string is user-chosen, so virtiofs file-ownership alignment is unchanged.
- **Type consistency:** `MacIdentity.make(username:uid:homePath:shell:sshDir:)`, `MachineArch.isNative`/`.host.display`, `Machine.username`/`.sshPort`, `store.terminalSession(for:)`, `@Environment(\.openWindow)` all match existing usages cited above. `machineCreated: Machine?` is new store state, reset on every create start and on card dismiss; the success branch is gated `!failed && !machineBusy && machineCreated != nil` so it never collides with in-progress/other flows.
- Build/snapshot-verified (no unit tests — sheet + store-state UI changes).
