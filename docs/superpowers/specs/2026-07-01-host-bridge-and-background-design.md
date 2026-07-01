# Dory Host Bridge, Menu-Bar Background Mode & Credential Bootstrap — Design

Date: 2026-07-01
Status: Approved architecture; pending spec review → implementation plan

## Motivation

Dory aims to make a Linux dev machine "feel local," matching OrbStack. Three gaps block that:

1. **Guest→host browser/login is missing.** Running `gh auth login`, `claude`, `vercel login`, etc.
   inside a Dory machine cannot open the Mac browser, and the OAuth `localhost:<port>` callback the
   CLI starts inside the machine is unreachable from the host — so browser-based logins can't complete.
   (Verified: no `$BROWSER`/`xdg-open` shim, no host URL-open path, no ephemeral-port forwarding.)
2. **"Runs in the background" is not guaranteed.** Dory is a normal windowed app (Dock icon, no
   `LSUIElement`/activation policy). Keeping the engine alive when the window closes relies on
   undocumented SwiftUI `MenuBarExtra` behavior. The desired experience is menu-bar-only (OrbStack-style).
3. **Credential transfer is coarse.** Sharing works only via bind-mounting the whole `$HOME`; the Claude
   API key (a shell-env var) is not propagated, and `gh`/`claude` are not installed in the machine.

## Topology constraint (decides the transport — evidence-based)

Dory machines are **nested**: macOS host → Apple-container VM (`containermanagerd`) → dockerd →
`dory-machine-*` container. Probed 2026-07-01 from inside a Dory container:

- `host.docker.internal` does **not** resolve; default gateway `172.17.0.1` is the **VM** bridge, not
  the Mac (connection refused). ⇒ **No network path guest→macOS host.** (Rules out a TCP/HTTP bridge
  and a guest→host vsock without new VM-level plumbing — multi-week engine work.)
- A container wrote a file through a host **virtiofs** bind-mount and the Mac saw it instantly. ⇒
  **virtiofs is the only proven guest→host channel.**

Therefore the bridge transport is a **file-drop over virtiofs**. This is not a compromise; it is the
only channel that reaches the real Mac in the current architecture.

## Goals / Non-goals

Goals:
- `BROWSER`/`xdg-open` inside a machine opens the URL on the Mac; browser-based CLI logins complete
  end-to-end (auth URL opens on Mac; `localhost:<port>` callback reaches the machine).
- Menu-bar-only app: no Dock icon; engine/shim stay up when no window is open; clean quit still restores
  the docker context.
- Machines get `ANTHROPIC_API_KEY` (+ a curated env allow-list) and have `gh` and `claude` preinstalled.

Non-goals (explicit, YAGNI):
- Guest→host bridge for **plain containers** (machines only for v1; containers rarely do interactive login).
- vsock/network transport (blocked by topology; revisit only if the engine gains host networking).
- Arbitrary host-app control from the guest (only: open http/https URL, forward a loopback port).
- Propagating the entire host shell environment (curated allow-list only).

---

## Component 1 — Host Bridge (guest→host browser + login port-forward)

### Bridge directory (transport)

- Host root: `~/.dory/bridge/<machine-name>/` with subdirs `open/` and `forward/`. Per-machine subdir
  so the host watcher knows the origin machine (→ its container `dory-machine-<name>`).
- Mounted into each machine at a fixed guest path **`/opt/dory/bridge`** (NOT under `/run`, which is a
  tmpfs in `createBody`). Added as an explicit bind independent of the "Share my Mac home" toggle, so
  the bridge works even when full home-sharing is off.
- Request files are JSON, written atomically (write to `*.tmp`, then rename), consumed-then-deleted by
  the host.

Request schemas:
```
open/<uuid>.json      { "url": "https://…", "cwd": "…", "ts": <unix> }
forward/<port>.json   { "port": 53219, "ts": <unix>, "ttlSec": 300 }
```

### Guest shim `dory-open`

- Installed by `MachineProvisioner` to `/usr/local/bin/dory-open` (POSIX sh; no runtime deps beyond
  coreutils + `awk`/`sed`). Symlinked over `xdg-open`, `sensible-browser`, `www-browser`, `gio` shim
  (best-effort), and exported via `BROWSER=dory-open` (env, Component 3).
- Behavior when invoked with a URL:
  1. If the URL contains a loopback `redirect_uri`/host (`localhost`/`127.0.0.1:<port>`), extract
     `<port>` and write `forward/<port>.json` **first**.
  2. Additionally scan `/proc/net/tcp` (+ `tcp6`) for `127.0.0.1:<port>` listeners in `LISTEN` state
     that appeared recently; write a `forward` request for each (covers CLIs that don't put the port in
     the URL). Deduplicated, loopback-only.
  3. Write `open/<uuid>.json` with the URL.
  4. Exit 0 quickly (fire-and-forget); print a human line ("Opening <url> on your Mac…").

### Host watcher (in the app)

- New type `HostBridge` (`Dory/Net/HostBridge.swift`), owned by `AppStore`, started in
  `startLocalNetworking()` alongside DNS/proxy. Uses a `DispatchSource` file-system watch (or kqueue)
  on each active machine's `open/` and `forward/` dirs; on change, scans for new request files.
- `open` handler: parse JSON → validate scheme ∈ {http, https} (reject `file:`, custom schemes, empty)
  → `NSWorkspace.shared.open(url)` → delete request. Malformed/blocked → delete + log, never crash.
- `forward` handler: validate `1024 ≤ port ≤ 65535` → create a host loopback listener
  `127.0.0.1:<port>` that bridges into the machine's container loopback via the existing exec-nc path
  (`HostPortForwarder`'s `container exec … nc 127.0.0.1 <port>` mechanism). Auto-teardown after
  `ttlSec` (default 300s) or when the guest listener disappears. Idempotent per (machine, port).
- Registration: when a machine starts (`MachineService.start`/`create`) the host ensures its bridge
  subdir exists and the watcher is watching it; on stop/delete, tear down watches + forwards + remove
  the subdir.

### OAuth callback data flow (`claude` / `vercel login` example)

1. CLI in machine starts `127.0.0.1:<port>` server, calls `dory-open <authURL>`.
2. Shim writes `forward/<port>.json` then `open/<uuid>.json`.
3. Host wires `127.0.0.1:<port>` → machine `<port>`, then `NSWorkspace.open(authURL)` (Mac browser).
4. User authenticates in the Mac browser; provider redirects browser → `http://127.0.0.1:<port>/cb?code=…`.
5. Mac loopback listener bridges the request into the machine's server → CLI receives the code → done.
6. Forward auto-tears-down on TTL/close.

Guest dependency: the exec-nc bridge needs `nc`/`socat` in the machine → ensure `socat` (or
`netcat-openbsd`) is installed (Component 3 / machine image).

### Security model

- Only the user's own machines mount the user's own bridge dir; trust boundary = "code in my dev
  machine may open my browser / forward a loopback port" (same as OrbStack).
- Host enforces: http/https scheme allow-list; loopback-only forward ports; rename-based atomic reads;
  request TTLs; size caps on request files. No shell interpolation of guest-provided strings.

---

## Component 2 — Menu-bar-only background mode

- Set `INFOPLIST_KEY_LSUIElement = YES` (build setting, since `GENERATE_INFOPLIST_FILE=YES`) so the app
  is an agent: no Dock icon, lives in the menu bar. Belt-and-suspenders: call
  `NSApp.setActivationPolicy(.accessory)` at launch via a minimal `NSApplicationDelegateAdaptor`.
- Menu bar icon is **always present** in this mode (the `showMenuBarIcon` toggle is forced on / hidden,
  else the app becomes unreachable). Keep the setting but disable turning it off when LSUIElement.
- Window behavior:
  - On first launch or when onboarding is required, open the main window; otherwise start windowless in
    the menu bar.
  - "Open Dory" (menu bar) uses `openWindow` to show/focus the main window; clicking it when already
    open just focuses. Closing the window keeps the app + engine running (agent app doesn't terminate on
    last window close).
  - Quit is via the menu bar "Quit Dory" / ⌘Q → `NSApp.terminate` → existing
    `willTerminateNotification` handler restores the docker context (`DockerContext.deactivateSync`).
- Engine/shim/port-forwarder/bridge lifecycles are unchanged (already independent of window state).

## Component 3 — Credential bootstrap

- **Env propagation:** the GUI app does not inherit the user's shell env, so read a curated allow-list
  via a login-shell probe (reuse the pattern in `DockerHostConflict.detect` that runs `loginShell -lic`).
  Default allow-list: `ANTHROPIC_API_KEY` (explicitly requested); plus opt-in extras the user can edit
  (`OPENAI_API_KEY`, `GH_TOKEN`, `HF_TOKEN`). Inject the resolved non-empty vars into the machine via
  `MachineService.createBody`'s `Env` (already the injection point). Documented as "secrets copied into
  the machine env."
- **Tool install (`gh`, `claude`):** in `MachineProvisioner` (best-effort, non-fatal, progress-reported):
  - `gh`: apt → add GitHub's apt repo + `apt-get install gh`; dnf → `dnf install gh`; apk →
    `apk add github-cli`; zypper/pacman → distro package. Fallback: download the release tarball.
  - `claude`: the official Claude Code installer (exact command verified against current Anthropic docs
    at implementation time — native install script preferred), fallback `npm i -g @anthropic-ai/claude-code`
    if Node is present.
  - Also ensure `socat` (needed by Component 1's callback bridge).
- Network-dependent; failures log a warning and do not fail machine creation.

---

## Files touched

New:
- `Dory/Net/HostBridge.swift` — host watcher (open + forward handlers, validation, lifecycle).
- `Dory/Runtime/Machines/DoryOpenShim.swift` — the guest `dory-open` sh script as a string + install steps.
- `Dory/App/AppDelegate.swift` — minimal `NSApplicationDelegateAdaptor` (activation policy).

Changed:
- `Dory/DoryApp.swift` — attach app delegate; window-open behavior for agent mode.
- `Dory.xcodeproj/project.pbxproj` — `INFOPLIST_KEY_LSUIElement = YES` (both configs). (CLI edit only;
  do not open the Xcode 27 GUI — it re-bumps objectVersion 77→110.)
- `Dory/Models/AppStore.swift` — start/stop `HostBridge` in `startLocalNetworking`/`stopLocalNetworking`;
  register machine bridge dirs on machine start/stop; env allow-list probe + injection wiring;
  force menu-bar icon on under LSUIElement.
- `Dory/Runtime/Machines/MachineService.swift` — add the `/opt/dory/bridge` bind + `BROWSER` env; call
  bridge registration; add injected env from the allow-list.
- `Dory/Runtime/Machines/MachineProvisioner.swift` — install `dory-open` + symlinks; install `gh`,
  `claude`, `socat`.
- `Dory/Net/HostPortForwarder.swift` — expose an on-demand "forward host loopback:<port> → machine
  loopback:<port>" entry point with teardown (extend the existing exec-nc bridge).
- `Dory/Features/Settings/SettingsView.swift` — surface the env allow-list editor + "open logins on my
  Mac" toggle; reflect menu-bar-only.

## Testing

- Unit (Swift Testing): URL validation (scheme allow-list, rejects `file:`/junk); `forward` port
  validation; `dory-open` port-extraction from representative auth URLs; env allow-list parsing; request
  JSON encode/decode; atomic read (rename) handling.
- Guest shim: shell-level tests for URL/redirect_uri parsing and `/proc/net/tcp` scanning (fixture files).
- Integration (extends `scripts/readiness.sh`, `--bridge`): create a machine; inside it run a fake login
  that starts a loopback server + calls `dory-open`; assert (a) host received the open request (stub the
  opener to record instead of launching a browser), (b) the forward wired host↔guest and a request to
  `127.0.0.1:<port>` reached the guest server. Tear down.
- Manual: real `claude` / `gh auth login` inside an Ubuntu machine opens the Mac browser and completes.
- Menu-bar mode: launch → no Dock icon; close window → app + `docker` still work; quit → context restored.

## Risks / open questions

- Callback ports whose number is neither in the URL nor visible via `/proc/net/tcp` at shim time (rare):
  the `/proc` scan runs at open time; document the limitation.
- `NSWorkspace.open` from an `.accessory` app is fine, but confirm focus behavior (browser comes forward).
- Auto-copying `ANTHROPIC_API_KEY` into a machine is a deliberate secret-propagation; make it visible in
  the UI and default to the single requested key, not a broad sweep.
- `claude` installer availability/offline: best-effort; must not break machine creation.

## Relationship to launch

Launch is moved to accommodate this (user decision, 2026-07-01). Build order: Component 2 (small,
de-risks background) → Component 1 (the bridge, core value) → Component 3 → notarized Developer-ID build
→ clean-room first-run test → readiness incl. `--bridge`.
