# Actions Parity & Honest Detail — Design Spec (WS5, scoped)

**Workstream:** WS5 of the Dory UI redesign (see [2026-06-22-ui-redesign-audit-digest.md](2026-06-22-ui-redesign-audit-digest.md)). WS5 ("Surface Detail & Actions Parity") is XL; this cycle delivers its two highest-impact, cross-cutting items:

1. **Destructive-action safety.** Image delete, volume delete/prune, and network delete/prune execute **immediately** with no confirmation (a context-menu `role: .destructive` only styles the item red on macOS — it does not prompt). Container/machine/snapshot/reclaim already confirm. Close the gap consistently.
2. **Honest container detail.** The stats CPU sparkline is both **fabricated** (`sparkData` floors every bar to `0.03` and returns `[0.04]` when empty, so idle containers show fake activity) **and broken** (it yields 0–1 values while `SparkBars` expects 0–100, collapsing every bar to the 2px floor). Logs don't auto-scroll to the newest line and can't be copied.

**Goal:** No destructive action runs without a confirm; the CPU sparkline reflects real activity (and renders honestly when idle); logs auto-scroll and are copyable.

## Decisions

- **Confirmations** reuse the established `confirmationDialog` pattern (as container/machine delete already do): a per-view `@State pending: <Item>?` set by the destructive button, and a `.confirmationDialog(…, presenting: pending)` whose destructive button calls the store action. Applied to: Images delete (row trash + context menu), Volumes delete + prune, Networks delete + prune. Copy states the action is irreversible.
- **Honest stats:** a pure `ContainerStatsFormat.cpuSparkBars(_ history: [Double]) -> [Double]` maps cpu-% samples to 0–100 bar heights, scaled `×5` (so ~20% CPU fills the bar), clamped `0…100`, with **no floor** — idle reads as a flat baseline, empty history → `[]`. The stats view shows "Collecting CPU…" when there's no history yet, and the real bars otherwise.
- **Logs:** wrap the log list in a `ScrollViewReader` and scroll to the last line's id whenever `logLines` changes (auto-follow). Add a "Copy" button in a small logs header that copies `ContainerStatsFormat.logsPlainText(_ lines:)` (a pure `timestamp level message`-per-line join) to the pasteboard.

## Components

- **`ContainerStatsFormat`** (`Dory/Features/Containers/ContainerStatsFormat.swift`, new, pure/testable): `static func cpuSparkBars(_ history: [Double]) -> [Double]`; `static func logsPlainText(_ lines: [LogLine]) -> String`.
- **`ContainerDetailView`** (modify): `sparkData` → `ContainerStatsFormat.cpuSparkBars(cpuHistory)`; stats shows "Collecting CPU…" on empty history; logs gain a `ScrollViewReader` auto-scroll + a "Copy" header button.
- **`ImagesView` / `VolumesView` / `NetworksView`** (modify): add a per-view `pendingDelete`/`pendingPrune` confirm state + `.confirmationDialog` wrapping the unprotected destructive calls.

## Error handling

- The store actions already surface failures via the global error toast; the confirm dialogs only gate the *initiation*. No new error path.
- Copy-logs on an empty buffer copies an empty string (no-op, no crash).

## Testing

- **Unit (`DoryTests/`):** `ContainerStatsFormatTests` — `cpuSparkBars`: empty → `[]`; all-zero history → all-zero (no fabricated floor); `[10,20]` → `[50,100]` (×5, clamped); `[50]` → `[100]`. `logsPlainText`: joins `timestamp level message` per line, `\n`-separated; empty → `""`.
- **Build/snapshot verified:** the confirm dialogs + the logs auto-scroll/copy UI + the stats "Collecting" state (`scripts/build.sh` + `scripts/shots.sh`).

## Non-goals (this cycle)

- Logs virtualization/search, log level filtering (the auto-scroll + copy are the high-value subset).
- Volume browser "get data out", k8s pod actions, compose-up wiring, structured create-sheet redesign (remaining WS5 surfaces — future cycles).
- Undo (true un-delete is impossible for docker resources; confirmation is the realistic safety net).
