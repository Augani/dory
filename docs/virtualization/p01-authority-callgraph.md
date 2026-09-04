# P01 authority and launch call graph

Reviewed against the working tree on 2026-09-04. This inventory records the P01-04/P01-13 implementation boundaries. Frozen behavioral and Release evidence is retained in the P01 review receipt; this is not physical guest qualification. Function names below identify implementation boundaries without depending on changing source line numbers.

## Production ownership

| Owner | Input and output | Why this boundary exists |
| --- | --- | --- |
| `DoryVirtualizationPlatformResolver` / `DoryVirtualizationProductPolicy` (`DoryOperations`) | Host architecture, guest family/architecture and translation consent → supported product cell | Reject unsupported intent before artifact acquisition, journal publication or disk mutation. Media architecture remains separately inspected. |
| `MachineManager.workspaceAuthority` and configuration migration bridge (`DorydKit`) | Exact persisted machine bytes plus workspace record → native definition and runtime compatibility projection | Native desired state is authoritative. The projection supplies existing helper/path interfaces and must not replace the persisted source used for launch reservations. |
| `DoryDaemonVirtualMachineProductionPlanningController.resolveReserveAndPublish` | Native definition and exact artifact publication paths → planning transaction | Publishes artifact authority only when kind, provenance, mutability and manager-owned launch path agree. |
| `DoryDaemonVirtualMachinePlanningTransactionCoordinator.resolveReserveAndPublish` | Caller UUID, expected workspace/version and desired definition → journalled admission and publication | Owns the planning portion of the existing lifecycle operation. Its mutation fence, durable recovery descriptor and admission lease have distinct responsibilities. |
| `DoryDaemonVirtualMachinePlanningCoordinator.resolveAndPersist` | Definition plus trusted inventory → `DoryResolvedMachinePlan` | Selects backend/graphics once, resolves topology, binds resources/evidence/persistence, and publishes by revision. Lower graphics requires explicit recovery authorization. |
| `DoryDaemonProductionTrustInventory` | Daemon-owned paths, host observation, signed catalog and admission ledger → fresh trusted inventory | Reads and verifies external or mutable authority. Persisted audit evidence is insufficient to recreate trusted qualification. |
| `DoryResolvedMachinePlanRepository` | Private persisted bytes → decoded, schema-checked plan | Disk is an authority boundary; unknown/obsolete records cannot silently gain current launch authority. |
| `DoryDaemonVirtualMachineLaunchPlanResolver.resolve` | Current definition, exact plan revision and fresh inventory → exact adapter plan plus single-use pre-spawn authorization | Has no capability planner or fallback authorization. Revalidates the persisted selection instead of choosing again. |
| `MachineManager.prepareResolvedMachineStart` / `spawnPreparedMachine` | Resolved launch plus persisted source → reserved helper generation and exact launch envelope | Rechecks current metadata/artifacts/shares/plan, then reserves the unchanged persisted source and operation UUID. The runtime projection remains separate. |
| `DoryDaemonVirtualMachinePreSpawnAuthorization` | Fresh purpose-bound authorization → one launch or one preflight check | Final host/runtime/artifact/admission checks are consumed once. Running/stopped preflight cannot authorize another process. |
| `RuntimeLaunchEnvelope` / `DoryPCRuntimeLaunchEnvelope` and runner composition | Exact plan-bound envelope, inherited resources and selected helper → guest execution | A separate process must verify descriptors, compute/disk/device authority and plan binding. It cannot select another backend or weaker graphics. VZMac uses exact managed arguments instead of the Linux envelope. |

The production composition is:

```text
DoryDaemonVirtualMachineProductionTrustFactory.activate
  → verified runtime/catalog material
  → MachineManager(launchPolicy: .perWorkspaceAuthority)
  → production adapters whose lifecycle operations return to that manager
  → DoryDaemonVirtualMachineProductionPlanningCompositionFactory.resolve
      → artifact authority + ledger + workspace/plan repositories
      → recover unfinished planning operations
      → exact evidence collector + launch resolver
  → installResolvedLaunchInfrastructure
  → activateVerifiedTrustFloor
  → complete recovered compound operations under activated trust

MachineManager.start (app, CLI and XPC retain caller UUID)
  → replay existing caller operation, or read-only source preflight
  → beginProductionStartRoot (expected source and planned target runtime)
  → refreshResolvedAdmissionForStartIfNeeded under that root
      → borrow root for production planning/admission/publication
      → retain exact plan checkpoint for recovery
  → startImplementation
      → startResolvedMachine
          → prepareResolvedMachineStart
              → prepareMachineStart(.resolvedPlan)
              → LaunchPlanResolver.resolve
                  → PlanRepository.read
                  → StartEvidenceCollector.collectFreshEvidence
                      → TrustInventory.startInventory
                      → exact capability evaluation
                  → PlanStartValidator.revalidate
                  → BackendRegistry.plan (the exact selected adapter)
              → recheck manager-owned definition, paths, shares and plan
          → borrow active lifecycle operation / pending start reservation
          → BackendRegistry.start
              → manager-owned adapter operation
                  → spawnPreparedMachine
                      → reserve persisted source + operation + generation
                      → consume pre-spawn authorization
                      → exact resources / helper process boundary
```

## Consolidation performed in this review

`DoryDaemonVirtualMachineStartInventoryRequest` now contains only an immutable resolved plan and validation purpose. It previously carried five separately mutable copies of machine identity, definition revision, plan revision, media reference and capability request. Production inventory compared those copies with the same unchanged plan, adding no fresh authority. Those fields and comparisons are removed. Media-reference presence is still checked; host/runtime verification, artifact resolution, firmware checks, exact admission binding and final pre-spawn revalidation remain.

`DoryResolvedMachinePlan.exactCapabilityRequest` is the shared typed projection for inventory qualification and exact capability evaluation. It constructs the evaluator's six-field request from the selected plan; it is not another stored authority or backend selector.

The fresh evidence collector also now includes the plan's forwarded ports. Previously its manually constructed runtime evidence defaulted that field to an empty list, rejecting every valid nonempty forwarding plan. Tests using `DoryResolvedMachineRuntimeEvidence(plan:)` concealed this because that initializer already copied the ports. The field is now required when constructing fresh evidence, so omission fails compilation. The added regression invokes the actual collector and resolver for launch, running preflight and stopped preflight, verifies exact forwarding/digest, and consumes the purpose-bound token once.

`DoryControlPlaneArchitectureTests` examines SwiftPM target dependencies, including transitive reachability. `DoryVMContracts`, `DoryExecutionContracts`, `DoryFirmware`, `DoryOperations` and `DoryCore` cannot reach daemon or runner composition. Daemon/CLI entrypoints cannot reach `DoryVMMKit`; the helper must consume it. This is a module dependency gate, not a source-wording check. The app Xcode product depends on DoryOperations; its DoryVMMKit dependency belongs to the helper target. Separate app transport tests exercise operation UUID and readiness projections.

## Checks retained intentionally

| Check | Reason to retain it |
| --- | --- |
| Plan decode/validation at repository read | Persisted bytes may have changed or use an unsupported schema. |
| Exact plan/current-definition revision and digest comparison | Desired state can change between planning and launch. Resource/topology/persistence comparisons provide specific failures. |
| Fresh boot/artifact/runtime/qualification/admission evidence | External paths, signatures, lease state, host capacity and policy can change after planning. |
| Manager verification of resolver output | The resolver is a replaceable protocol dependency. A returned adapter plan must still match the manager's current source and intended runtime projection. |
| Manager reread immediately before spawn | Workspace files, share authority and plan publication can change after the initial read. |
| Atomic launch reservation | In-memory state, active operation UUID or helper generation can change after validation. |
| Single-use pre-spawn revalidation | The resolver's initial inventory does not freeze executables, artifact paths, host state or capacity until process creation. |
| Runner envelope/resource validation | The helper is a separate process receiving encoded authority and inherited descriptors. |

Public controller and coordinator entrypoints validate an untrusted request once, then carry `DoryDaemonValidatedPlanningTransaction` and `DoryDaemonValidatedPlanningRequest` through the concrete internal path. An independently called public API still validates its input. Injected protocol implementations remain a boundary that must validate independently; the concrete production composition reuses the validated value.

Creation and restore reuse `DoryMachineArtifactProof` only within one owned mutation context. It retains descriptors, exact artifact bindings and filesystem identity/change stamps minted during the first full hash. Snapshot publication carries its own private validated result. Fresh recovery hashes again; no journal checkpoint can recreate these in-memory proofs. Each artifact publication syncs its retained destination directory before the caller records durable progress. Mutable guest backing checks retain identity, ownership and length while permitting legitimate guest writes; immutable artifacts retain full content checks.

## Retained boundaries

| Path | Current restriction and purpose |
| --- | --- |
| `startLegacyMachine`, diagnostic constructors and qualification bootstrap | Compiled only in DEBUG. Release exposes the strict production manager; unavailable trust cannot enable compatibility launch. Legacy records migrate before resolved planning, retaining source bytes on rejection. |
| Historical `ProductionTrustFactory.resolve` | Retains trust/readiness and migration classification. Its alternate manager/adapters/resolver composition is isolated in DEBUG-only `resolveDiagnosticPlanningComposition`; production uses `activate`. |
| `resolvedLaunchCompatibilityOperations(for:)` | Production adapter callbacks consume the manager's pending exact plan and operation. They bind the adapter back to process ownership and cannot select a legacy launch. |
| Native definition → `DoryMachineConfiguration` projection | Supplies existing helper/path interfaces. Launch reservation compares the separate exact persisted source, so projected settings cannot replace workspace authority. |
| Creation, clone, snapshot and restore | Typed durable roots bind caller UUID, source/target identities and private recovery payloads. Clone plans the new destination identity; restore keeps backups until exact target plan, power state and readiness are established. |
| Restart, configuration, installer and desktop updates | Planning, quiescence, launch and compensation borrow one root operation. Cancellation closes before irreversible publication; rollback authenticates and observes the source helper before replacing its state. |

Unchanged configuration requests validate caller identity and preserve the current runtime, admission and journal without replanning. Suspend, pause and resume retain the caller UUID through app/CLI/XPC; completed power-operation replay observes current state without mutating a newer runtime. Saved-state readmission reuses the exact persisted plan and binds a fresh admission transaction before execution. Native saved-memory continuation after guest writes still requires the P08 artifact-continuity and physical-guest qualification gates.

Ordinary app start and maintenance no longer acquire or replace managed kernels through a separate refresh endpoint. Kernel changes use the explicit desktop-update operation. Backup verification receives a stopped planned clone, starts it under a distinct caller UUID, waits for owned readiness, and cleans up only that accepted clone.

The module-dependency gate, public-operation campaigns and final Release symbol audit are complementary. None alone establishes physical guest or release qualification, which remains assigned to later phases in PLAN.md.
