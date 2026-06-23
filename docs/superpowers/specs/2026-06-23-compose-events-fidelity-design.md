# Compose & Events Fidelity — Design Spec

Dory's Compose stack (`Dory/Compose/ComposeEngine.swift`, `ComposeModel.swift`) already parses `compose.yaml`, builds a topological start order, probes healthchecks via exec, and brings projects `up`/`down` against any `ContainerRuntime`. The GUI (`Dory/Features/Compose/ComposeProjectsView.swift`) groups running containers into project cards by the `com.docker.compose.project` / `com.docker.compose.service` labels and offers per-project Start/Stop/Down plus per-service toggles. On the Apple/mock backends, lifecycle is reported to `docker events` watchers by `EventSynthesizer.diff` (`Dory/Engine/EventSynthesizer.swift`), driven by the polling loop in `DockerShim.eventsResponse`.

The wiring works but has four concrete fidelity gaps that diverge from a real engine, each of which a `docker compose` CLI run or a `docker events` watcher will notice:

1. **Compose labels are dropped from `GET /containers/json`.** `DockerShim.containersResponse` hard-codes `Labels: [:]` (DockerShim.swift:391). Dory's own GUI reads labels from the runtime snapshot directly so its cards work, but the **real `docker` CLI** and `docker compose` driving Dory's socket see no `com.docker.compose.*` labels — `docker compose ps`, `docker ps --filter label=…`, and external compose tooling can't recognize Dory-created projects. This is the highest-impact gap: it breaks the "real `docker compose` drives Dory's socket" claim in COMPATIBILITY.md.
2. **Synthesized events omit health and compose context.** `EventSynthesizer.diff` only emits `create/start/stop/die/destroy` and the `Actor.Attributes` carry only `name`/`image`. A real engine also emits `health_status: healthy`/`health_status: unhealthy` container events and stamps compose attributes (`com.docker.compose.project`, `com.docker.compose.service`). Watchers that wait on `docker events --filter event=health_status` (a common compose-adjacent pattern) never fire.
3. **`composeDown` discards the project shape.** `AppStore.composeDown` calls `engine.down(ComposeProject(name: name, services: [], …))` (AppStore.swift:912). With empty `services`, `ComposeEngine.down`'s `startOrder()` returns `[]`, so the careful reverse-dependency teardown (ComposeEngine.swift:63-68) silently degrades to "stop everything by name prefix in arbitrary order" — a dependent can be torn down after its dependency. The GUI never reconstructs the parsed project.
4. **The reverse-teardown order is untested** because the test double drops labels. `RecordingRuntime.create` (ComposeEngineTests.swift:24) builds a `Container` with no `labels`, so `composeService` is always `nil` and `down`'s ordering branch is never exercised.

`EventBus` (EventSynthesizer.swift:51-71) is **dead code** — defined, never instantiated. The shim re-derives events by polling snapshots, so the bus is not on the live path; this spec does not resurrect it.

**Goal:** Dory-created compose containers are recognizable to the real `docker`/`docker compose` CLI (labels surfaced); synthesized `docker events` include `health_status` transitions and compose attributes so health/compose watchers behave like a real engine; `compose down` tears down in true reverse-dependency order from the parsed project; and the event-synthesis + down-ordering logic is pure and unit-tested.

## Decisions

- **Surface labels in the containers list (pure mapping).** Extract a pure `static func summary(_ container: Container, all: Bool) -> DockerContainerOut?` onto a new `ShimContainerMapping` enum so the `State`/`Status`/`Ports`/`Labels` derivation is testable, and pass `container.labels` through instead of `[:]`. `Container.labels` already carries the compose keys on every backend (set by `ComposeEngine.spec`, present in `MockData`, mapped from the engine in `DockerEngineRuntime.snapshot`). No new data needed — the shim just stops throwing it away.

- **Richer event model + health diffing (pure).** Extend `DoryEventAction` with `case healthStatusHealthy = "health_status: healthy"` and `case healthStatusUnhealthy = "health_status: unhealthy"` (raw values match Docker's exact `Action` strings). Add `var attributes: [String: String]` to `DoryEvent` carrying `name`, `image`, and any `com.docker.compose.project`/`com.docker.compose.service`/`com.docker.compose.container-number` labels. `EventSynthesizer.diff` gains health diffing: when a container's `health` field transitions to `.healthy` or `.unhealthy` (and it existed before), emit the matching `health_status` event. This requires `Container` to expose a `health: Health?` derived from its labels/state — checked below; if the snapshot does not yet carry health, the health-event branch is gated on a non-nil `health` so it is a no-op on backends that don't report it (honest: Docker backend proxies real events anyway, so synthesis only matters for Apple/mock).

- **`DockerShim.eventsResponse` reads the new attributes.** The encode loop maps `event.attributes` straight into `DockerEventActor.Attributes` instead of the hard-coded `["name":…, "image":…]`. The action string comes from `event.action.rawValue` unchanged (the raw values are already Docker-faithful, including the `health_status: …` forms).

- **`compose down` reconstructs the real project.** `AppStore` keeps a `composeProjects: [String: ComposeProject]` map keyed by project name, populated on every successful `composeUp`. `composeDown(name)` looks up the parsed project and passes it to `engine.down`; on a cache miss (project brought up in a prior session) it falls back to reconstructing a minimal project from the current snapshot's containers grouped by `composeService`, so reverse ordering still has service identity to sort on. The `ComposeEngine.down` body is unchanged — it already does the right thing given a real project.

- **Make down-ordering testable.** Fix `RecordingRuntime.create` to copy `spec.labels` onto the `Container` it fabricates, so `composeService` resolves and the reverse-order assertion can be written. This is a test-double fix, not production behavior.

All new logic lives in pure functions/enums (`ShimContainerMapping`, the extended `EventSynthesizer.diff`, a small `ComposeEngine.teardownOrder` helper extracted from `down`) so it is unit-tested without a live engine. No ViewModels; `AppStore` stays the Environment-injected store. Strict types: new enum cases over magic strings, `[String: String]` attributes validated at the boundary.

## Components

- **`Dory/Engine/EventSynthesizer.swift`** (modify, pure/testable): add `healthStatusHealthy`/`healthStatusUnhealthy` to `DoryEventAction`; add `attributes: [String: String]` to `DoryEvent`; rewrite `event(_:_:)` to populate `attributes` from the container's `name`/`image`/compose labels; add health-transition diffing in `diff(previous:current:)` gated on a non-nil `Container.health`. Leave `EventBus` as-is (out of scope) or delete if confirmed unreferenced — flagged as an open question, not done blindly.

- **`Dory/Shim/ShimContainerMapping.swift`** (new, pure/testable): `enum ShimContainerMapping { static func summary(_ container: Container, all: Bool) -> DockerContainerOut?; static func state(_:) -> String; static func statusText(_:) -> String }`. Houses the `State`/`Status`/`Labels`/`Ports` derivation currently inline in `containersResponse`, now passing `container.labels` through.

- **`Dory/Shim/DockerShim.swift`** (modify): `containersResponse` delegates per-container mapping to `ShimContainerMapping.summary` (Labels no longer `[:]`); `eventsResponse` encode loop sets `Actor: DockerEventActor(ID: event.containerID, Attributes: event.attributes)`.

- **`Dory/Models/Models.swift`** (modify): add `var health: Health?` to `Container` derived from its existing fields/labels (e.g. a `health` label or status) so `EventSynthesizer` can diff health. If no health signal exists on the snapshot yet, define `health` to return `nil` for now and note it as the activation gate (honest: health events only fire once a backend populates it).

- **`Dory/Compose/ComposeEngine.swift`** (modify, pure helper extracted): pull the reverse-ordering sort out of `down` into `static func teardownOrder(containers: [Container], startOrder: [String]) -> [Container]` so it is unit-testable in isolation; `down` calls it.

- **`Dory/Models/AppStore.swift`** (modify): add `private(set) var composeProjects: [String: ComposeProject] = [:]`; set `composeProjects[project.name] = project` after a successful `composeUp`; rewrite `composeDown(_:)` to resolve the project from `composeProjects[name]` or reconstruct it from the snapshot, then call `engine.down(project)`.

- **`DoryTests/ComposeEngineTests.swift`** (modify): fix `RecordingRuntime.create` to set `labels: spec.labels` on the fabricated `Container`; add a reverse-teardown-order assertion.

## Error handling

- `ShimContainerMapping.summary` returns `nil` for containers filtered out by `all == false && status != running`; the caller `compactMap`s, so a filtered or malformed container is dropped, never crashes the list response. Empty `labels` map to `Labels: [:]` (valid Docker output), so non-compose containers are unaffected.
- `EventSynthesizer.diff` is total: unknown/absent health is `nil` and skips the health branch (no spurious events). Attribute population uses optional-chained label reads with nullish fallbacks — a container missing compose labels simply omits those attribute keys.
- `AppStore.composeDown` on a cache miss with zero matching snapshot containers calls `engine.down` with an empty project; `ComposeEngine.down` already guards every `stop`/`remove` with `try?`, so a missing/already-removed container is a no-op. Failures surface via the existing `actionError` global toast; `composeBusy` is reset by the `defer`.

## Testing

- **`DoryTests/EventSynthesizerTests.swift`** (new): `diff` create→start emits `create` then `start` with `attributes["name"]`/`["image"]`/`["com.docker.compose.service"]` populated from a labeled container; running→stopped emits `die` then `stop`; removed running container emits `die`+`destroy`; **health transition** starting→healthy emits exactly one `health_status: healthy` (raw value asserted literally) and healthy→unhealthy emits `health_status: unhealthy`; a container with `health == nil` emits no health event; no status change emits nothing.
- **`DoryTests/ShimContainerMappingTests.swift`** (new): a compose-labeled running container maps to `State == "running"`, `Status` prefixed `"Up "`, and `Labels["com.docker.compose.project"]` preserved (the regression guard for the dropped-labels bug); a stopped container with `all: false` maps to `nil`; a non-compose container maps to `Labels == [:]`.
- **`DoryTests/ComposeEngineTests.swift`** (extend): `teardownOrder` returns dependents before their dependencies for the `web→api→{db,cache}` fixture (inverse of start order, unranked last); the existing `downStopsAndRemovesProjectContainers` strengthened to assert `stoppedIDs`/`removedIDs` are in reverse-dependency order now that `RecordingRuntime` carries labels.
- **`DoryTests/ComposeTests.swift`** (extend if needed): assert `AppStore.composeUp` caches the parsed project under its name and `composeDown` consumes it (drive against `RecordingRuntime`/mock store; pure store-state assertion, no live engine).
- **Build/snapshot verified:** `scripts/build.sh` then `scripts/shots.sh` — confirm the Compose projects view still renders cards (no UI change expected, this is a fidelity/regression guard) and that the app builds with the extended event/mapping types.

## Non-goals (this cycle)

- Resurrecting or wiring `EventBus` onto the live path; the polling synthesizer in `eventsResponse` stays. (Removing it as dead code is an open question, not assumed.)
- Populating a real `Container.health` from the Apple/mock snapshots — this cycle adds the *plumbing* (`health: Health?`, health-event diffing) gated on a non-nil value; actually sampling health into the snapshot on those backends is a follow-up. The Docker backend proxies real engine events regardless.
- Event filtering (`--filter`), `network`/`image`/`volume` event scopes, and the `scope`/`Type` taxonomy beyond `container` — synthesized events stay container-scoped this cycle.
- Compose profiles, multiple-file/override merge, anonymous-volume wiring, `network_mode: service:` — already tracked as ⛔/🟡 in COMPATIBILITY.md and out of scope for fidelity polish.
- Restart-policy name translation (`unless-stopped`/`on-failure:N`) into `MaximumRetryCount` — a separate create-body fidelity item.
