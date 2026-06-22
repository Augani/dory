# Dory UI Redesign — Audit Digest & Decomposition Map

_Synthesis of a 14-surface UX/UI audit into decision-ready redesign workstreams. Source: parallel audit (`wc6d0tn2o.output`), 59 high-severity findings across containers, terminal, machines, machine-creation, images, volumes, networks/k8s, compose, app-shell, settings, onboarding, create/inspect sheets, design-system, orbstack-parity._

## 1. Headline verdict

The runtime is genuinely ahead of its UI — Dory already ships the hard parts (shared VM, reverse proxy, `*.dory.local` + local CA, binfmt emulation, snapshots, docker-context routing) but exposes them through a hand-assembled surface layer where every screen subtly disagrees on metrics and idioms. The app is **feature-wired but not yet designed**: controls work, yet the experience leaks trust at the edges. Four themes cut across all 14 surfaces. **(1) Mock-data seeding** — every engine-backed collection defaults to `MockData` (AppStore.swift:38-44) and `engineRunning` defaults `true` (AppStore.swift:44), so containers, images, volumes, networks, machines, sidebar counts, meters, and the menu-bar list all flash fabricated rows then collapse to reality; this single root cause produces the user's #1 complaint on six surfaces. **(2) No design system** — there is no spacing/type/radius/elevation scale anywhere (28 font sizes, 15 radii, 26 paddings), button/form primitives are copy-pasted across 3-5 files, there are two divergent table implementations, light mode flattens four surface tokens to pure white, and there are **zero** `accessibilityLabel` calls in the entire feature layer. **(3) Modal-instead-of-window** — terminals, the volume browser, and machine creation are all blocking fixed-size sheets that can't minimize or coexist, directly blocking the multitasking the user calls out. **(4) Thin machine config model** — `MachineSettings` holds only cpus/memoryMB/mounts/ports (MachineService.swift:5-11); there is no username, SSH, shell, env, or disk-size, so machines boot bare-root despite shipping sudo.

## 2. The cross-cutting foundation (Workstream #1 — must precede most per-surface work)

The design-system surface is the substrate everything else stands on. Until these primitives exist, every per-surface redesign re-derives its own metrics and re-introduces drift.

**Missing tokens to create (`Dory/DesignSystem/`):**
- **Type scale** — collapse the 28 ad-hoc `.system(size:)` values (7…44, dominated by half-points like 12.5/14.5) into a named `DoryFont` (caption 11, footnote 12, body 13, headline 15, title 18) with weight helpers.
- **Spacing scale** — collapse ~26 padding magnitudes into a 4/8pt `Spacing` enum (xs2=2…x2=24).
- **Radius scale** — collapse 15 radii (radius 7 in toolbar vs 8 in sheets vs 10/15 for "cards") into `Radius` (sm 6, md 8, lg 12, xl 16, pill).
- **Elevation scale** — four bespoke one-off shadows today (MainColumnView.swift:84, SettingsView.swift:328, OnboardingView.swift:22,44); replace with `Elevation` level0/1/2.
- **Semantic + dark/light parity** — light mode sets `bgWindow/bgContent/bgElevated/bgInput` ALL to `0xFFFFFF` (Theme.swift:72-75), so the entire elevation system collapses in light mode (cards/inputs/window separated only by 1px border). Give them distinct light values. `monoText` is a fixed light gray in both palettes (Theme.swift:64,95) — a latent 1.3:1 bug off the terminal surface; make it surface-resolved. Tertiary `p.text3` (#64676F dark / #9A9DA5 light) sits at ~2.4-3.0:1 and is used for load-bearing nav labels, counts, and data columns — must clear 4.5:1.

**Shared components to extract:**
- **DataTable** (promote `TableHeader` / `tableRow()` / `IconTile` / `RowBackground` out of ImagesView; refactor ContainersView's bespoke 16/9 table onto it — one place to hook skeleton/empty handling).
- **EmptyState** + **LoadingSkeleton** (Kubernetes, Compose, Machines each hand-roll empty states; the skeleton primitive is what the mock-flash fix attaches to).
- **DoryButtonStyle** (`.doryPrimary/.dorySecondary/.doryDestructive/.doryGhost` with built-in pressed/hover/disabled/focus-ring — kills 5+ inline `primaryButton` copies).
- **IconButton** with a **required** `accessibilityLabel` init param (makes the zero-labels gap structurally impossible to repeat).
- **SheetChrome v2** (one header/body/footer scaffold on 2-3 size tiers — replaces 5 arbitrary fixed sheet footprints).
- Native or fixed **DoryToggle** (currently 38×22 hit target, no disabled/VO/focus), plus a project-wide `accessibilityReduceMotion` convention (no reduced-motion handling exists anywhere today).

Total effort: **L**. Dependency: none. Nearly every other workstream depends on this.

## 3. Proposed decomposition into redesign workstreams

### WS1 — Design System Foundation
- **Surfaces/files:** `DesignSystem/Theme.swift`, `Components.swift`, `DoryGlyph.swift`, `Color+Hex.swift`; touches every view.
- **Top problems:** no type/spacing/radius/elevation scale (design-system high ×3); light-mode elevation collapse (Theme.swift:72-75); zero `accessibilityLabel` in feature layer; copy-pasted button/form primitives (NewMachineSheet.swift:261-285 ≡ MachinesView.swift:486-517).
- **Headline moves:** four token enums; `DoryButtonStyle` + `IconButton`; extract `DataTable`/`EmptyState`/`LoadingSkeleton`/`SheetChrome v2`; fix light-mode surfaces and tertiary contrast.
- **Parity closed:** the cohesion gap — "OrbStack feels like one app because every surface is the same parameterized primitive."
- **Effort:** **L.** **Dependencies:** none (enables WS2-6).

### WS2 — List Truth & Liveness (the mock-flash + running/all + empty-states cluster)
- **Surfaces/files:** Containers, Images, Volumes, Networks, app-shell counters, menu-bar — `AppStore.swift`, `ContainersView.swift`, `ImagesView.swift`, `VolumesView.swift`, `NetworksView.swift`, `SidebarView.swift`, `MenuBarContentView.swift`, `MockData.swift`.
- **Top problems:** mock-data flash everywhere (AppStore.swift:38-44; lists swap on `reload()` :442-455); no Running/All/Stopped toggle — `filteredContainers` returns ALL when filter empty (AppStore.swift:521-524) — this _is_ "shows all then collapses to active"; ContainersView has no empty state at all (blank pane); sidebar counts/meters momentarily lie (SidebarView.swift:53,61,100); menu-bar lists every container flat, contradicting its "N running" header.
- **Headline moves:** seed all collections `[]` + `engineRunning=false` until first `reload()`, gate MockData behind the mock runtime; segmented Running/All/Stopped in the header (new `ContainerFilter` enum), default running; skeleton rows → crossfade to real; adopt shared EmptyState/no-match across all tables; group + cap the menu-bar list.
- **Parity closed:** competitors default to Running with explicit toggle and never show placeholder data.
- **Effort:** **L.** **Dependencies:** WS1 (skeleton/EmptyState/DataTable primitives).

### WS3 — Terminal Windowing (architecture decision)
- **Surfaces/files:** terminal-experience — `ContainerTerminalView.swift`, `TerminalLauncher.swift`, `MachinesView.swift` (MachineTerminalSheet), `ContainerDetailView.swift`, `DoryApp.swift`, `AppStore.swift`.
- **Top problems:** machine terminal is a fixed 760×480 blocking `.sheet` (MachinesView.swift:11-13,299) — can't minimize/resize/coexist; three inconsistent hosting models for one SwiftTerm view; container shell dies on tab/selection switch via `.id(container.id)` (ContainerDetailView.swift:246); `machineTerminal: Machine?` structurally permits exactly one shell (AppStore.swift:993); no `processTerminated` handling → frozen black pane on exit; SwiftTerm not themed from `p.monoBg/monoText`.
- **Architecture decision (the crux):** introduce a single `TerminalSession` model + registry replacing the lone `machineTerminal: Machine?`, and host sessions in a dedicated **auxiliary `Window`/`WindowGroup(id:"terminal", for: TerminalSession.ID)`** scene opened via `@Environment(\.openWindow)` — a real minimizable/resizable NSWindow, optionally multi-tab. Inline detail tab stays as a quick-peek with a "Detach ↗" that promotes the live process without killing it. **Open question to brainstorm:** NSWindow tabbing vs SwiftUI WindowGroup multi-window vs a detachable pane.
- **Parity closed:** persistent/reattachable sessions, independent windows, multi-session, process-exit/reconnect UX. (SSH endpoint is deferred to WS4.)
- **Effort:** **XL.** **Dependencies:** WS1 (theming tokens, SheetChrome retirement); shares the Window-scene pattern with WS5.

### WS4 — Machine Config & Creation (biggest functional gap)
- **Surfaces/files:** machine-creation + machines-page config — `NewMachineSheet.swift`, `MachineCreationSheet.swift`, `MachineService.swift`, `MachineImageBuilder.swift`, `MachineArch.swift`, `MachineEditSheet` (in MachinesView.swift), `AppStore.swift`.
- **Top problems:** no login user — boots bare-root despite installing sudo/shadow (MachineImageBuilder.swift:18,46; no `useradd`); no SSH/shell/env (`MachineSettings` MachineService.swift:5-11; Env hardcoded `["container=docker"]` :71); **silent data loss** — `collectedSettings()` gates cpus/memory on `advancedExpanded` so collapsing Advanced discards them (NewMachineSheet.swift:417-418); file sharing buried two levels deep with a `/mnt/<name>` default contradicting OrbStack's auto-home-mount; two-modal handoff (580→500) jumps/re-centers with a raw-log console; blocking creation can't background; mounts/ports silently dropped via `compactMap` with no inline validation.
- **Headline moves:** extend `MachineSettings` with username (default `NSUserName()`) / passwordless-sudo / shell / env / diskSize, thread through `createBody`/`hostConfig` and inject `useradd`/sudo into the systemd Dockerfiles; promote a "Sharing & Access" section visible by default (username + auto-suggested host-home mount); fix the advancedExpanded gating bug (visible = submitted); single resizable window hosting both config form and live creation as an inline stepped-progress phase (checklist + log behind "Show details"); inline validation on blur; explicit Rosetta/x86 toggle with perf note.
- **Parity closed:** OrbStack's auto-user, auto file sharing, SSH, default shell, explicit Rosetta, env vars, non-blocking create. (Dory keeps its lead: 12-family distro catalog + dev recipes.)
- **Effort:** **XL.** **Dependencies:** WS1; the window-host approach should reuse WS3's Window-scene pattern.

### WS5 — Surface Detail & Actions Parity (volumes / images / networks-k8s / compose / inspect)
- **Surfaces/files:** Images, Volumes + browser, Networks, Kubernetes, Compose, create/inspect sheets — `ImagesView.swift`, `VolumesView.swift`, `VolumeBrowserSheet.swift`, `VolumeBrowser.swift`, `NetworksView.swift`, `KubernetesView.swift`, `ComposeProjectsView.swift`, `CreateSheets.swift`, `InspectSheets.swift`.
- **Top problems:** destructive ops fire with **no confirm/undo** across images, volumes, networks (AppStore.swift:702-705, 712-716, 728-732) — and `Prune` sits in the same context menu; images have no inline hover actions (right-click-only) and Run uses empty config with no feedback (the "poorly designed" complaint); volume browser is a read-only dead-end (no download/export/copy-path/reveal, single-level `..`, wrong glyphs); pods are read-only dead-ends with no logs/describe/delete (KubernetesView.swift:54-67); Compose filter box is dead and bulk Start ignores `depends_on` (ComposeProjectsView.swift:7-12,123-125); inspect sheets are dead-ends (Copy ID + Close only) with no keyboard submit/focus/inline validation in any create sheet.
- **Headline moves:** confirm+undo on every destructive action; inline hover-action clusters + selection on image/container rows; size bars + reclaimable-space footers; volume browser → resizable utility window with breadcrumbs, file actions (download/copy/reveal), SF-symbol file icons; pod context menus (logs/describe/delete) + namespace grouping; surface k8s service `*.k8s.dory.local` links; structured port/volume/env row editors + keyboard submit + focus + actionable inspect.
- **Parity closed:** actionable disk-aware tables, get-your-data-out volume browser, multi-resource k8s explorer, structured validated create flows.
- **Effort:** **XL** (broad; can split images/volumes/k8s into sub-cycles). **Dependencies:** WS1 (DataTable/EmptyState/SheetChrome); shares window pattern with WS3 for the volume browser.

### WS6 — Native Shell, Settings & Onboarding
- **Surfaces/files:** app-shell-nav, settings, onboarding — `ContentView.swift`, `MainColumnView.swift`, `SidebarView.swift`, `DoryApp.swift`, `DoryCommands.swift`, `SettingsView.swift`, `OnboardingView.swift`, `Updater.swift`.
- **Top problems:** `.hiddenTitleBar` with no replacement toolbar → non-draggable window, hand-rolled 52px header (MainColumnView.swift:19-43); Resources sliders are **fake** (no Slider/binding, thumb can't move — SettingsView.swift:315-334); settings is an in-window section, not a native `Settings{}` scene (Cmd-, just switches section); onboarding step 2 is dead UI (gated on default-true `engineRunning`, so the demo button can fire before the runtime exists — OnboardingView.swift:92-97); comparison-table cells carry meaning by color/shape only; `shield` glyph means three different things; onboarding hard-snaps with no animation and a hardcoded `localhost:8080` demo URL.
- **Headline moves:** adopt NavigationSplitView + native inline toolbar (drag, collapsible sidebar, `.searchable`); move Settings to a real `Settings{}` scene with `Form`/`Toggle`/`Picker`/real `Slider` (or honest read-only gauges); three-way System/Light/Dark appearance; drive onboarding off a real `engineBootstrapPhase`; real migration progress (checklist + cancel); coherent icon language.
- **Parity closed:** native window chrome, real preferences window, truthful bootstrap + verified drop-in proof. (Dory keeps its lead: docker-context conflict cleanup with Undo, Migrate & Compare.)
- **Effort:** **L.** **Dependencies:** WS1; the running/all header control belongs to WS2.

## 4. Recommended build order

1. **WS1 — Design System Foundation.** Everything else re-derives metrics without it; it's the only true blocker. _Rationale: pay the cohesion debt once._
2. **WS2 — List Truth & Liveness.** **This delivers the most visible "wow" first** — it kills the mock flash and the "shows all then collapses" jank on the very first screen the user opens, on cold launch, every time. Highest perceived-quality-per-effort. _Rationale: the loudest complaint, now cheap atop WS1's skeleton/EmptyState._
3. **WS4 — Machine Config & Creation.** The biggest _functional_ gap (username/SSH/sharing) and an explicit user ask. _Rationale: unblocks the "machines as dev boxes" positioning; establishes the Window-host pattern WS3/WS5 reuse._
4. **WS3 — Terminal Windowing.** The cleanest architecture decision; build once WS4 has proven the Window scene. _Rationale: resolves complaint (b) with a reusable session model._
5. **WS5 — Surface Detail & Actions Parity.** Broad but mostly mechanical atop WS1; safety-critical confirm/undo lands here. _Rationale: parallelizable into per-surface cycles._
6. **WS6 — Native Shell, Settings & Onboarding.** Highest-polish, lowest-urgency; the fake sliders and dead onboarding step are embarrassing but low-traffic. _Rationale: finish the frame last._

## 5. Top 10 delighters worth keeping (deduped)

| # | Delighter | WS | Size |
|---|-----------|----|----|
| 1 | One-click **"Open in browser" port chips** + copyable `*.dory.local` HTTPS domain in the row/detail/menu-bar (plumbing already exists, just inert text) | WS5 | S |
| 2 | **Skeleton→real crossfade** (200ms) on first load so the swap reads as a refresh, not a flash | WS2 | S |
| 3 | **Detachable terminal windows** with distro logo + live RunState dot in the title bar; "Detach ↗" flies the live process out without killing it | WS3 | M |
| 4 | **Copy-on-click everywhere** — any overview value (IP, ports, domain, ID) copies with a checkmark micro-confirm; copyable `ssh user@name.dory` on machine cards | WS5 | S |
| 5 | **Command palette (Cmd-K)** fusing section switch + container search + start/stop/new, reusing the existing section enum + filter | WS6 | M |
| 6 | **Verified onboarding proof** — run real `docker context inspect`/`ps` and render the green check the moment it actually passes, instead of asserting it | WS6 | M |
| 7 | **"Reclaim N GB"** count-up chip in Images/Volumes that opens a confirm listing exactly what gets pruned | WS5 | M |
| 8 | **Pulsing StatusDot** on transitional (starting/stopping) state + soft gray→green ramp on start, reduced-motion gated | WS1 | S |
| 9 | **Creation success → start of work** — end the machine-create panel with "Open terminal" + "Copy ssh command" instead of a bare auto-dismiss | WS4 | S |
| 10 | **"Paste docker run…"** parser that fills the structured create fields (image/-p/-v/-e/--name) — highest-leverage power-user touch | WS5 | M |

## 6. Explicit cuts (YAGNI — not now)

- **Multi-select dev recipes + dnf/zypper/apk recipe strings** (machine-creation) — single-select apt recipes are fine for v1; expanding the recipe matrix is breadth, not love.
- **"Broadcast a command to all machine terminals"** (terminal) — power-user footgun; defer until multi-session is proven.
- **Per-volume 7-day growth sparkline / runaway-volume detection** (volumes) — speculative analytics; ship size bars + sort first.
- **k8s namespace tree + Deployments/Services/Ingress explorer** (networks-k8s) — large; ship actionable pods + service links first, expand later.
- **Restart-history sparkline in pod RESTARTS column** — nice but niche; the amber/red count encoding carries the signal.
- **Drag-out-to-download / drag-folder-to-upload in volume browser** (volumes) — start with explicit Download…/Reveal actions; drag-drop is a later finesse.
- **"Duplicate from existing machine" entry point** (machine-creation) — clone/snapshot path already exists; don't fork the create flow yet.
- **Live cost/footprint estimate on CPU/RAM sliders** (machine-creation) — cute, not load-bearing.
- **Genie-style re-dock animation / matchedGeometry sheet-from-button everywhere** — keep a few hero animations (detach, skeleton crossfade); don't gold-plate every transition.
- **Settings search box** (settings) — a real `Settings{}` scene is the win; search over a handful of panes is premature.

## Recommended first workstream to brainstorm in detail

**Start with WS1 (Design System Foundation), brainstormed jointly with the first slice of WS2.** WS1 is the only hard blocker — without the token scales, `DataTable`, `EmptyState`, `LoadingSkeleton`, and `DoryButtonStyle`, every later surface silently re-introduces the drift the audit measured (28 fonts, 15 radii, 26 paddings, zero a11y labels, light-mode elevation collapse). But WS1 in isolation produces no visible payoff, which risks momentum — so scope the brainstorm to "the foundation plus exactly enough to ship the mock-flash + Running/All fix on the Containers list," because that pairing turns an invisible refactor into the single most visible quality jump in the app on the first screen users see, every cold launch. Decide the token values, the `DataTable`/skeleton API, and the `ContainerFilter` state shape together; everything downstream inherits those choices.
