# Kubernetes Workload Surface — Design Spec

**Track:** Kubernetes workloads — the single biggest OrbStack switch-driver in Dory's Docker/K8s parity cycle. OrbStack ships a full cluster browser (pods, deployments, services, configmaps/secrets, logs, exec, scale, namespace switching, in-browser service open). Dory today provisions a one-click k3s cluster inside the shared VM (`KubernetesProvisioner`), writes a kubeconfig to `~/.kube/dory-config`, and renders a **single read-only pods table** (`KubernetesView` over `store.pods`, fed by `KubernetesProvider.status()`). It also runs a `KubeServiceProxy` for `*.k8s.dory.local` and can `kubectl apply` a manifest (`AppStore.applyKubernetesYAML`).

**What is broken / missing today:** no pod logs, no pod exec, no pod/resource delete, no Deployments / Services / ConfigMaps / Secrets / Ingress views, no scale/restart, no namespace switcher, and no detail views of any kind. The kubeconfig is written but there is no GUI affordance telling the user how to point their own `kubectl` at it (only the `dory k8s` CLI wrapper wires it).

**Goal:** turn the thin pods table into a credible cluster browser that covers the workloads a developer evaluates Dory on — without inventing a parallel k8s client. This is XL; it ships in three phases, each independently mergeable and snapshot-verifiable.

**Access strategy decision (load-bearing): shell out to `kubectl`, do NOT build a direct API-server HTTP client.** Justification:
- **Zero new dependency + zero new auth/TLS surface.** Dory already ships nothing for k8s except a kubeconfig; the cluster is k3s with a client-cert kubeconfig at `~/.kube/dory-config`. A direct `URLSession` client would have to parse kubeconfig YAML, load the embedded client cert/key into a `SecIdentity`, pin the cluster CA, and re-implement watch/exec/log-streaming protocols (SPDY/websocket upgrades for exec). `kubectl` already does all of this correctly and is the exact tool the user's own workflow uses.
- **Consistency with the codebase.** Every existing k8s touchpoint already shells out: `KubernetesProvider` (`kubectl get … -o json`), `KubeServiceProxy` (`kubectl proxy`), `AppStore.applyKubernetesYAML` (`kubectl apply -f -`), and the `dory k8s` CLI. The `Shell.runAsyncResult` helper and the `Process` + drained-pipe pattern in `applyKubernetesYAML` are the established, tested transports.
- **Streaming logs and exec for free.** `kubectl logs -f` and `kubectl exec -it` give us follow + interactive TTY with no protocol work; exec drops straight into the already-shipped SwiftTerm terminal-windowing surface (`/bin/zsh -lc "kubectl exec …"`), exactly mirroring how container exec runs `docker exec`.
- **Honest failure mode.** When `kubectl` is absent we already surface "kubectl not found — install it". Direct-API would remove that dependency but at a durability cost the parity story does not justify this cycle.

The one durable cost is that `kubectl` must be installed; this is already the precondition for the existing pods table and `Apply YAML`, so this spec does not regress anything. A `KubeClient` seam (below) keeps the door open to swap transports later without touching views.

## Decisions

- **Introduce one pure, Sendable seam: `KubeClient`** (`Dory/Runtime/Kubernetes/KubeClient.swift`) that owns kubectl invocation. It holds the resolved `kubectlPath` + `kubeconfigArgs` (lifted from the duplicated logic in `KubernetesProvider`/`KubeServiceProxy`) and exposes typed `get`/`delete`/`scale`/`rolloutRestart`/`logs` methods returning decoded models or `KubeError`. `KubernetesProvider.status()` is refactored to call it (no behavior change). This is the single place that builds argv, so argv construction is unit-testable in isolation.
- **All list/detail data is `kubectl get <kind> -n <ns|-A> -o json` decoded into `Decodable, Sendable` row structs** — the exact shape `KubernetesProvider.pods()` already uses. Each kind gets a small typed model + a pure mapper `KubeRowMapper.<kind>(from: <APIList>) -> [<Row>]` so JSON→row mapping is tested without a cluster.
- **Namespace + kind switching live in `AppStore`** as `@Observable` state: `kubeNamespace: String` (default `"All Namespaces"` sentinel → `-A`), `kubeResource: KubeResourceKind` (pods/deployments/services/configmaps/secrets/ingress), and per-kind row arrays loaded by `loadKubernetes()`. Switching either re-runs the load. Namespaces themselves come from `kubectl get ns -o json`.
- **Mutations are explicit, confirmed actions** following the `ImagesView` `confirmationDialog` + `pending<Item>` pattern: `deletePod`, `deleteResource`, `scaleDeployment(name, ns, replicas)`, `restartDeployment(name, ns)` on `AppStore`, each calling `KubeClient`, each surfacing failures through the existing global `actionError` toast and calling `loadKubernetes()` on success.
- **Pod logs reuse the container-logs UI verbatim.** `kubectl logs <pod> -n <ns> --tail=200 --timestamps` is parsed by a pure `KubeLogParser.parse(_:) -> [LogLine]` into the existing `LogLine`/`LogLevel` model, rendered by the same `ScrollViewReader` auto-scroll block already in `ContainerDetailView`. Follow (`-f`) streams via an `AsyncStream<LogLine>` mirroring `store.streamLogs`.
- **Pod exec reuses terminal-windowing — no new terminal.** `TerminalSession` gains an optional `kubeExec: KubeExecTarget?` (pod/namespace/container/kubeconfig). When set, `ContainerTerminalView` runs `kubectl exec -it` instead of `docker exec`; the command string is produced by a pure `KubeExecCommand.shell(target:) -> String` (parallel to `TerminalLauncher.execArgs`). `AppStore.terminalSession(for pod: KubePodRow)` is the factory, opened with the same `@Environment(\.openWindow)` action `ContainerDetailView` already uses. This keeps "one window per session id" and the existing `WindowGroup(for: TerminalSession.self)` scene untouched.
- **Kubeconfig/context wiring gets a GUI affordance.** A "Use in kubectl" / "Copy kubeconfig path" control in the cluster banner surfaces `KUBECONFIG=~/.kube/dory-config` and the `dory k8s …` wrapper, so the user's own `kubectl` can target Dory's cluster. No automatic mutation of `~/.kube/config` (that mirrors OrbStack's opt-in stance and avoids clobbering the user's contexts); a pure `KubeContextHint.snippet(kubeconfigPath:)` produces the copyable text.
- **Service open-in-browser reuses `KubeServiceProxy`.** A Service row's "Open" action maps to `http://<svc>.<ns>.k8s.dory.local` (the host `KubeServiceProxy.backends` already publishes) via `NSWorkspace.open`, falling back to the API proxy path when the reverse proxy is not active.
- **The redesigned `KubernetesView`** keeps the `emptyState` + `banner` it has, adds a namespace `Picker` + a resource-kind segmented control to the banner, and switches the body between per-kind tables built from the shared `TableHeader`/`tableRow()` primitives `ImagesView` uses. Selecting a row opens a kind-specific detail (pods/deployments via the existing detail layout; configmaps/secrets via a key/value sheet).

### Phasing

- **P1 — workloads browse + pod lifecycle (the switch-driver core).** Pods + Deployments + Services list, namespace switcher, resource-kind switcher, pod logs (follow + copy), pod delete, kubeconfig hint. Ships a believable cluster browser.
- **P2 — pod exec + deployment control.** Pod exec into a terminal window (reusing WS3), deployment scale (replica stepper) and restart (rollout restart). Makes Dory interactive, not just observational.
- **P3 — config + networking surfaces.** ConfigMaps, Secrets (masked), Ingress list + detail; Service proxy "Open in browser"; generic resource delete. Rounds out parity.

## Components

### Phase 1

- **`KubeClient`** (`Dory/Runtime/Kubernetes/KubeClient.swift`, new, pure/testable transport): resolves `kubectlPath` (reusing the `Shell.find` candidate list) + `kubeconfigArgs` (prefers `KubernetesProvisioner.kubeconfigPath` when present, else default). Methods: `getJSON(kind:namespace:) async -> Result<Data, KubeError>`, `delete(kind:name:namespace:)`, plus a pure static `args(kind:namespace:kubeconfig:) -> [String]` that is the unit-test target. `enum KubeError: Error, Sendable { case kubectlMissing, nonZero(Int32, String), decode }`.
- **`KubeModels.swift`** (`Dory/Runtime/Kubernetes/KubeModels.swift`, new, pure): `Decodable, Sendable` API structs for Deployment (`spec.replicas`, `status.readyReplicas`, `status.availableReplicas`) and Service (`spec.type`, `spec.ports`, `spec.clusterIP`), plus row structs `KubeDeploymentRow`, `KubeServiceRow`, `KubeNamespaceRow` (the existing `Pod`/`PodPhase` model is reused for pods). Pure mappers `KubeRowMapper.deployments(_:)`, `.services(_:)`, `.pods(_:)` (moved out of `KubernetesProvider`).
- **`KubeResourceKind`** (`Dory/Models/Models.swift`, modify — add enum next to `AppSection`): `case pods, deployments, services, configmaps, secrets, ingress`; `var label`, `var apiKind`. Drives the resource switcher.
- **`KubeLogParser`** (`Dory/Runtime/Kubernetes/KubeLogParser.swift`, new, pure/testable): `static func parse(_ raw: String) -> [LogLine]` splitting `--timestamps` output into `timestamp`/`level`/`message`, inferring `LogLevel` from the line (reuse any existing container-log heuristic if present, else a small keyword map). Empty → `[]`.
- **`KubeContextHint`** (`Dory/Runtime/Kubernetes/KubeContextHint.swift`, new, pure/testable): `static func snippet(kubeconfigPath:) -> String` → `export KUBECONFIG=…` + `dory k8s get pods` example.
- **`AppStore`** (`Dory/Models/AppStore.swift`, modify): add `kubeNamespace`, `kubeResource`, `kubeNamespaces: [String]`, `deployments: [KubeDeploymentRow]`, `kubeServices: [KubeServiceRow]`; expand `loadKubernetes()` to load namespaces + the selected kind through `KubeClient`; add `deletePod(_:)`, `podLogs(_:) async -> [LogLine]`, `streamPodLogs(_:) -> AsyncStream<LogLine>`. `kubernetes` property becomes a `KubeClient`-backed value.
- **`KubernetesView`** (`Dory/Features/Tables/KubernetesView.swift`, modify): banner gains a namespace `Picker` (bound to `store.kubeNamespace`, options from `store.kubeNamespaces` + "All Namespaces") and a resource-kind segmented `Picker`; body switches on `store.kubeResource` to per-kind tables built with `TableHeader`/`tableRow()`; pod rows get a hover trash (`pendingDeletePod`) + double-tap to a detail, mirroring `ImageRow`. Add a "Copy kubeconfig" / "Use in kubectl" item to the existing `⋯` menu sourced from `KubeContextHint`.
- **`PodDetailView`** (`Dory/Features/Tables/PodDetailView.swift`, new): header + tabs (Overview / Logs), Logs tab reusing the `ScrollViewReader` auto-scroll + Copy block from `ContainerDetailView`; logs via `store.podLogs`/`streamPodLogs`. Selection state held in `AppStore` (`selectedPodID`) like `selectedContainerID`.

### Phase 2

- **`KubeExecTarget`** (`Dory/Runtime/Kubernetes/KubeExecCommand.swift`, new, pure): `struct KubeExecTarget: Hashable, Codable { let pod; let namespace; let container: String?; let kubeconfig: String }` + `enum KubeExecCommand { static func shell(target:) -> String }` producing `kubectl --kubeconfig … exec -it <pod> -n <ns> [-c <c>] -- sh -c 'command -v bash … exec bash || exec sh'` (parallel to `TerminalLauncher.execArgs`).
- **`TerminalSession`** (`Dory/Runtime/TerminalSession.swift`, modify): add `let kubeExec: KubeExecTarget?` (default nil; keep `Codable`/`Hashable`). Existing container/machine factories pass `nil`.
- **`ContainerTerminalView`** (`Dory/Features/Containers/ContainerTerminalView.swift`, modify): when a `kubeExec` target is present, build the exec string from `KubeExecCommand.shell(target:)` instead of `docker exec`; otherwise unchanged. (`TerminalWindowView` needs no change — it already renders any `TerminalSession`; its "Terminal.app" button reuses the same command source.)
- **`AppStore`** (modify): `terminalSession(for pod: Pod) -> TerminalSession` factory (id `"pod:<ns>/<name>"`, carrying the `KubeExecTarget`); `scaleDeployment(_:replicas:)`, `restartDeployment(_:)` via `KubeClient` (`kubectl scale deploy …`, `kubectl rollout restart deploy …`).
- **`PodDetailView`** (modify): add an "Exec" action that calls `openWindow(value: store.terminalSession(for: pod))`.
- **`DeploymentDetailView`** (`Dory/Features/Tables/DeploymentDetailView.swift`, new): replica stepper (confirm on apply) + "Restart" button, both confirmed via `confirmationDialog`.

### Phase 3

- **`KubeModels.swift`** (modify): add ConfigMap (`data: [String:String]`), Secret (`data` base64 + `type`), Ingress (`spec.rules` host/path/backend) decodables + row structs.
- **`KubeClient`** (modify): `configMaps`, `secrets`, `ingresses` loads; generic `delete(kind:name:namespace:)` already covers all kinds.
- **`AppStore`** (modify): `configMaps`, `secrets`, `ingresses` arrays + `deleteResource(kind:name:namespace:)`; `openService(_:) ` mapping a `KubeServiceRow` to `http://<svc>.<ns>.k8s.dory.local` via `NSWorkspace`.
- **`KubernetesView`** (modify): wire the configmaps/secrets/ingress kinds into the resource switcher; Service rows get an "Open" action.
- **`ConfigDetailSheet`** (`Dory/Features/Sheets/ConfigDetailSheet.swift`, new): key/value list for a ConfigMap/Secret; Secret values masked behind a reveal toggle, base64-decoded by a pure `KubeSecretDecode.decode(_:) -> [LabelPair]`. Registered as a new `AppSheet` case.

## Error handling

- `KubeClient` returns `KubeError` for missing kubectl, non-zero exit (carrying stderr), and decode failure — never throws into views. `loadKubernetes()` already no-ops on `mock` runtime and on unreachable clusters; per-kind loads degrade to `[]` so a partially-failing kind never blanks the whole screen.
- Every mutation (`deletePod`, `deleteResource`, `scaleDeployment`, `restartDeployment`) routes failure to `store.actionError` (the existing global toast) with the kubectl stderr, and is gated behind a `confirmationDialog` ("This cannot be undone." for deletes; replica count echoed for scale). No destructive k8s action runs without confirm — matching the WS5 actions-parity rule.
- Log follow and exec inherit their failure surfaces from the existing primitives: the `AsyncStream` ends when `kubectl logs -f` exits; the terminal window shows the shell/exec exit line (existing `ContainerTerminalView` behavior). Opening exec/logs is gated on pod `phase == .running`.
- kubeconfig hint is read-only (copy to pasteboard); it never edits `~/.kube/config`.

## Testing

Pure logic is unit-tested in `DoryTests/` (no cluster required), mirroring `ExecArgsTests` / `ContainerStatsFormatTests`:

- **`KubeClientArgsTests`** — `KubeClient.args(kind:namespace:kubeconfig:)`: `pods` + "All Namespaces" → `[--kubeconfig, …, get, pods, -A, -o, json]`; a concrete namespace → `-n <ns>` (not `-A`); empty kubeconfig path → no `--kubeconfig` flag.
- **`KubeRowMapperTests`** — decode fixture JSON (small inline strings) for a Deployment list → `[KubeDeploymentRow]` with `ready` = `readyReplicas/replicas`; a Service list → rows skipping headless (`clusterIP == None`) exactly like `KubeServiceProxy.services`; a Pod list reproduces the current `ready`/`restarts`/`phase` mapping (regression-locks the refactor out of `KubernetesProvider`).
- **`KubeLogParserTests`** — `--timestamps` line → `LogLine` with split timestamp/message; an `ERROR`/`WARN` keyword line → the right `LogLevel`; empty input → `[]`.
- **`KubeExecCommandTests`** (P2) — `KubeExecCommand.shell(target:)` with/without a container name and with a non-default kubeconfig produces the expected `kubectl … exec -it … -- sh -c '…'` string (parallels `ExecArgsTests`).
- **`KubeContextHintTests`** — `snippet(kubeconfigPath:)` contains the `export KUBECONFIG=` line and the path.
- **`KubeSecretDecodeTests`** (P3) — base64 `data` → decoded `[LabelPair]`; invalid base64 → the raw value (no crash).
- **`TerminalSessionTests`** (modify) — a pod session round-trips `Codable` with a non-nil `kubeExec`; container/machine sessions keep `kubeExec == nil`.

**Build + snapshot verification** for the SwiftUI surfaces (not unit-testable): `scripts/build.sh` gates compilation; `scripts/shots.sh` captures the redesigned `KubernetesView` (namespace + kind switcher, deployments/services tables), `PodDetailView` (logs tab), and `DeploymentDetailView`. The `mock` backend already supplies pods via `MockData`; extend `MockData` with mock deployments/services so the new tables render in snapshots without a live cluster.

## Non-goals (this cycle)

- Direct API-server HTTP client / `client-go`-style watch streams — `kubectl` shell-out is the deliberate transport (see access strategy); the `KubeClient` seam leaves this swappable later.
- Editing resources via the GUI (apply-from-YAML already exists; in-place `kubectl edit`, port-forward UI, RBAC/CRD browsing, HPA, Jobs/CronJobs/DaemonSets/StatefulSets-specific views, events stream, node/metrics dashboards are future cycles).
- Multi-cluster / context-picker UI — Dory targets its own provisioned cluster; the kubeconfig hint is opt-in and does not mutate the user's `~/.kube/config`.
- Pod logs search / level-filter / virtualization (copy + follow + tail are the high-value subset, matching the WS5 logs scope).
- Auto-installing `kubectl` — absence is surfaced honestly, as today.
