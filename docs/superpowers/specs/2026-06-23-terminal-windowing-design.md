# Terminal Windowing — Design Spec (WS3)

**Workstream:** WS3 of the Dory UI redesign (see [2026-06-22-ui-redesign-audit-digest.md](2026-06-22-ui-redesign-audit-digest.md)). Audit finding: a terminal can't be popped out or minimized — the machine terminal is a **blocking modal sheet** (760×480) and the container terminal is locked inside a detail tab, so the user can't multitask while a shell is open.

**Goal:** Terminals open in real, independent, **minimizable** macOS windows you can keep open while you work — for both containers and machines.

**Architecture:** A `TerminalSession` value (Codable/Hashable, carrying everything a shell needs) drives a dedicated `WindowGroup(for: TerminalSession.self)` scene in `DoryApp`. Views open a session with the `@Environment(\.openWindow)` action; SwiftUI creates one real window per session id and focuses an existing window if the same session is reopened (no duplicates). The machine modal sheet is removed; the container detail keeps its inline terminal tab but gains a "pop out" button.

## Decisions

- **One window per session, keyed by session id.** Container id and `dory-machine-<name>` give stable ids → reopening focuses the same window instead of spawning a second.
- **Self-contained session.** `TerminalSession` carries `socketPath`, `containerID`, `user`, `shell`, `home`, `title`, `subtitle`, `logo` — so the terminal window scene (a fresh SwiftUI environment) renders without reaching into `AppStore`.
- **Reuse `ContainerTerminalView`** (the SwiftTerm `NSViewRepresentable` from WS4-A6, which already takes `user`/`shell`/`home`). Containers default to root; machines pass their identity (`user`/`loginShell`, home `/Users/<user>` or `/root`).
- **Standard window chrome** (resizable, minimizable, ⌘W/⌘M), default 760×480 — NOT `hiddenTitleBar` (the user needs the real title bar to minimize/close). The window title is the session title.
- **Keep the inline container terminal tab** (quick peek) + a "Pop out ↗" button that promotes it to a window. **Machines drop the modal** entirely — the Terminal action opens a window.
- `store.machineTerminal` and `MachineTerminalSheet` are removed.

## Components

- **`TerminalSession`** (`Dory/Runtime/TerminalSession.swift`, new): `struct TerminalSession: Identifiable, Hashable, Codable { let id; title; subtitle; logo: String?; socketPath; containerID; user; shell; home }`.
- **`AppStore` factories** (pure, testable): `func terminalSession(for container: Container) -> TerminalSession` (root shell) and `func terminalSession(for machine: Machine) -> TerminalSession` (identity shell, home derivation). These are the single source of the session's field mapping.
- **`TerminalWindowView`** (`Dory/Features/Containers/TerminalWindowView.swift`, new): slim header (logo + title/subtitle + "Open in Terminal.app ↗") over `ContainerTerminalView(session…)`; `.navigationTitle(session.title)`.
- **`DoryApp` scene:** add `WindowGroup("Terminal", for: TerminalSession.self) { $session in if let session { TerminalWindowView(session: session).environment(store) } }` with `.defaultSize(width: 760, height: 480)`.
- **Open sites:** `ContainerDetailView` (overflow "Open Terminal" + a "Pop out ↗" in the terminal tab) and `MachinesView` (the machine "Terminal" action) use `@Environment(\.openWindow)` → `openWindow(value: store.terminalSession(for: …))`. Remove the `machineTerminal` sheet.

## Error handling

- Opening a terminal for a stopped container/machine: the open site already gates the action on `isRunning`; the window header notes "not running" if state changes (the existing `ContainerTerminalView` shows the shell exit). No new error path.
- Closing the window tears down the SwiftTerm process (existing behavior of the representable). Reopening starts fresh.

## Testing

- **Unit (`DoryTests/`):** `TerminalSessionTests` — `terminalSession(for:)` maps a container to a root session (`user=="root"`, `home=="/root"`, id == container id) and a machine to its identity session (`user`/`shell` from the machine, home `/Users/<user>`, id == `dory-machine-<name>`); `TerminalSession` is `Codable` round-trippable (so `WindowGroup(for:)` works).
- **Build-verified:** the `WindowGroup` scene, `TerminalWindowView`, and the `openWindow` wiring (SwiftUI scene code, not unit-testable). `scripts/build.sh` is the gate.

## Non-goals

- Tabbed terminals / split panes (one window per session this cycle).
- A "broadcast to all terminals" feature (audit-cut).
- Persisting/restoring terminal windows across app launches.
- Real-ssh terminal windows (the in-app terminal uses docker-exec; `dory ssh`/IDE Remote-SSH from WS4-B cover real ssh).
