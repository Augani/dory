# P01 authority and launch call graph

Reviewed against the working tree on 2026-09-04. This inventory supports P01-04/P01-13; it does not close either item or qualify physical guest execution. Function names below identify implementation boundaries without depending on changing source line numbers.

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

MachineManager.start
  → current authority and admission checks
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
          → one lifecycle operation / pending start reservation
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

`DoryControlPlaneArchitectureTests` examines SwiftPM target dependencies, including transitive reachability. `DoryVMContracts`, `DoryExecutionContracts`, `DoryFirmware`, `DoryOperations` and `DoryCore` cannot reach daemon or runner composition. Daemon/CLI entrypoints cannot reach `DoryVMMKit`; the helper must consume it. This is a module dependency gate, not a source-wording check. The app Xcode dependency graph and entrypoint behavior require their own evidence.

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

Public planning controller, transaction coordinator and standalone planning coordinator still independently call product/definition preflight. Some calls see the same immutable definition during one production invocation, but each API remains independently callable today. Removing those checks requires a validated, unforgeable internal request path while retaining validation at each public entrypoint; deleting calls alone would weaken standalone entrypoints. This remains a concrete P01-04 follow-up outside the request-copy cleanup.

## Compatibility paths and removal gates

| Retained path | Current authority restriction | Evidence required before removal |
| --- | --- | --- |
| `MachineManager.startLegacyMachine` and `.legacyCompatibility` preparation | Explicit compatibility launch policy plus `allowsLegacyCompatibilityLaunches`; current runtime identity must also be compatibility mode. Normal `.perWorkspaceAuthority` start rejects that identity until production planning succeeds. | Migrate direct manager/qualification callers and prove all three cells' upgraded-account create/start/restore/clone flows. Preserve source bytes on failed migration. |
| Daemon startup fallback in `Sources/doryd/main.swift` | Normal fallback sets compatibility launch/create flags false. The explicit qualification-bootstrap environment option enables them and cannot acquire production support authority. | Replace the bootstrap/qualification composition with exact plan fixtures, then remove the alternate launch policy. Unavailable production trust must remain a visible failure. |
| `resolvedLaunchCompatibilityOperations(for:)` | Production adapters use these manager callbacks to consume an already prepared exact plan. The name does not mean they may choose a legacy launch. | Refactor the callback interface together with adapters/pending-start ownership; do not remove the only path that binds adapter start back to the manager's pending plan. |
| Native definition → `DoryMachineConfiguration` runtime projection | Still supplies existing helper/path APIs. The reservation compares the separate exact persisted source; projected environment/settings are not persisted as replacement authority. | Replace legacy helper inputs after all runner and app/CLI operations consume typed plan resources directly. Include software/accelerated settings and snapshot restoration parity. |
| Clone/snapshot recovery construction | Clone creates a new machine/disk identity and requires production planning; source launch authority is history. Snapshot restore validates saved ABI/artifacts and replans as required. | Complete public migration/restore/clone campaigns; retain originals on rejection and reject unsafe in-place conversion. |
| Compound operation callbacks | Restart and production installer work retain one parent operation through their subordinate planning/launch phases. Desktop update and remaining direct compatibility operations are being consolidated separately. | Verify one durable UUID, idempotent replay, cancellation and process-death recovery for each compound operation before deleting legacy transaction/recovery stores. |

Passing this dependency test or the focused collector tests does not prove the compatibility removal gates. P01-04/P01-13 remain open until those owners and behavioral campaigns are complete.
