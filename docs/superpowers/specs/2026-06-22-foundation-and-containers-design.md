# Foundation + Containers List — Design Spec

**Workstream:** WS1 (Design-system foundation) + WS2-core (Containers list) + Images list. First cycle of the Dory UI redesign (see [2026-06-22-ui-redesign-audit-digest.md](2026-06-22-ui-redesign-audit-digest.md) for the full 14-surface audit and decomposition).

**Goal:** Build the reusable design-system layer every later workstream consumes, and use it to redesign the two most-seen data screens — the Containers list and the Images list — to the "Elevated" bar: no mock-data flash, real running/all/stopped filtering, premium rows (status pills, port chips, live meters, compose grouping), and honest loading/empty states.

**Visual direction (locked):** B · Elevated, full. Dark mode is the design target this cycle.

## Locked decisions

- **Direction:** Elevated — status pills, clickable port chips, live CPU sparkline, compose grouping, hover quick-actions.
- **Port chips** open `https://<container>.dory.local` (Dory's domain router + local CA) when the container has a proxy domain, falling back to `http://localhost:<publishedPort>`.
- **In scope:** shared foundation components, Containers list redesign, Images list redesign.
- **Out of scope this cycle (non-goals):** light-mode correctness pass (token layer is *structured* to support it, but no light pass); container detail-pane deep rework (logs virtualization/search, stats sparkline rework) → WS5; terminal pop-out → WS3; volumes/networks/k8s/compose/machines/settings/onboarding redesigns → later workstreams (they may adopt new components opportunistically but are not required to change).

## Scope check

This is one coherent, independently-shippable unit: a foundation layer plus two screens that prove it. The detail pane and other tables inherit components but are not redesigned here, keeping the cycle bounded.

---

## Architecture

Three layers, each independently testable:

1. **`Dory/DesignSystem/` components** — pure, stateless SwiftUI views driven by inputs. No `AppStore` dependency.
2. **`AppStore` state + transforms** — owns `LoadState`, `ContainerFilter`, grouping, optimistic mutation, image-reclaim math. Pure functions and `@Observable` state; unit-testable without UI.
3. **Feature views** (`ContainersView`, `ImagesView`) — thin renderers that map `AppStore` state onto components. No business logic.

### Data flow

`Runtime snapshot → AppStore (state + transforms) → Feature view → DesignSystem components`. Views never compute filtering, grouping, or formatting; they read derived properties off `AppStore`.

---

## Design-system components (`Dory/DesignSystem/`)

Each is a new file. Interfaces below are the contract later workstreams depend on.

### `Tokens.swift`
Extends the existing palette (`Theme.swift`) with scales — replaces the audit's 28 ad-hoc font sizes / 15 radii.
- `enum DoryType` → `.label`(11) `.caption`(12) `.body`(13) `.title`(15) `.heading`(18) `.display`(22); each resolves to a `Font` with a weight variant (`.regular`/`.semibold`). Mono variant for image refs/IDs.
- `enum DorySpace: Double` → `xs`(4) `sm`(8) `md`(12) `lg`(16) `xl`(24).
- `enum DoryRadius: Double` → `sm`(6) `md`(8) `lg`(12).
- `enum DoryElevation` → `flat`/`raised`/`overlay` (maps to existing bg tokens; no shadow churn).
- Semantic color roles already exist on the palette (`accent`, `green`, `amber`, `red`, `text/2/3`, `bg*`); this file only adds the scales, not new colors.

### `StatusPill.swift`
`StatusPill(_ status: RunState)` → rounded-`Radius.lg` pill (the model's status enum is `RunState`, `Models.swift:66`): running = green-on-`greenWeak` with a 5pt dot; stopped/exited = `text2`-on-`white06`; paused = amber; restarting = amber with a subtle pulse (respecting reduced-motion). Carries an `accessibilityLabel` of the status text. An images variant (`isUsed` → "in use"/"unused") reuses the same pill body with different inputs.

### `PortChip.swift`
`PortChip(label: String, url: URL, open: (URL) -> Void)` → mono chip with an `external-link` glyph; tap calls `open(url)`. `accessibilityLabel` = "Open \(label)". Visual: `bgElevated` fill, `accentText` foreground.
- **Data source:** `Container.ports` is an unstructured `String` (`Models.swift:71`, e.g. `"0.0.0.0:8080->80/tcp, :::8080->80/tcp"`). A pure `parsePublishedPorts(_ raw: String) -> [PublishedPort]` helper (`PublishedPort { hostPort: Int; containerPort: Int; proto: String }`) dedups host ports and feeds the chips. Unit-tested.

### `Meter.swift`
`Meter(fraction: Double, tint: Color, width: Double = 46, height: Double = 4)` → clamped track+fill bar. `fraction` clamped to `0...1`.

### `Sparkline.swift`
`Sparkline(samples: [Double], tint: Color, height: Double = 14)` → bar sparkline from normalized samples. Empty/all-zero input renders nothing (no fabricated idle bars — fixes the audit's misleading idle chart). Decorative (`accessibilityHidden`).

### `EmptyState.swift`
`EmptyState(icon: String, title: String, message: String, actionTitle: String? = nil, action: (() -> Void)? = nil)` → centered SF-Symbol + title + message + optional primary button. One reusable component for every "nothing here / nothing matched / engine off" state.

### `LoadingSkeleton.swift`
`SkeletonRows(count: Int)` → shimmer placeholder rows matching row height; used while `LoadState == .connecting` before first snapshot. Shimmer animation respects reduced-motion (falls back to static).

### `Buttons.swift`
- `DoryButtonStyle(kind: .primary | .secondary | .destructive)` — primary = `accent` fill, secondary = `bgInput` + border, destructive = `red`. Press scale 0.98, disabled opacity 0.45.
- `IconButton(systemImage: String, label: String, action: () -> Void)` — `label` is **required** and applied as `accessibilityLabel`, closing the audit's "zero accessibility labels in feature layer" finding. Min 28×28 hit target with hover highlight.

### `DataTable.swift`
Generic table chrome extracted from today's ImagesView (the one well-built table), made reusable.
```
struct DataColumn<Row> {
    let key: String
    let title: String
    let width: ColumnWidth   // .flex or .fixed(Double)
    let sortable: Bool
    let cell: (Row) -> AnyView
}
struct DataTable<Row: Identifiable>: View {
    let columns: [DataColumn<Row>]
    let rows: [Row]
    @Binding var sort: SortState?         // (key, ascending)
    var selection: Binding<Row.ID?>? = nil
    var rowActions: ((Row) -> AnyView)? = nil   // hover-revealed
    var emptyState: EmptyState? = nil
    var isLoading: Bool = false
}
```
Handles: pinned sortable header (click toggles asc/desc with a chevron), zebra-free hairline rows, selection highlight (accent left capsule + `accentWeak`), hover row background + revealed `rowActions`, `LoadingSkeleton` when `isLoading`, `EmptyState` when `rows` is empty. Cell rendering is delegated to columns.

---

## AppStore state changes

### Remove the mock-data flash
- `Dory/Models/AppStore.swift:38` — `var containers: [Container] = MockData.containers` → `= []`.
- The default `engineRunning = true` becomes honest: starts `false`, set to `true` only when the runtime probe succeeds.
- Add `enum LoadState { case connecting, ready, engineOff }` and `var loadState: LoadState = .connecting`, transitioned by the existing reload/refresh path: `.connecting` until first successful snapshot → `.ready`; probe failure / engine down → `.engineOff`.

### Container filter
- `enum ContainerFilter: String { case running, all, stopped }`, persisted in `UserDefaults` (key `containerFilter`), default `.running`.
- `var containerFilter: ContainerFilter` (`@Observable`, persisted on set).
- Replace `filteredContainers` (AppStore.swift:521) so it applies, in order: (1) the filter (`running` → `isRunning`; `stopped` → `!isRunning`; `all` → no state filter), then (2) the search text. Search-empty no longer means "all states".
- `var runningCount: Int` already exists via `subtitle`; expose it for the header "N running" chip.

### Compose grouping
- `var groupedContainers: [ContainerGroup]` where `ContainerGroup = (project: String?, containers: [Container])`. Containers sharing a `composeProject` group under that project; `project == nil` containers form a trailing ungrouped section. Order: groups by first-seen, ungrouped last.

### Optimistic actions
- `toggle(_:)` / `restart(_:)` (AppStore.swift:651–686) set a per-container `pending` flag, flip the optimistic state, call the runtime, and **revert + surface the global error toast on failure**. Views show a busy spinner in the action slot while `pending`.
- `var pendingContainerIDs: Set<String>` drives the per-row busy state.

### Port-URL resolution
- `func portURL(for container: Container, port: PublishedPort) -> URL` — returns `https://\(container.domain)` when `container.domain` is non-empty (`Models.swift:75` already holds the `*.dory.local` host), else `http://localhost:\(port.hostPort)`. Pure function, unit-testable.
- `func openPort(_ url: URL)` — opens via `NSWorkspace`; failure surfaces a toast.

### Per-row CPU history (for the live sparkline)
- Rows don't keep history today (only the detail view samples CPU). Add `var cpuHistory: [String: [Double]]` to `AppStore`, appended on each stats refresh and capped at ~20 samples per container (`hostID` key). `Sparkline` in a row reads `cpuHistory[container.id] ?? []`; absent/empty → renders nothing. Evicted when a container disappears from the snapshot.

### Image reclaim
- `var reclaimableImageBytes: Int64` — sum of dangling/unused image sizes (`usedByCount == 0`).
- `func reclaimUnusedImages() async` — prune, with the existing confirm + error-toast path.

---

## Containers list (`ContainersView`)

Header (uses `DataTable`-style chrome or bespoke list — list stays bespoke for grouping): title, live **"N running"** pill, `[Running · All · Stopped]` segmented control bound to `containerFilter`, search field, `New` button (`DoryButtonStyle(.primary)`).

State rendering (drives off `loadState` + data):
| Condition | Render |
|-----------|--------|
| `loadState == .connecting` && containers empty | `SkeletonRows` |
| `loadState == .engineOff` | `EmptyState(icon: power, title: "Engine not running", action: Start engine)` |
| `loadState == .ready` && containers empty | `EmptyState(icon: shippingbox, title: "No containers yet", action: New)` |
| filter/search yields none but containers exist | `EmptyState(icon: line.magnifyingglass, title: "No matches")` (no action) |
| otherwise | grouped list |

Row (`ContainerRow`, rebuilt): `StatusPill` · name (`.title` semibold) + image (`.caption` mono `text3`) · `PortChip`s · `Sparkline` + tabular CPU% · memory + `Meter` · hover-revealed `IconButton`s (stop/start, terminal, ⋯ menu) with busy spinner when pending. Row tap selects (detail pane unchanged except inheriting tokens/pills/buttons). Compose groups render under a `SectionGroupHeader` (project name + service count).

---

## Images list (`ImagesView`)

Rebuilt on `DataTable`:
- Columns: `repository:tag` (flex, mono) · size (fixed, right-aligned tabular) · created (relative) · used-by → `StatusPill`-style "in use"/"unused".
- `sort` bound to existing `imagesSort`.
- Hover `rowActions`: Run (→ create-container sheet prefilled), Inspect, Copy ID, Delete (confirm).
- Header: `Pull image` button; **"Reclaim \(formatted) GB"** button shown when `reclaimableImageBytes > 0` (confirm → `reclaimUnusedImages`).
- `emptyState`: "No images yet" → Pull.

---

## Error handling

- Runtime action failures: revert optimistic state, surface the existing global error toast (no silent fire-and-forget).
- Port open failure: toast "Couldn't open \(url)".
- Image prune failure: toast; list refreshes from truth.
- All destructive actions (Delete image/container, Reclaim) require a confirm.

## Testing

**Unit (`DoryTests/`, Swift `Testing`):**
- `ContainerFilterTests` — running/all/stopped × search combinations over a fixture set.
- `ContainerGroupingTests` — compose grouping order, nil-project trailing section.
- `LoadStateTests` — connecting→ready on first snapshot; →engineOff on probe failure; no mock rows ever present at init (`store.containers` empty before first load).
- `PortURLResolutionTests` — `https://<domain>` when `container.domain` set, `localhost:port` fallback when empty.
- `PublishedPortParsingTests` — `parsePublishedPorts` over real Docker `ports` strings (IPv4+IPv6 dupes, ranges, udp), dedup of host ports, empty string → `[]`.
- `ReclaimMathTests` — `reclaimableImageBytes` sums only `usedByCount == 0`.
- `OptimisticActionTests` — toggle reverts on failure; `pendingContainerIDs` set/cleared.

**Visual (`DoryUITests/` + `scripts/shots.sh`):** screenshot the new components and each container-list state (connecting / engine-off / empty / no-match / running / all) and images (populated / empty / reclaim-visible). Build with the Xcode 27 beta `DEVELOPER_DIR` per project convention; ignore SourceKit false positives.

## File structure

- **Create:** `Dory/DesignSystem/{Tokens,DataTable,StatusPill,PortChip,Meter,Sparkline,EmptyState,LoadingSkeleton,Buttons}.swift`
- **Modify:** `Dory/Models/AppStore.swift` (state + transforms), `Dory/Features/Containers/ContainersView.swift` (rows/states/header), `Dory/Features/Tables/ImagesView.swift` (rebuild on DataTable), `Dory/Features/Containers/ContainerDetailView.swift` (adopt pills/buttons/tokens only).
- **Test:** new files under `DoryTests/`, additions to `DoryUITests/DoryScreensUITests.swift`.
- **Remove:** `MockData.containers` usage from the live path (keep `MockData` for previews/tests only).
