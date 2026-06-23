# Docker/K8s Parity Cycle — Build Roadmap

> **For agentic workers:** this is a *sequencing* plan across four already-designed tracks, not a task list. Each step links to its design spec; implement that spec with `superpowers:executing-plans`. Steps are ordered by (switch-driver value) × (cost) × (dependency). K8s is sequenced at phase granularity.

## Thesis

Kubernetes is the single biggest OrbStack switch-driver, so it anchors the cycle — but it is XL and its interactive phases depend on already-shipped terminal-windowing (WS3). We therefore front-load the cheap, high-leverage **positioning matrix** (S, doc-only) so the cycle has a public honest scorecard from day one, then drive **K8s P1** (the browse + pod-lifecycle core that flips the comparison's Kubernetes row from `partial` toward `tie`). Because Apple-backend correctness and Compose/events fidelity are independent of K8s and of each other — and Apple-correctness contains the highest-value single fix in the cycle (truthful exit codes, which flip Compose's completion gate from always-pass to honest) — they slot in parallel with / between the K8s phases rather than waiting behind the XL anchor. **K8s P2** (pod exec + deployment control) is gated on WS3 terminal-windowing (already shipped) and is sequenced after P1 and after the two M correctness tracks land, so the comparison doc's row upgrades happen in a believable order. **K8s P3** (config/secrets/ingress + open-in-browser) rounds out parity last. The matrix is re-touched after each track lands per its row→track maintenance map, so the marketing artifact never drifts ahead of shipped code.

## Dependency notes (load-bearing)

- **K8s P2 (pod exec) depends on WS3 terminal-windowing** (`docs/superpowers/plans/2026-06-23-terminal-windowing.md`, already shipped). P2 adds an optional `kubeExec` target to the existing `TerminalSession` / `WindowGroup(for:)` scene rather than inventing a terminal. This is the only cross-cycle dependency that gates a K8s phase — and it is already satisfied, so P2 is unblocked the moment P1 lands. K8s P1 has **no** WS3 dependency.
- **The positioning matrix depends on the other three tracks for its *row upgrades*, not for its first cut.** Its honest first version ships immediately against `COMPATIBILITY.md` as sole source of truth; rows 5/6/7/8 are then flipped as tracks land (row 6→K8s, row 5→Apple-correctness + Compose-fidelity, rows 7/8→machines, which is outside this cycle). Ship-first, maintain-after.
- **Apple-backend correctness and Compose/events fidelity are mutually independent and independent of K8s.** Both are M, both are pure-logic-heavy, and they touch disjoint surfaces (Apple runtime + shim `/wait`/`pullImage`/`logs` vs. shim `/containers/json` labels + `EventSynthesizer` + `composeDown`). They can be built concurrently by separate agents.
- **Within K8s, P1 → P2 → P3 is mandatory** (each phase's components extend the prior phase's `KubeClient`/`AppStore`/`KubernetesView`). Do not reorder K8s phases.

## Build sequence

### 1. Positioning matrix — first honest cut (S)
**Spec:** `docs/superpowers/specs/2026-06-23-positioning-matrix-design.md`
**Rationale:** Cheapest item in the cycle (doc-only, no Swift, no build/snapshot cost) and the communication layer that markets the other three tracks. Shipping it first gives the team a single defensible head-to-head scorecard immediately, with the Kubernetes/Engine-API rows honestly marked `partial` and the maintenance-hook footer pre-wired so later tracks know exactly which row to flip. Doing it first (not last) means every subsequent track lands against a published baseline it can visibly upgrade.
**Parallelizable:** Fully — touches only `docs/comparison/` + one `README.md` line; can run alongside any other step. No code dependency.

### 2. Apple `container` backend correctness (M)
**Spec:** `docs/superpowers/specs/2026-06-23-apple-backend-correctness-design.md`
**Rationale:** Contains the highest-value *single* fix in the cycle — truthful exit codes (`containerExitCode` + `/wait`), which flip Compose `service_completed_successfully` and foreground `docker run`/`docker wait` from always-success to honest. M-sized, concentrated in two runtime methods plus four pure unit-tested seams (`AppleStatsMath`, `AppleLogParse`, `ContainerWait`, `PullProgress`). Independent of K8s, so it runs while/just after the matrix and before the K8s anchor consumes attention. Tightens the comparison's Engine-API parity row (row 5).
**Parallelizable:** Yes — disjoint files from step 3; both can run concurrently. Independent of K8s entirely.

### 3. Compose & events fidelity (M)
**Spec:** `docs/superpowers/specs/2026-06-23-compose-events-fidelity-design.md`
**Rationale:** Fixes the compatibility-boundary divergences that break "real `docker compose` drives Dory's socket" — surfacing compose labels in `GET /containers/json` (highest-impact gap), health/compose event attributes, and honest reverse-dependency `composeDown`. M-sized, all pure/testable (`ShimContainerMapping`, extended `EventSynthesizer.diff`, `teardownOrder`). Independent of both K8s and Apple-correctness. Also contributes to the Engine-API parity row (row 5) honesty.
**Parallelizable:** Yes — mutually independent with step 2 (disjoint shim/engine surfaces) and with K8s. Note the spec ships health-event *plumbing* gated on a non-nil `Container.health` (no backend populates it yet) — honest follow-up, not blocking.

### 4. Kubernetes P1 — workloads browse + pod lifecycle (XL → phase 1)
**Spec:** `docs/superpowers/specs/2026-06-23-kubernetes-workloads-design.md` (Phase 1)
**Rationale:** The switch-driver core and cycle anchor. Pods + Deployments + Services lists, namespace + resource-kind switchers, pod logs (follow + copy), pod delete, and the kubeconfig hint turn the thin read-only pods table into a believable cluster browser. Introduces the `KubeClient` seam + pure mappers/parsers that P2/P3 build on. **No WS3 dependency** — safe to start as soon as agent capacity frees from the M tracks. This is the phase that earns the comparison doc's Kubernetes row upgrade (`partial → tie`).
**Parallelizable:** Partially — P1 itself is independent of steps 1–3, so an agent can build it concurrently with the M correctness tracks. P1 must complete before K8s P2/P3.

### 5. Kubernetes P2 — pod exec + deployment control (XL → phase 2)
**Spec:** `docs/superpowers/specs/2026-06-23-kubernetes-workloads-design.md` (Phase 2)
**Rationale:** Makes the cluster browser interactive — pod exec into a terminal window, deployment scale (replica stepper) and rollout restart. **This is the phase gated on WS3 terminal-windowing** (already shipped): it adds an optional `kubeExec: KubeExecTarget?` to `TerminalSession` (must default `nil` so existing container/machine sessions keep decoding through `WindowGroup(for:)` state restoration) and branches `ContainerTerminalView` to `kubectl exec`. Sequenced after P1 (extends its `KubeClient`/views) and after the M tracks so the comparison row already reads `tie` before interactivity layers on.
**Parallelizable:** No — strictly after P1 (extends P1's seam) and depends on shipped WS3. Independent of steps 2/3 only in the sense that those should already be merged by now.

### 6. Kubernetes P3 — config + networking surfaces (XL → phase 3)
**Spec:** `docs/superpowers/specs/2026-06-23-kubernetes-workloads-design.md` (Phase 3)
**Rationale:** Rounds out parity — ConfigMaps, Secrets (masked-by-default with reveal), Ingress list/detail, Service proxy "Open in browser" (reusing `KubeServiceProxy` + `*.k8s.dory.local`), generic resource delete. Lowest marginal switch-driver value of the K8s phases (the browse + exec core already wins the evaluation), so it lands last. Secret-reveal is a consented information-exposure surface, masked by default.
**Parallelizable:** No — strictly after P2 (extends `KubeClient`/`KubernetesView`/`AppStore`).

### 7. Positioning matrix — row upgrades (S, maintenance)
**Spec:** `docs/superpowers/specs/2026-06-23-positioning-matrix-design.md` (maintenance hook)
**Rationale:** Per the doc's row→track map, flip the rows the cycle actually moved: row 6 (Kubernetes) `partial → tie` after K8s P1/P2; tighten row 5 (Engine API parity) after Apple-correctness (step 2) and Compose-fidelity (step 3). Rows 7/8 (machines / file-sharing) and 14/15 (distribution/platform) are explicitly *not* touched — they only move when out-of-cycle machine/distribution work ships. Keeping the matrix in sync is what preserves its credibility.
**Parallelizable:** Trailing — runs after the tracks whose rows it upgrades have merged; doc-only, no code dependency. Can be folded incrementally as each track lands rather than batched at the end.

## Critical path

`K8s P1 → K8s P2 → K8s P3` is the critical path (the XL anchor, sequential by construction). Steps 1 (matrix first cut), 2 (Apple-correctness), and 3 (Compose-fidelity) all run off the critical path and should be parallelized against P1. Step 7 (matrix maintenance) trails whichever upgrading track finishes last. Net: with two or three agents, the cycle's wall-clock is bounded by the K8s three-phase chain, with all M/S work absorbed alongside it.
