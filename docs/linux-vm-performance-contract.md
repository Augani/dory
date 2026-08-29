# Linux VM performance and release-evidence contract

- **Status:** Proposed normative Linux release contract; budget calibration is not complete
- **Date:** 2026-08-23
- **Scope:** Native ARM64 Linux virtual workspaces on Apple-silicon hosts
- **Applies to:** VZ generic ISO/UEFI and any separately qualified RawHV managed direct-boot cell
- **Related qualification contract:**
  [`container-engine-performance-qualification.md`](container-engine-performance-qualification.md)

## Decision

Dory will qualify Linux VM performance with one candidate-bound evidence model spanning the host
application, daemon, selected VMM, isolated helpers, host kernel, guest kernel, guest userspace, and
the user's end-to-end interaction. A fast guest microbenchmark, a renderer counter, or a host
process sample is useful diagnostic evidence; none of them alone is a product performance claim.

The product objective is a consistently fast **whole VM**, independent of distribution branding.
Every exact Linux media cell Dory publishes as supported MUST satisfy the same applicable product
budgets for its backend, resource class, and requested capability tier. A distribution-specific
shortcut, guest mutation, or favorable benchmark cannot waive boot, responsiveness, tail-latency,
CPU, memory, storage, network, input/display, filesystem, GPU, durability, or endurance evidence.

This document defines the evidence vocabulary, metric ownership, campaign matrix, and budget
lifecycle. It deliberately does **not** publish latency, throughput, CPU, or memory thresholds.
Those values must be derived from reproducible physical baselines and user-impact research, then
frozen before a release candidate is tested. Until that calibration is complete, Dory can collect
diagnostic evidence but cannot call the Linux VM performance gate passed.

The existing
[`container-engine-performance-qualification.md`](container-engine-performance-qualification.md)
remains the contract
for matched Dory container-engine campaigns. This document adds an absolute Linux VM product
contract. Container-engine parity, even when qualified, cannot substitute for desktop VM boot,
input, display, GPU, storage-durability, or sustained-resource evidence.

### Current diagnostic baseline

The 2026-08-26 physical Developer-ID calibration supersedes the earlier functional graphics
failure without creating a release-performance result. On Mac14,10/macOS 27 build 26A5416b, the
repaired dual VirGL2/Venus tuple booted managed Ubuntu GNOME and remained live for more than 15
minutes. Direct accelerated VirGL rendered a 35-second `glxgears` workload at approximately
147–157 FPS. Venus Vulkan 1.3 created an XCB surface and FIFO swapchain, then acquired, rendered,
submitted, presented, and reached idle. Exact Zed 1.16.1 mapped Dory's Venus driver and sustained a
mapped window for 30 seconds while Firefox and ordinary GNOME applications remained usable. No
rejected `RESOURCE_FLUSH`, device-lost, renderer-fatal, or GPU-quiescence error was observed.

This proves the repaired functional path for that exact calibration tuple. The evidence artifact
still declares `not-release-qualifying`: it is neither the release-signed/notarized candidate nor a
complete campaign with frozen absolute budgets, multi-host repetitions, fault injection, and
resource/thermal samples. Accordingly, the observations above are diagnostic values, not published
performance thresholds or a public support claim.

## Normative language and non-goals

`MUST`, `MUST NOT`, `SHOULD`, and `MAY` are normative.

- Correctness, trust, and durability gates run before performance gates. A fast corrupted frame,
  lost write, dropped input event, or unproven renderer is a failed observation, not a performance
  win.
- An absolute budget is a versioned product limit or floor. A comparison with another backend or
  release is supplementary and cannot replace it.
- Missing mandatory evidence is `unavailable` and fails release qualification. It MUST NOT be
  encoded as zero, omitted, estimated, or inferred from a neighboring layer.
- VZ and RawHV results MUST remain separate matrix cells. They have different firmware, boot,
  storage, sharing, display, and telemetry mechanisms.
- A software-rendered result MUST remain a software-rendered result. It cannot satisfy an
  accelerated budget even when it is functionally correct.
- This contract does not claim that every ARM64 ISO is compatible, that guest GPU access is
  passthrough, or that source code containing a device implementation proves production support.
- Compatibility admission and performance admission are conjunctive. An exact ISO that boots but
  misses an applicable whole-VM budget is not Supported; a fast exact ISO does not project its
  result onto another release, kernel, desktop, filesystem, backend, or device tuple.
- Fast paths MUST be protocol- and capability-driven rather than keyed to distribution names.
  Optional guest integration may improve an already truthful tier, but the supported baseline
  cannot rely on an undocumented distro-specific tuning branch.
- Performance work MUST NOT weaken descriptor validation, isolation, durability, lifecycle, or
  fallback truth to improve a score.

## Evidence model

### Stable terms

| Term | Meaning |
|---|---|
| Candidate | One immutable, signed set of Dory and guest-facing artifacts plus its release configuration |
| Matrix cell | One exact host, guest, backend, resource, device, display, network, and workload tuple |
| Observation | One raw measured value with an owner, scope, clock, sample identity, and validity state |
| Summary | A deterministic aggregation over named observations; never the only retained evidence |
| Budget | A versioned absolute acceptance rule bound to a metric definition and applicable matrix cells |
| Budget set | Canonical collection of budgets frozen before release-candidate measurement |
| Fallback | A requested capability that resolved to a lower-quality or unavailable implementation |
| Qualifying run | A run whose candidate, host, guest, tools, campaign, clocks, and raw evidence are all bound |

Metric IDs are stable semantic identifiers, for example `ux.boot.login-ready.duration` or
`host.vmm.physical-footprint.peak`. Changing an endpoint, unit, scope, workload, aggregation, or
validity rule requires a new metric-definition revision. Renaming the label is not sufficient.

### Machine-readable bundle

Every campaign MUST emit canonical JSON plus referenced raw samples and logs. The normative shape
is below; concrete JSON Schema and signature-envelope versions may add fields only through a
reviewed schema revision. Unknown enum values fail closed for release qualification.

```json
{
  "schemaVersion": 1,
  "kind": "dev.dory.linux-vm-performance-evidence",
  "qualificationMode": "calibration",
  "candidate": {
    "componentCandidateInventorySHA256": "<canonical unqualified component candidate inventory>",
    "applicationSHA256": "<notarized Dory application>",
    "sbomSHA256": "<candidate-bound SBOM>",
    "runtimePlanSHA256": "<resolved operation-bound launch plan>",
    "virtualHardwareABIVersion": "<version>",
    "budgetSetSHA256": "<canonical budget set>",
    "codeSignatureEvidence": "evidence/candidate-signatures.json"
  },
  "host": {
    "architecture": "arm64",
    "identity": "evidence/host.json",
    "powerAndThermalState": "evidence/host-state.json",
    "displayTopology": "evidence/display.json",
    "storageTopology": "evidence/storage.json",
    "noiseControls": "evidence/noise-controls.json"
  },
  "guest": {
    "installerSHA256": "<exact ISO>",
    "installerSignatureEvidence": "evidence/installer-signature.json",
    "architecture": "arm64",
    "installedSystemIdentity": "evidence/guest-system.json",
    "kernelSHA256": "<booted kernel>",
    "initrdSHA256": "<booted initrd or null>",
    "guestToolsSHA256": "<tools or null>",
    "mesaAndRendererClientIdentity": "evidence/guest-graphics.json"
  },
  "launch": {
    "operationID": "<UUID>",
    "planGeneration": 1,
    "backend": "vz",
    "resources": "evidence/resources.json",
    "devices": "evidence/devices.json",
    "graphicsSelectionReceipt": "evidence/graphics-selection.json",
    "graphics": {
      "accelerationEvidence": null,
      "requestedQuality": "software",
      "selectedQuality": "software",
      "implementation": "software",
      "fallback": false,
      "fallbackReason": null,
      "selectionReceiptSHA256": "<selection receipt>",
      "accelerationEvidenceSHA256": null
    }
  },
  "campaign": {
    "definitionID": "linux-desktop-interactive",
    "definitionRevision": 1,
    "harnessSHA256": "<harness tree>",
    "workloadSHA256": "<immutable workload corpus>",
    "matrixCellID": "<canonical tuple digest>",
    "matrixCellDescriptor": "evidence/matrix-cell.json",
    "samplingPlan": "evidence/sampling-plan.json",
    "clockCalibration": "evidence/clocks.json"
  },
  "observations": "raw/observations.jsonl",
  "summaries": "summary/metrics.json",
  "fallbacks": "summary/fallbacks.json",
  "unavailableEvidence": "summary/unavailable.json",
  "verdict": "not-release-qualifying",
  "signature": "signatures/evidence-bundle.sig"
}
```

The bundle MUST also contain a canonical file inventory with each path, byte length, and SHA-256
digest. The detached signature covers that inventory, the evidence manifest, and the candidate and
budget-set bindings. Raw observations remain inspectable; a summary JSON file is not sufficient.

The first structural gate is
[`validate-linux-vm-performance-evidence.py`](../scripts/validate-linux-vm-performance-evidence.py).
It accepts one canonical schema-1 evidence manifest and one canonical schema-1
`dev.dory.linux-vm-performance-budget-set`, hashes the exact canonical budget-set bytes into the
candidate binding, and rejects duplicate keys, unknown/missing fields, unsafe bundle paths,
non-native architecture, contradictory operation/graphics/fallback classification, and
provisional or unapproved qualification. It remains intentionally a **pre-signing structural
validator**. Passing it does not prove that a referenced file exists, that a summary came from the
raw samples, that a budget passed, or that any bytes were signed.

The assembled-bundle gate is
[`verify-linux-vm-performance-bundle.py`](../scripts/verify-linux-vm-performance-bundle.py). A
schema-1 bundle has fixed root files `bundle-inventory.json`, `evidence-manifest.json`, and
`budget-set.json`. Its inventory is canonical JSON with this exact authority shape:

```json
{
  "budgetSet": "budget-set.json",
  "evidenceManifest": "evidence-manifest.json",
  "files": [
    {"bytes": 1, "path": "...", "sha256": "..."}
  ],
  "kind": "dev.dory.linux-vm-performance-bundle-inventory",
  "schemaVersion": 1
}
```

Inventory paths are sorted and unique. Every payload other than the inventory itself and its
necessarily non-circular detached signature is inventoried; the actual regular-file set MUST equal
that declared set plus those two files. The verifier opens the root and every descendant
descriptor-relative without following symbolic links, rejects indirect roots, hard links, special
files and untracked files, and checks each declared byte count and SHA-256. The detached Ed25519
signature authenticates the exact canonical inventory bytes, which in turn bind the manifest,
budget set, raw observations, summaries, evidence and logs. Release invocation MUST supply the
32-byte public key through `--signature-public-key-base64`; there is no embedded production key and
there is no unsigned release mode. `--signature-verifier` is an integration seam for a trusted
orchestrator, defaulting to Dory's existing CryptoKit verifier. Replacing it is a trust-root change,
not a developer convenience switch.

`evidence/matrix-cell.json` is a canonical
`dev.dory.linux-vm-performance-matrix-cell` projection. Its SHA-256 MUST equal `matrixCellID`.
The assembled verifier reconstructs that projection from the signed candidate identities, exact
installer/kernel/installed-system identities, host identity and stable topology evidence,
backend, resources, devices, graphics-selection/acceleration receipts, harness, workload, and
sampling plan. It rejects a caller-chosen ID, a receipt digest that differs from the inventoried
bytes, or any descriptor field that differs from the signed evidence graph. Dynamic thermal and
clock observations remain separately signed run evidence rather than changing the predeclared
cell identity.

Successful byte and signature verification alone is not publication admission. A release
invocation MUST also pass `--require-release-qualified`; this rejects calibration and failed
bundles. It MUST bind the signed bundle to the candidate being published with all of
`--expected-component-candidate-inventory-sha256`, `--expected-application-sha256`,
`--expected-sbom-sha256`, `--expected-runtime-plan-sha256`,
`--expected-budget-set-sha256`, and `--expected-virtual-hardware-abi-version`. It MUST also bind the
proposed exact support record with `--expected-matrix-cell-id`,
`--expected-installer-sha256`, `--expected-backend`, and
`--expected-selected-graphics-quality`. Supplying only a subset of either group is invalid. Each
value comes from the immutable publication candidate and proposed support record, not from the
bundle being checked. A calibration bundle may authenticate successfully for retained research
evidence, but it can never authorize publication.

The performance bundle deliberately does not bind the final support-bearing component catalog.
Physical qualification runs after immutable candidate assembly and SBOM generation, while
`build-components.py finalize` creates that catalog only after qualification. Requiring its digest
inside the performance bundle would recreate a circular release dependency. Publication instead
proves that the final catalog binds the same component candidate inventory, SBOM, and signed
qualification output.

The clearly labeled fixture under
`scripts/fixtures/linux-vm-performance-bundle-schema1/` carries only a test public key, test
signature, and test budget value. It proves the verifier interface and MUST NOT be used as release
trust material or product calibration evidence.

Schema 1 also closes the minimum observation-to-verdict chain:

- `dev.dory.linux-vm-performance-sampling-plan` binds every metric-definition revision and unit to
  an expected sample count and minimum independent-round count;
- canonical JSONL observations are sorted and uniquely identify their operation, matrix cell,
  round/sample coordinate, endpoint, owner, clock, source evidence, validity, correctness and
  fallback state; source evidence must itself be inventoried;
- `dev.dory.linux-vm-performance-summaries` uses the fixed
  `schema1:all-valid-correct-no-fallback` selection. Its observation IDs, state counts, and
  statistics are recomputed from all planned raw records. Schema-1 percentiles use deterministic
  linear interpolation over sorted values; arithmetic is rounded half-even to twelve decimal
  places, and population coefficient of variation is informational when defined;
- schema-1 frozen budgets may address `minimum`, `lower-quartile`, `median`, `upper-quartile`,
  `maximum`, `mean`, `p90`, `p95`, or `p99`. `atMost`, `atLeast`, and `range` comparisons are
  inclusive and use the recomputed value. An unsupported statistic fails closed rather than
  trusting a supplied summary;
- a missing planned record, insufficient independent rounds, invalid or unavailable applicable
  sample, failed correctness oracle, or fallback makes that applicable frozen budget fail even if
  the remaining numeric values are favorable. A manifest saying `qualified` is rejected when any
  recomputed applicable result fails.

This verifies assembled evidence; it still does not create a collector, a workload, a threshold,
or a performance result. Calibration bundles remain non-release-qualifying even when their bytes
and signature verify.

### Observation semantics

Each observation MUST carry:

- metric ID and metric-definition revision;
- operation ID, matrix-cell ID, campaign round, sample index, workload phase, and warm/cold state;
- value and canonical unit without locale conversion;
- measurement scope and attributed owner;
- source clock ID, raw start/end timestamps when applicable, and clock-calibration reference;
- source evidence reference, such as a signpost interval, guest probe event, trace slice, or tool
  output;
- validity state: `valid`, `invalid`, or `unavailable`, with a reason for the latter two;
- fallback and correctness state at the time of the sample.

Raw time-series and latency samples MUST be retained so percentiles can be recomputed. Counters
MUST include reset epoch and start/end values. A maximum counter is not a latency distribution.
Rates MUST name both the numerator and denominator observations instead of recording an opaque
precomputed number.

### Summary semantics

Summaries MUST name the deterministic observation selection query and include the count, minimum,
lower quartile, median, upper quartile, tail percentiles selected by the metric definition,
maximum, and coefficient of variation where mathematically meaningful. A release budget names the
statistic it evaluates. The harness MUST NOT choose a more favorable statistic after observing a
candidate.

Independent rounds are the unit of inference. High-frequency samples within one boot or workload
do not become independent merely because there are many of them. Position balancing and
interleaving SHOULD be used when comparing backends or releases. The comparative rules already
defined in
[`container-engine-performance-qualification.md`](container-engine-performance-qualification.md)
remain authoritative
for those comparisons.

### Budget states

Each budget has one of these states:

- `provisional`: metric and applicability are under calibration; it has no release authority and
  may have no numeric value;
- `frozen`: contains a finite value or range, unit, direction, statistic, applicability predicate,
  owner, rationale, baseline-evidence digest, approval record, and effective release line;
- `retired`: retained for audit but not evaluated for new candidates.

A frozen budget MUST be absolute: `atMost`, `atLeast`, or `range`. Relative change versus the last
qualified release is a separate regression rule, not the sole product budget. A budget cannot be
frozen from an anecdotal run, a debug build, a mutable workload, or a different matrix cell.

The budget set is canonical, versioned, reviewed, and hashed into the candidate campaign before
release measurements begin. Observing a failing candidate is not permission to move the budget.
Any changed endpoint, statistic, applicability, or value creates a new reviewed budget-set
revision with new baseline evidence.

## Immutable candidate controls

Release evidence MUST bind all performance-affecting authorities, including:

- the notarized Dory app, `doryd`, VMM executable, schema-3 dual VirGL2-plus-Venus signed XPC
  renderer worker and its exact virglrenderer, XPC-local ANGLE Metal, MoltenVK, and guest-Mesa
  inventory, filesystem worker, networking helper, guest agent, guest tools, kernel, initrd,
  Mesa/client stack, guest loader closure, firmware, and all relevant code signatures,
  entitlements, and hashes;
- the canonical unqualified component inventory and its SBOM/attestation association;
- the operation-bound resolved plan, plan generation, backend, virtual-hardware ABI and topology,
  CPU and memory assignment, disk attachment/cache/durability policy, shares, network mode, audio,
  input devices, display count/resolution/scale, and graphics selection receipt;
- the exact installer digest and publisher-signature verification, installed package state,
  filesystem, desktop environment, kernel command line, services, power policy, and workload tree;
- the qualification harness, workload assets, configuration, collection tools, and budget set;
- host model/SoC, installed memory, macOS build, boot identity, power source/mode, thermal state,
  free storage, storage topology, display topology, and relevant accessibility/input settings.

Environment variables and persisted legacy flags are never performance authorities. They may be
recorded as migration inputs, but the running operation's typed plan and receipts define what was
measured. Any mismatch invalidates the run.

Signing the final manifest is necessary but insufficient. The collector MUST resolve process and
helper identities through the operation-bound launch graph, validate code identity and start time,
and reject evidence produced after any participant has been replaced or restarted outside the
recorded generation.

## Host-versus-guest attribution

### Ownership scopes

Every metric belongs to one or more explicit scopes:

| Scope | Examples |
|---|---|
| `product-ui` | Dory window, launch action, visible readiness/fallback state |
| `control-plane` | `doryd`, plan resolution, validation, staging, lifecycle journal |
| `vmm` | VZ process or RawHV runner, vCPU execution, device emulation |
| `renderer-worker` | graphics decoding, submission, synchronization, presentation resources |
| `filesystem-worker` | VirtioFS request execution, cache/invalidation work |
| `network-helper` | gvproxy/NAT helper processing and buffers |
| `host-kernel` | virtualization, networking, filesystem, scheduling pressure not attributable to a user process |
| `guest-kernel` | vCPU accounting, pressure stalls, block/net/device work |
| `guest-userspace` | desktop shell, compositor, services, application, workload cgroup |
| `end-to-end` | user action through observable correct result |

The host process set MUST be constructed from the operation's launch receipt and supervised child
relationships, not names, regular expressions, or a single PID. PID plus process start time and
code identity prevent PID-reuse attribution. Short-lived launch and helper processes remain part of
the operation.

Host CPU MUST report per-owner CPU time and wall time for the complete process set, plus system
pressure/context needed to detect busy waits. Guest CPU MUST report workload and system cgroup
usage and Linux pressure. A low guest CPU value does not prove efficiency if a host helper is
spinning; a low host value does not prove guest responsiveness during guest memory or I/O stalls.

Host memory MUST use attributable physical-footprint semantics for every participant and state the
shared-memory allocation rule. Summing each process's resident set can double-count shared VM,
renderer, or file mappings and is not a valid product footprint. Guest memory is reported
separately through cgroup and `/proc` evidence; configured guest RAM is neither host footprint nor
guest working set.

Linux Pressure Stall Information and cgroup-v2 `cpu.stat`, `memory.current`, `memory.stat`,
`memory.events`, and pressure files SHOULD provide guest attribution when available. The guest
probe records kernel support and controller delegation; unsupported fields are `unavailable`, not
zero. See the Linux kernel's primary [PSI documentation](https://docs.kernel.org/accounting/psi.html)
and [cgroup v2 documentation](https://docs.kernel.org/admin-guide/cgroup-v2.html).

### Clock domains

macOS continuous/monotonic time, a VMM clock, renderer timestamps, guest monotonic time, and device
timestamps are different domains. The evidence bundle MUST name every clock and record a
calibration model with offset, drift, sample interval, and error bound. Cross-domain latency is
valid only when the error bound is materially smaller than the measured budget margin. Otherwise
the result is `unavailable`, or the endpoints must be moved into one clock domain.

Host phases SHOULD use signposted operation intervals. Apple's
[performance-data guidance](https://developer.apple.com/documentation/os/recording-performance-data)
describes structured signpost intervals. Host footprint collectors SHOULD use the operating
system's task footprint interfaces rather than plain RSS; Apple documents relevant fields in
[`task_vm_info_data_t`](https://developer.apple.com/documentation/kernel/task_vm_info_data_t).

## Qualification matrix

### Host and configuration dimensions

The frozen campaign specification selects representative cells from these dimensions. Exact
values come from calibration and supported-product policy, not this document.

- every Apple-silicon family Dory claims, with the lowest supported memory configuration and at
  least one higher-resource configuration;
- every supported macOS major/build family used for the release claim;
- AC and battery/power-mode states when Dory claims equivalent availability;
- internal storage and every external/data-drive class Dory supports;
- single and multiple displays, supported scale factors and pixel counts, windowed/full-screen,
  visible/occluded, and resize/hotplug cases;
- each supported CPU/memory tier, disk policy, network mode, sharing mode, audio direction, and
  input-device set;
- VZ and RawHV as separate cells, never pooled. RawHV applies only to a boot bundle and device set
  its current contract supports.

The campaign records host quiescence and invalidates thermally constrained, power-transitioning,
storage-starved, update-active, or otherwise contaminated runs. Noise controls and invalidation
rules are written before collection. Runs are not silently discarded for being slow.

### Representative native ARM64 installer matrix

The matrix uses official, native AArch64 media. Exact releases, publisher signature material, and
SHA-256 digests are frozen with each candidate. A row is eligible only after Dory's bounded media
inspector establishes AArch64 EFI compatibility and a smoke install confirms the requested device
contract. Presence in this research matrix is not a support promise.

The Ubuntu, Debian, Fedora, and openSUSE families form the mandatory representative baseline once
an eligible exact release has been selected. The enterprise-compatible row is an additional
rotating family. A failed eligibility smoke is recorded and investigated; it is not silently
replaced with an easier ISO. Public compatibility remains narrower than or equal to the exact
media cells that subsequently pass the complete qualification contract.

The representative matrix calibrates implementation breadth; it is not a sampling license for
the support catalog. Every additional exact installer digest admitted to the published catalog
must run its applicable complete whole-VM campaign. Dory may publish a narrower supported catalog,
but it may not publish a broad compatibility claim by extrapolating from one distribution family.

| Family selector | Official primary source | Representative reason | Required campaign path |
|---|---|---|---|
| Supported Ubuntu LTS ARM64 Server, default page-size installer | [Ubuntu ARM server downloads](https://ubuntu.com/download/server/arm) and [ARM64 installer page-size guidance](https://ubuntu.com/server/docs/how-to/installation/choosing-between-the-arm64-and-arm64-largemem-installer-options/) | Widely deployed Debian/systemd base; explicitly avoids conflating default and large-page kernels | VZ ISO/UEFI install, desktop provisioning, reboot, update, workload; RawHV only after an exact installed boot bundle qualifies |
| Debian stable arm64 netinst or DVD | [Debian network-install media](https://www.debian.org/CD/netinst/) | Minimal installer, selectable desktop, conservative kernel/userspace | VZ ISO/UEFI install through selected desktop and workload |
| Fedora current stable Server aarch64 DVD/network installer | [Fedora Server downloads](https://fedoraproject.org/server/download/) | Faster kernel/Mesa cadence and SELinux-enforcing RPM family | VZ ISO/UEFI install, desktop package selection, update, workload |
| openSUSE Leap AArch64 offline or network installer | [openSUSE Leap downloads](https://get.opensuse.org/leap/) | Independent installer, RPM/Btrfs/system-management path | VZ ISO/UEFI install, selected desktop/filesystem, update, workload |
| Supported enterprise-compatible AArch64 rotation | [Rocky Linux downloads](https://rockylinux.org/download) or [AlmaLinux downloads](https://almalinux.org/get-almalinux/) | Long-lived enterprise kernel/userspace and installer behavior | One publisher is selected and frozen per release campaign; VZ path first |

Apple's official Virtualization framework guidance requires guest media to match the Mac CPU
architecture; the [GUI Linux VM sample documentation](https://developer.apple.com/documentation/virtualization/running-gui-linux-in-a-virtual-machine-on-a-mac)
is the mechanism reference, not proof that a particular distribution/device tuple is supported.

The VZ path is mandatory for generic ARM64 ISO/UEFI claims. RawHV does not execute an installed
disk's EFI path; its evidence begins only after a verified direct-boot bundle is created. A RawHV
result cannot be projected onto arbitrary installed media or an installer path.

### Workload phases

Every release campaign includes independently identifiable phases:

1. media verification/import and VM creation;
2. installer start, complete interactive install, media eject, and first installed boot;
3. cold boot, warm boot, login, desktop readiness, network readiness, tools readiness, and clean
   shutdown;
4. representative interactive application use, including browser, editor, terminal/build, media,
   package update, shared-folder, storage, and network work;
5. display resize/full-screen/multi-display, input stress, audio, clipboard, share reconnect, and
   network change where claimed;
6. suspend/wake, host sleep/wake, snapshot/restore where supported, guest reboot, forced failure,
   recovery, and repeated lifecycle/endurance cycles.

Named readiness facts are mandatory. A process start, first frame, generic `running` state, or
successful agent socket alone is not desktop readiness.

## Absolute metric catalog

The catalog below defines required measurement families and endpoints. Frozen budget values are
added only after calibration. Each budget's applicability selects the matrix cells for which the
metric is mandatory.

### User experience and lifecycle

- import request to verified-media result, including inspection and digest phases;
- create request to installer UI ready and correct at the intended resolution;
- boot request to guest-kernel start, display-manager ready, login UI ready, successful login,
  desktop interactive, network ready, guest-tools ready, and first application interactive;
- resume/wake request to correct interactive frame, input acceptance, network recovery, share
  recovery, and audio recovery;
- shutdown request to guest acknowledgement, device quiescence, process exit, and durable final
  state;
- failure/retry UI latency and time to a truthful, actionable terminal state;
- lifecycle success rate and the distribution of each named duration, with cold and warm results
  separated.

### CPU and scheduling

- host CPU time and wall-time utilization for product UI, daemon/control plane, VMM, renderer,
  filesystem worker, network helper, and complete operation tree during each phase;
- host wakeups, context switches, run-queue/pressure indicators, and idle cost while a VM is idle,
  visible, occluded, and suspended;
- guest total and per-cgroup CPU usage, throttling, runnable/blocked pressure, workload completion,
  and idle cost;
- vCPU oversubscription/configuration and host-versus-guest CPU attribution for storage, network,
  shared-folder, display, and GPU workloads;
- CPU cost per completed unit of useful work, with correctness and bytes/items definitions bound
  to the workload.

### Memory and reclaim

- configured guest RAM, guest `memory.current`, anonymous/file/slab breakdown, pressure, swap,
  reclaim, OOM/events, and workload peak;
- attributable host physical footprint and peak for every operation owner plus the deduplicated
  product total;
- renderer/display resident and peak resource bytes, shared-memory mappings, scanout count and
  dimensions, and retained resources after resize or VM shutdown;
- balloon target/actual state, reclaim progress and latency, guest pressure response, and workload
  impact;
- idle settling, repeated boot/resize/workload-cycle growth slope, and post-shutdown residual
  footprint. A leak result needs a time series, not two hand-selected endpoints.

### Storage and shared filesystems

- install, boot, application, package-manager, compiler, and shared-folder read/write/metadata
  completion times;
- sequential and random throughput, operation rate, and latency distributions for read, write,
  mixed, sync, flush/fsync, discard, and queue-depth profiles selected during calibration;
- durability acknowledgements, flush errors, maximum observed flush latency plus the underlying
  latency samples, reset/recovery behavior, and post-crash filesystem/application verification;
- virtual-disk logical size, host allocated bytes, guest used bytes, growth during workload,
  reclaim/trim effectiveness, snapshot growth, and storage amplification;
- shared-folder create/read/write/rename/delete, metadata, permissions, links, invalidation and
  concurrent host/guest coherence, with correctness hashes before timing;
- host CPU and footprint per useful I/O unit so cache- or copy-heavy mechanisms are not rewarded
  solely for guest-visible throughput.

The workload SHOULD emit machine-readable fio output where fio is used. The official
[fio documentation](https://fio.readthedocs.io/en/latest/fio_doc.html) defines latency percentiles,
JSON output, and steady-state controls; every job file and fio version is candidate evidence.

### Network

- controlled host/guest, LAN, and external paths as distinct campaigns; NAT and any host-only mode
  remain distinct cells;
- TCP forward/reverse throughput, retransmissions, congestion/window evidence, and VMM/helper/guest
  CPU per transferred byte across calibrated stream and payload profiles;
- UDP delivered throughput, loss, reordering, and jitter where the product claims the workload;
- ICMP or application round-trip latency distributions on controlled paths;
- DNS, connect, TLS, first-byte, and complete-transfer phases for external workflows, with fixed
  endpoint identity and response digest;
- sleep/wake, host-network change, VPN-compatible environments, helper restart, backpressure, and
  reconnect behavior, including drops and time to truthful recovery;
- device/helper counters for malformed packets, queue drops, backlog, socket errors, and deferred
  work. Correctness faults invalidate the performance observation.

iperf3 evidence records both endpoint views and machine-readable output. Its official
[invocation documentation](https://software.es.net/iperf/invoking.html) describes JSON/server output
and omitted warmup intervals; endpoint version, options, CPU, and topology are frozen inputs.

### Input

- host event injection to guest-device receipt, guest receipt to compositor/application handling,
  handling to first changed presented frame, and end-to-end latency when clock calibration permits;
- keyboard press/release ordering, repeats, modifiers and layouts; absolute pointer movement/click,
  relative movement where supported, drag, capture/release, and scroll direction/cadence;
- event loss, duplication, reordering, backlog, coalescing, and recovery through resize, focus,
  full-screen, high-rate input, suspend/wake, and device reset;
- latency distributions and maximum observed stalls for each stage. A visually plausible result
  without device/application receipts is not valid input evidence.

### Display and presentation

- first correct-size frame, login-to-desktop transition, application first useful frame, resize
  settle, full-screen transition, scale change, display attach/detach, and wake-to-frame;
- presented-frame intervals, missed/superseded/duplicate frames, long stalls, wrong-size frames,
  damage area, bytes copied per frame where observable, and presentation queue depth;
- host VMM/renderer CPU and physical footprint versus pixel count, display count, scale, frame
  cadence, visible/occluded state, and CPU versus accelerated scanout path;
- frame correctness/integrity evidence for text, transparency, color, cursor, video, resize, and
  sustained application workloads. A frame counter is not proof of a correct frame.

Wayland core frame callbacks only tell a client when it is appropriate to draw again; they are not
an end-to-end presentation receipt. The primary [Wayland protocol specification](https://wayland.freedesktop.org/docs/html/apa.html)
defines that boundary. Dory MUST name the actual compositor/presentation endpoint used for every
display-latency metric.

### GPU and renderer

- requested and selected graphics mode, operation-bound selection receipt, backend and exact host
  renderer/guest client tuple, API version, driver/vendor/device/renderer strings, capsets and
  feature probes;
- explicit software-renderer detection, including llvmpipe or other CPU fallbacks, and the reason
  selected;
- correctness and frame-time distributions for representative editor, browser/WebGL, Vulkan/OpenGL,
  compositor, video and stress workloads chosen during calibration;
- shader/pipeline compilation, command submission, producer/consumer fence wait, presentation,
  device-loss/recovery, timeout, reset, dropped-frame, rejected-allocation, and protocol-fault
  evidence;
- renderer/VMM CPU, host GPU/resource residency where the platform can attribute it, shared-memory
  bytes, scanout resources, copy/upload bytes, and resource release after workload and shutdown;
- screenshot/frame-hash or semantic rendering oracles that prove workload output, not only API
  availability or a high frame count.

An accelerated observation is admissible only when the signed renderer receipt proves the exact
tuple, resource lease, producer-fence handoff, presentation ownership, and operation generation.
Absent proof makes the accelerated metric `unavailable`; it does not become software or inferred
acceleration. Vulkan timing queries and synchronization semantics are defined by the primary
[Vulkan specification](https://registry.khronos.org/vulkan/specs/latest/html/vkspec.html), but Dory
must still bind them to its cross-process and presentation receipts.

### Audio and completeness

When audio is claimed, collect output/input start, underrun/overrun/drop, latency and drift across
idle/load/suspend/reconnect, with a loopback or other correctness oracle. Clipboard, guest tools,
USB, shares, and other claimed devices likewise require task duration, correctness, recovery, host
cost, and visible availability evidence even when they do not yet receive an independent numeric
budget.

## Visible fallback contract

Fallback is part of the measured product behavior, not a hidden benchmark configuration.

- The resolved plan and UI MUST expose requested capability, selected implementation, quality
  level, reason, known effect, qualification state, and operation generation.
- The running receipt, status projection, telemetry and evidence bundle MUST agree. A mismatch
  invalidates the campaign and stops the release gate.
- Accelerated and software-rendered observations use different metric applicability and summary
  groups. They MUST NOT be pooled or averaged.
- If a mandatory accelerated matrix cell falls back, its accelerated evidence is unavailable and
  that cell fails. The software path may be evaluated separately for its own visible-fallback
  contract.
- If no supported implementation satisfies a requested mandatory capability, Dory fails before
  launch or obtains an explicit user choice through the product surface. It does not silently
  change the workload's meaning.

## Calibration, budget freeze, and release use

### Instrument calibration

Before proposing budgets, the team MUST:

1. freeze workload definitions and correctness oracles;
2. validate collectors against known synthetic events and resource allocations;
3. characterize clock offset, drift, and error across host, guest and renderer domains;
4. prove process-tree attribution across helper start, restart, failure, and shutdown;
5. prove that counter resets, missing fields, fallback, thermal invalidation and partial logs fail
   closed;
6. run repeatability studies for every representative matrix cell and investigate multimodal or
   high-variance results rather than hiding them in one average.

Calibration bundles are signed and retained but say `qualificationMode: calibration` and cannot
authorize a public claim.

### Baseline and budget proposal

Baseline campaigns run the exact intended release configuration on the representative physical
matrix with predetermined rounds, warmup, order, environment and invalidation rules. They retain
all valid and invalid raw runs. The team combines those distributions with explicit user-impact
research to propose each absolute budget and records:

- metric definition and applicability;
- selected statistic/direction and proposed value;
- baseline evidence digest and distribution summary;
- user-impact rationale and known measurement error;
- owner, reviewer, approval, effective release line, and remediation path.

This is where numeric values are created. They MUST NOT be copied from unrelated VMs, container
campaigns, developer laptops, marketing expectations, or this architecture document.

### Freeze

The reviewed budget set is canonicalized, signed, and committed before the release candidate is
measured. The release candidate embeds or references its digest. Harness, workload, matrix,
candidate, or budget drift starts a new campaign; it is not an in-place correction.

Regression checks against the last qualified release and diagnostic backend comparisons are then
evaluated in addition to the absolute budgets. A release must pass both applicable classes. When a
budget genuinely needs revision, a new baseline/approval record explains why; the failing
candidate's result remains in history.

### Release verdict

A Linux VM performance verdict is release-qualifying only when:

- candidate, budget-set, host, guest, plan, helpers, workload, and raw-evidence bindings verify;
- the exact installer digest, backend, capability tier, host class, and virtual-hardware ABI map to
  exactly one support-catalog record, and that record carries this verified bundle-inventory
  digest;
- the set of performance-qualified records equals the set of Linux records the candidate proposes
  to publish—missing, duplicate, extra, or extrapolated media cells fail the release;
- all prerequisite correctness, security, durability, lifecycle and capability gates pass;
- every applicable mandatory frozen budget passes;
- no mandatory evidence is invalid or unavailable;
- fallback is visible and does not masquerade as the requested quality;
- invalidation/noise rules pass and the complete signed evidence bundle is reproducible from its
  inventory.

The verdict remains fail-closed when a collector does not exist. Release notes may describe a
provisional diagnostic result as such, but catalogs, support matrices and UI MUST NOT translate it
into a qualified capability.

This is how “fast on any supported Linux ISO” remains testable: support is the union of exact
qualified records, never a wildcard inferred from a distribution name. Adding another ISO digest
adds another mandatory campaign; removing a campaign narrows the catalog rather than weakening the
budgets.

## Integration with current tooling

The current `scripts/benchmark-*.sh` and
`scripts/qualify-container-engine-performance.sh` provide useful
patterns: immutable candidate identity, raw round data, position-balanced comparisons, host
identity, cleanup evidence, and signed-package inputs. They are container-engine campaigns and
MUST NOT be relabeled as Linux VM evidence.

Implementation SHOULD reuse their canonical inventory/package conventions while adding a distinct
`dev.dory.linux-vm-performance-evidence` producer. The sequence is:

1. retain and evolve the separate structural pre-signing validator and complete signed-bundle
   verifier through reviewed schema revisions; neither substitutes for a physical collector;
2. add operation-bound macOS signposts and process/helper attribution;
3. add a versioned guest probe for readiness, cgroup/PSI, input receipts and workload events;
4. add VZ black-box collectors and RawHV typed telemetry adapters without inventing missing parity;
5. add clock calibration, immutable workloads, matrix orchestration and signed bundle production;
6. collect physical calibration evidence, freeze budgets, and connect the resulting manifest to
   assemble -> SBOM -> qualify -> finalize.

The legacy `scripts/benchmark.sh` uses mutable default fixtures and broad host sampling. It remains
a developer diagnostic only. Mutable `latest` images/packages, unbound host `vm_stat` deltas, and
single observations are not release evidence.

## Backend applicability and fast-path rules

### Applicability boundary

The generic-ISO and RawHV paths are not interchangeable implementations of one virtual-hardware
cell. Their current production applicability is:

| Product path | Current source boundary | What Dory may infer from source |
|---|---|---|
| VZ generic ARM64 installer ISO/UEFI disk | RawHV accepts only `linuxKernel` and `installedLinuxBootBundle`, while VZ accepts structurally compatible native ARM64 Linux installer ISO and virtual-disk media (`dory-core-swift/Sources/DoryOperations/DoryVirtualMachineCapabilities.swift:1356-1367`). Default planning selects RawHV for managed kernel/bundle media and VZ for compatible EFI media; x86_64 media is rejected rather than routed to the incomplete experimental QEMU surface (`dory-core-swift/Sources/DoryOperations/DoryVirtualMachineBackendPlanner.swift:279-288`). | Virtualization.framework owns the vCPU and emulated-device implementation. Dory can inspect its configuration and Dory-owned boundaries, but internal queue depth, copy count, and latency remain unavailable unless Apple exposes them. Generic-ISO qualification therefore needs black-box physical evidence. |
| RawHV managed direct boot | The same capability and planning lines restrict the default RawHV cell to a managed Linux kernel or installed boot bundle. RawHV does not currently implement arbitrary installer-ISO firmware boot. | Dory owns the Hypervisor.framework vCPU loop and VirtIO backends, so source-level receipts can identify structural work and candidate-bound traces can measure it. RawHV results MUST NOT be used as evidence that the VZ generic-ISO path is fast. |

Apple's GUI-Linux sample establishes the portable install boundary: an ISO must match the host CPU
architecture and boots through EFI with VirtIO scanout, storage, networking, input, and audio. It
does not define a guest hardware-3D contract. Mesa's VirGL and Venus contracts add renderer,
resource, host-visible-memory, and synchronization requirements that the VZ 2D baseline does not
promise. Dory's current worker bootstrap is narrower still: it accepts only the managed
`managedLinux612106PrepareFBV1` producer-complete fence contract. Therefore "distro-neutral" cannot
mean silently claiming acceleration for every installer image. Dory installs native ARM64 media
through VZ, but may select RawHV hardware 3D only for an authenticated managed kernel/guest tuple
that satisfies the schema-3 dual VirGL2-plus-Venus contract. An arbitrary installed kernel does not
inherit producer-complete scanout ordering merely because it binds `virtio_gpu`; generic-ISO
acceleration remains unavailable until an upstream-compatible producer contract is implemented and
physically qualified. Selection is by measured capabilities and exact artifact identities, never
by a distribution-name branch.

Rosetta is an application translator for x86_64 Linux processes inside a compatible ARM64 Linux
VM; Dory's container engine currently uses FEX for the equivalent application-level container
case. Neither mechanism virtualizes an x86_64 kernel, firmware, installer, or complete guest OS.
Dory therefore exposes no partial x86 VM support and no Intel ISO boot plan. Any future
whole-system x86 product must begin with a complete, packaged QEMU TCG backend and independently
qualify its firmware, virtual hardware, lifecycle, isolation, recovery, and performance; dormant
experimental QEMU selection is not an acceptable fallback.

`hostAcceleratedDisplay` means host-side scanout presentation; it is not guest hardware 3D. The
capability resolver permits `hardwareAccelerated3D` for Linux only on RawHV
(`dory-core-swift/Sources/DoryOperations/DoryVirtualMachineCapabilities.swift:1378-1389`), while
the VZ launcher represents a desktop as `hostAcceleratedDisplay`
(`dory-core-swift/Sources/DoryVMMKit/DoryVMM.swift:443-450`). RawHV schema 5 admits a read-only
renderer bootstrap at FD 6 exactly for a hardware-3D request, and the runner establishes the
renderer broker before vCPU start. That launch authority is still not GPU readiness: accelerated
publication requires a separate first worker-backed frame that has waited on the producer fence
and completed Metal presentation. The schema-3 daemon admission path verifies the canonical dual
bundle inventory, exact peer identity, candidate-bound real-bootstrap evidence, admitted managed
kernel, and fresh live receipt before activating the command lane; it then mints immutable
read-only FD 6 authority. Those are capability/authority facts, not GPU benchmark results.
Release-signed physical VirGL desktop, Venus application, synchronized-frame, recovery, visual
integrity, and whole-VM performance evidence remain open.

### Source-inspection evidence classes

Runtime audit findings use four disjoint evidence classes:

- **Structural blocker:** deterministic source behavior blocks a claimed capability, durability,
  correctness, or truthful fallback contract. It can block a release without a stopwatch.
- **Structural cost:** source proves that work, a copy, a syscall boundary, or serialization exists,
  but does not prove its wall-time severity.
- **Test-fixture observation:** a focused automated test proves behavior under its stated synthetic
  conditions. It is not a physical-host performance measurement.
- **Physical measurement:** only a candidate-bound observation from the evidence bundle defined
  above. Source findings and test fixtures MUST NOT be relabeled as measured regressions.

### Required fast-path architecture

1. **The resolved plan owns topology.** vCPU count, memory, disk policy, VirtIO queue count, NIC
   path, display topology, and graphics quality MUST be candidate-bound. A backend MUST NOT derive
   guest-visible queue topology from ambient host state after planning. RawHV block no longer uses
   ambient processor count: an omitted value resolves deterministically to one queue and explicit
   values are bounded to 1...16 (`Packages/ContainerizationEngine/Sources/DoryHV/VirtioBlk.swift:683-718`).
   Resolved RawHV desktop launches now bind memory, vCPU count, and an exact system-disk queue count
   in canonical launch-envelope schema 5 (`dory-core-swift/Sources/DoryOperations/RuntimeLaunchEnvelope.swift`),
   omit the former split CPU/memory flags (`dory-core-swift/Sources/DorydKit/MachineManager.swift:7593-7608`),
   and materialize that exact count (`Packages/ContainerizationEngine/Sources/dory-hv/DesktopMode.swift:780-805`,
   `Packages/ContainerizationEngine/Sources/dory-hv/DesktopMode.swift:1355-1358`). Engine mode remains
   a separate container workload whose block topology is not a Linux desktop support claim.
2. **A vCPU exit MUST have bounded ownership.** The boot vCPU and its `Machine.run()` lifetime run
   on one dedicated joinable POSIX thread, never a dispatch queue or cooperative task executor.
   An exit MUST NOT perform per-byte host I/O, helper RPC, an unbounded queue drain, a CSPRNG call,
   synchronous host-memory reclaim, or a whole-frame copy. Work handed off from an exit needs a
   bounded, reset-safe queue, explicit backpressure, generation fencing, and latency receipts. This
   rule does not relax descriptor validation or publication ordering.
3. **Transient backpressure MUST NOT become an invisible success.** A queue descriptor may be
   consumed only after its payload is accepted or after a typed, observable drop policy applies.
   Socket-full conditions need retained bounded work and readiness-driven resumption; overload
   policy and counters remain part of the resolved device contract.
4. **AppKit input callbacks MUST enqueue only.** Key, pointer, button, and semantic scroll events
   retain ordering and button/key transitions, while replaceable motion may be coalesced. Ring
   draining, guest waits, and device-lock contention belong off the AppKit main thread and need
   host-callback, enqueue, used-ring, guest-receipt, and presented-frame timestamps.
5. **Software presentation work MUST scale with damage.** Small damage MUST NOT first materialize a
   full backing image. The mailbox may retain one bounded surface, but publication, coalescing,
   extraction, and upload bytes must be separately observable. Accelerated scanout remains a
   distinct zero-readback contract and requires renderer/fence receipts.
6. **Memory reclaim authority MUST be truthful.** Target-driven ballooning, autonomous free-page
   reporting, and unavailable reclaim are different capabilities. Reclaim batches and restored
   stage-2 faults need byte/operation/latency distributions before policy changes.
7. **Helper isolation remains mandatory.** Filesystem, renderer, and network helpers MUST remain
   generation-bound and least-privileged. Optimization starts with attribution and copy/queue
   receipts; it cannot bypass the worker boundary merely to improve a microbenchmark.
8. **VZ datapath changes require matched physical evidence.** EFI system disks use cached,
   fsync-synchronized NVMe, while installer media is read-only USB mass storage
   (`dory-core-swift/Sources/DoryVMMKit/DoryVMM.swift:695-735`). Exact VZ NIC plans commonly select
   the file-handle/gvproxy path. The generic/RawHV/disconnected minimum remains MTU 1280, but a
   connected VZ file-handle NIC has an exact minimum and default of 1500 because host validation
   rejects 1280 and accepts 1500. Values below 1500 fail before gvproxy directory, socket, or
   process side effects. Native VZ NAT, file-handle/gvproxy, and every controller/media/cache/sync
   storage policy remain separate signed matrix cells; do not change or infer selection from source
   intuition alone.
9. **Hot-path synchronization remains local, exact, and edge-aware.** RawHV guest RAM shared with
   an isolated device worker MUST use an exclusively created POSIX shared-memory object whose name
   is unlinked immediately after creation; it MUST NOT use a regular filesystem file. The VMM and
   worker validate descriptor type, unlinked state, access mode, declared size, backing identity,
   and exclude the identity-authority page from worker grants. A vCPU's per-exit stop check remains
   a one-way acquire/release signal and MUST NOT acquire the global lifecycle lock. Virtio-MMIO
   interrupt status remains pending until ACK; repeated notification of an already-pending bit is
   coalesced while a newly pending distinct bit is still published, and request counters remain
   separate from emitted-signal counters. MMIO device attachment is a cold-path operation: the
   complete non-overlapping address map is sorted and sealed before SMP starts, each vCPU owns its
   own last-region cache, and a cache miss uses binary search without shared mutable cache state.
   These are correctness-preserving mechanisms, not evidence of a physical speedup.

## Current runtime hazards found by source inspection

Priority orders architectural closure, not measured severity. `P0` is a correctness/capability
truth blocker, `P1` is work directly on an interactive or device fast path, and `P2` is a material
attribution or efficiency risk that still needs traces. Unless a row explicitly says otherwise,
its evidence class is structural source inspection, not a physical benchmark.

| Priority / applies to | Corrected source finding | Required closure and qualification consequence |
|---|---|---|
| P0 / VZ generic ISO and RawHV managed boot | **No currently qualified Linux path may be called guest hardware-accelerated 3D.** VZ represents desktop graphics only as host-accelerated 2D presentation. RawHV's current mechanism is the schema-3 dual VirGL2-plus-Venus signed, sandboxed XPC worker with exact inventory and peer identity; that implemented admission path is not physical guest evidence. The worker accepts only the managed producer-complete fence contract, so arbitrary EFI guests cannot inherit its acceleration claim. | Keep the selected quality visible and fail every accelerated media cell closed. A guest application starting, including under llvmpipe, is not acceleration evidence. A launch-time identity, real-bootstrap receipt, or live capability receipt cannot replace release-signed installed launch, producer-fence-waited Metal presentation, sustained GL/Vulkan applications, recovery, visual integrity, and whole-VM performance gates. Qualify VZ 2D separately from RawHV renderer-backed 3D. |
| Closed P0 evidence-authority defect / both Linux paths | **The structural manifest checker can no longer be mistaken for a release evidence verifier.** The separate schema-1 bundle verifier opens one direct no-symlink root, requires an exact canonical file set, authenticates the inventory with a caller-supplied Ed25519 trust root, verifies every payload's length and SHA-256, binds expected sample/round counts, recomputes summaries from canonical raw JSONL, and evaluates only applicable frozen absolute bounds. Missing, invalid, unavailable, incorrect, fallback, unsupported-statistic, unsigned, untracked, indirect, or tampered evidence fails qualification. The verifier also rebuilds the canonical exact-media matrix-cell descriptor, requires its SHA-256 to be the matrix ID, and binds the selection/acceleration receipts to their inventoried bytes. Publication mode rejects calibration/failed verdicts and requires caller-supplied immutable candidate plus matrix-cell, installer, backend, and graphics bindings rather than trusting values declared by the bundle. The evidence no longer depends circularly on the post-qualification catalog. Thirteen focused tests include real valid and tampered detached-signature cases, descriptor-derived cell identity, release-qualified/exact-candidate/support-cell admission, and the precatalog CLI contract; the fixture key and numeric value are explicitly test-only. This is tooling/fixture closure, not a collected VM performance result. | Connect the candidate-bound physical collectors and bundle producer to this gate, pin the reviewed release public key in source-controlled release authority, and retain failed/invalid campaigns. The workflow MUST use `--require-release-qualified` with every expected candidate and support-cell binding, then prove the final catalog binds those same inputs and the qualification output. Do not publish a performance percentage or Supported cell until the complete exact candidate/media bundle verifies and all prerequisite gates pass. |
| Closed P0 artifact defect / RawHV accelerated managed boot | **The replacement Venus pack is deterministic against an explicit old GNU-libc baseline instead of inheriting Ubuntu 24.04.** The schema-6 `guest/out/dory-mesa-venus-arm64.tar.zst` has SHA-256 `fa12e2bef9855dd382c3cd7f1dcd434f65302fc13471ae06367179f1ad37124c` and input fingerprint `19a55684e03b26053f504982ebbbd85f31d198bcaeb307239689fd11189f17e9`. The build pins Debian Bullseye by image digest and snapshot, admits a `GLIBC_2.31` ceiling, and the verified exact ICD/application-probe/compositor-probe closure actually tops out at `GLIBC_2.29` (`guest/mesa/PINS`; `guest/out/dory-mesa-venus-build-arm64.stamp`). The archive is one `/opt/dory/mesa` tree, links libdrm static-hidden, records every runtime executable's exact `DT_NEEDED` set in `runtime.env`, contains no private Mesa patch, and independently passes `guest/mesa/verify-build.sh`. Its v2 compositor mechanism requires optimal color-attachment/blend/transfer-source rendering followed by a copy into the real transfer-destination LINEAR virtio-gpu DMA-BUF; this is not evidence that the production compositor already implements that path. The booted disposable Ubuntu derivative exercised the application probe's real Wayland acquire/render/present path; the new compositor probe, exact installed candidate binding, and whole-VM qualification remain open. | Retain the exact guest bytes now bound into the signed renderer tuple. In-guest preflight and activation MUST still validate architecture, loader, actual symbol ceiling, every exact `DT_NEEDED` library, Vulkan loader/WSI, device nodes, manifest path, and installed-tree identity. Then physically execute the compositor copy probe, integrate and prove a real compositor frame, and run the exact-media Venus/Zed campaign with process maps, renderer/fence receipts, native-surface/swapchain proof, no llvmpipe substitution, reset/recovery, and whole-VM budgets; an older ABI floor does not project compatibility or performance onto an untested distro. |
| Closed P0 renderer tuple/admission contradiction; open physical qualification / RawHV accelerated managed boot | **Production identity is now the schema-3 `dory-dual-metal-20260826` signed XPC bundle.** Its inventory binds the worker, XPC-local ANGLE Metal pair, static MoltenVK/virglrenderer inputs, guest Mesa, and exact identities as one candidate. Worker operation raw value 6 is the bounded `createResource3D` operation; activation exercises real VirGL2 and Venus contexts, imports the VirGL shared-texture and Venus descriptor-backed scanout paths, observes callback fences, and admits acceleration only when the authenticated bootstrap and fresh live receipt agree on all production feature bits and exactly ordered capsets `[2, 4]`. This closes the Venus-only/dual-contract source contradiction; it is still source, build, signature, and fixture authority rather than a hardware support claim. | Retain fail-closed dual-capset and exact-peer admission. Hardware 3D remains Unqualified until the exact release-signed candidate passes physical direct-rendering VirGL desktop/compositor/application tests, Venus surface/swapchain and sustained native-app tests, producer-fence-waited Metal presentation, resize/reset/worker-loss recovery, visual integrity, and whole-VM budgets. Do not include arbitrary generic ISO cells: no producer-complete guest-fence contract exists for them today. |
| Closed P0 source defect / VZ and RawHV reclaim | **Backend-specific balloon projection now matches the implemented control plane.** A running machine advertises and accepts target-driven ballooning only when the exact live backend is Virtualization.framework and the handoff socket still matches (`dory-core-swift/Sources/DorydKit/MachineManager.swift:8590-8619`, `dory-core-swift/Sources/DorydKit/MachineManager.swift:8629-8649`). A real RawHV launch with a control socket remains non-balloonable, rejects the target without invoking the controller, and preserves autonomous free-page reporting as a separate mechanism (`dory-core-swift/Tests/DorydKitTests/MachineManagerTests.swift:4860-4947`). VZ target application and both memory-snapshot compatibility cases remain green. | Keep the two reclaim mechanisms separate in API, telemetry, UI and qualification. Add physical pressure/reclaim progress, latency, restored-page-fault bursts and mixed-workload evidence for each backend; source/test closure is not a performance claim. |
| Closed P0 source defect / RawHV managed boot | **TX no longer consumes transient backpressure as guest packet loss or drains the ring on the notifying vCPU.** `backendManaged` kicks release the MMIO lock and enqueue a serial worker; production turns are bounded to 64 descriptors and 256 KiB (`Packages/ContainerizationEngine/Sources/DoryHV/VirtioNet.swift:40-95`, `Packages/ContainerizationEngine/Sources/DoryHV/VirtioNet.swift:752-835`). The transaction is `peek -> bounded snapshot -> MSG_DONTWAIT send -> pop -> push`; `EAGAIN`, `EWOULDBLOCK`, `ENOBUFS` and `EINTR` return before finalization, retain the FIFO head, and arm a bounded 250 microsecond-to-8 millisecond one-shot retry (`Packages/ContainerizationEngine/Sources/DoryHV/VirtioNet.swift:993-1062`, `Packages/ContainerizationEngine/Sources/DoryHV/VirtioNet.swift:1081-1089`, `Packages/ContainerizationEngine/Sources/DoryHV/VirtioNet.swift:1176-1252`). Deterministic tests prove 64 retained descriptors and zero used entries/drops across EAGAIN then ENOBUFS, responsive MMIO with fair bounded turns, and reset cancellation without a late send/completion (`Packages/ContainerizationEngine/Tests/DoryHVTests/VirtioNetTests.swift:176-292`, `Packages/ContainerizationEngine/Tests/DoryHVTests/VirtioNetTests.swift:294-425`). This is structural and fixture evidence, not physical throughput. | Bind queue/offload topology to the resolved plan and collect candidate-bound loss, p50/p95/p99 latency, throughput, CPU/byte, queue-depth, retry, fairness and reset-under-load evidence before qualifying sustained networking on any Linux guest. |
| Closed P0 source/authority defect / RawHV managed boot | **Guest RAM is no longer backed by an unlinked regular filesystem file.** `GuestMemory` now creates an exclusive POSIX shared-memory object, unlinks its name before publication, reserves one versioned identity page, maps guest data after that page, and owns exact unmap/close lifecycle (`Packages/ContainerizationEngine/Sources/DoryHV/GuestMemory.swift:76-180`). VMM and renderer worker handoff duplicates only close-on-exec bounded regions and rejects regular files, stale/resized descriptors, another same-size POSIX object, or exposure of the authority page (`Packages/ContainerizationEngine/Sources/DoryHV/GuestMemory.swift:280-331`; `Packages/ContainerizationEngine/Sources/DoryHV/DoryRendererWorkerBroker.swift:617-694`; `Packages/ContainerizationEngine/Sources/DoryRendererWorkerServiceCore/DoryRendererWorkerService.swift:309-384`). Darwin POSIX shm rejects `pread`/`pwrite` with `ESPIPE`, so metadata access uses one bounded shared page rather than weakening identity. Twelve focused CPU/memory tests, 27 broker/service compatibility tests, the original 512 KiB GPU fixture, and an optimized `dory-hv` product build pass. This is source/fixture/build closure, not memory-bandwidth, pressure, or footprint evidence. | Retain the exact descriptor/identity contract and collect attributable footprint, page-fault, pressure, reclaim, worker-map, CPU, bandwidth, boot and endurance evidence on every exact candidate/media cell. Do not infer anonymous-memory accounting or speed merely from the POSIX-shm mechanism. |
| Closed P1 source defect / RawHV managed boot | **A vCPU no longer takes the global lifecycle condition after every Hypervisor exit just to observe stop state.** `VCPUStopSignal` publishes the one-way stop transition with release storage and each exit loop reads it with acquire ordering; `teamCondition` still exclusively owns stop reason, vCPU handles, wakeups and joins (`Packages/ContainerizationEngine/Sources/DoryHV/Machine.swift:247-263`, `Packages/ContainerizationEngine/Sources/DoryHV/Machine.swift:498-503`, `Packages/ContainerizationEngine/Sources/DoryHV/Machine.swift:611-647`). Concurrency tests prove publication visibility and one-way lifetime semantics (`Packages/ContainerizationEngine/Tests/DoryHVTests/MachineHotPathTests.swift:7-54`). This removes a proven global serialization point but is not a measured vCPU speedup. | Collect exit counts/reasons, host CPU, lock contention, context switches, guest workload completion and stop latency from matched physical candidates; correctness of cancellation/join remains a prerequisite. |
| Closed P1 source/scheduling defect / RawHV managed boot | **The boot vCPU and complete `Machine.run()` lifetime no longer inherit a libdispatch or Swift cooperative-executor worker.** `RawHVMachineRunner` creates one single-use joinable POSIX owner thread, applies scheduling-policy revision 1, rejects self-join and a second start, performs exactly one native join, and replays the same result to concurrent lifecycle observers (`Packages/ContainerizationEngine/Sources/DoryHV/RawHVMachineRunner.swift:44-220`, `Packages/ContainerizationEngine/Sources/DoryHV/RawHVMachineRunner.swift:232-270`). Desktop, Engine, and the agent-ping probe all enter the machine through that owner and join it before teardown (`Packages/ContainerizationEngine/Sources/dory-hv/DesktopMode.swift:1043-1165`, `Packages/ContainerizationEngine/Sources/dory-hv/DesktopMode.swift:1874-1878`, `Packages/ContainerizationEngine/Sources/dory-hv/DesktopMode.swift:2167-2168`; `Packages/ContainerizationEngine/Sources/dory-hv/EngineMode.swift:924-929`; `Packages/ContainerizationEngine/Sources/dory-hv/main.swift:140-204`). Five focused lifecycle/concurrency tests and the production product build pass. This closes thread ownership structurally; it does not quantify scheduling latency or throughput. | Collect owner/vCPU runnable time, involuntary context switches, migrations, exit service-time distributions, SMP scaling, workload completion, thermals, and stop/join latency on exact candidates under idle and mixed load. Keep AppKit on the main thread and do not replace the owner with a dispatch task to improve convenience. |
| Closed P1 source defect / RawHV managed boot | **MMIO exits no longer linearly scan every attached device.** Cold attachment validates positive, non-overflowing, non-overlapping windows and maintains a sorted region table; `Machine.run()` seals that table before starting any vCPU (`Packages/ContainerizationEngine/Sources/DoryHV/MMIO.swift:10-57`; `Packages/ContainerizationEngine/Sources/DoryHV/Machine.swift:530-545`). Each vCPU then owns an unsynchronized last-region cache, so repeated accesses to one device are constant-time and a miss uses binary search rather than an attachment-order scan (`Packages/ContainerizationEngine/Sources/DoryHV/MMIO.swift:59-125`; `Packages/ContainerizationEngine/Sources/DoryHV/Machine.swift:662-749`). Four focused tests cover order independence, exact boundaries, repeated-device/miss transitions, and the top physical address; the full `DoryHV` target also compiles. This is structural hot-path closure, not measured exit-cost reduction. | On exact candidates, retain exit-reason/address attribution and compare MMIO service time, host CPU, guest workload completion, cache locality, SMP scaling, input latency and device throughput under isolated and mixed loads. Do not infer the magnitude from algorithmic complexity alone. |
| Closed P1 source defect / RawHV managed boot | **Virtio-MMIO no longer injects redundant host interrupts for repeated notifications of the same already-pending ISR bit.** Used/config request totals remain exact, pending status is lock-consistent through ACK/reset, same-bit requests coalesce until ACK, a newly pending distinct bit still emits, and telemetry separates notification demand from emitted signals (`Packages/ContainerizationEngine/Sources/DoryHV/VirtioMMIO.swift:4-28`, `Packages/ContainerizationEngine/Sources/DoryHV/VirtioMMIO.swift:151-166`, `Packages/ContainerizationEngine/Sources/DoryHV/VirtioMMIO.swift:355-397`). Focused tests cover same-bit coalescing, partial ACK/distinct bits, and 32-thread contention with reset (`Packages/ContainerizationEngine/Tests/DoryHVTests/VirtioMMIOInterruptTests.swift:6-116`). This is protocol/fixture closure, not measured interrupt-cost reduction. | Retain request-versus-emission counters and collect IRQ rate, exits, completions, latency, CPU and lost-wakeup correctness under storage/network/input/GPU mixed load on exact candidates. |
| Closed P1 source defect / RawHV managed boot | **Guest console bytes no longer become host writes on vCPU exits.** PL011 still publishes the byte produced by each guest data-register access, but Desktop and Engine sinks now perform only a bounded FIFO enqueue (`Packages/ContainerizationEngine/Sources/dory-hv/DesktopMode.swift:2499-2515`; `Packages/ContainerizationEngine/Sources/dory-hv/EngineMode.swift:1168-1180`). `BoundedSerialConsolePublisher` owns a fixed 256 KiB ring, coalesces ordered output into at-most-16 KiB batches on a dedicated worker, duplicates destinations close-on-exec, fences new publication at stop, drains with a bounded caller wait, synchronizes the durable desktop log, and receipts peak/pending, overflow, post-stop rejection, batches, syscalls, write errors, sync errors, and worker retirement (`Packages/ContainerizationEngine/Sources/dory-hv/BoundedSerialConsolePublisher.swift:49-108`, `Packages/ContainerizationEngine/Sources/dory-hv/BoundedSerialConsolePublisher.swift:194-299`, `Packages/ContainerizationEngine/Sources/dory-hv/BoundedSerialConsolePublisher.swift:315-397`). Desktop retires it before closing the original log descriptor; Engine uses the same boundary (`Packages/ContainerizationEngine/Sources/dory-hv/DesktopMode.swift:2160-2168`; `Packages/ContainerizationEngine/Sources/dory-hv/EngineMode.swift:586-595`). Three focused tests prove fixed-capacity FIFO wraparound/overflow, byte-exact batched order through flush and durable stop, late-publication rejection, and invalid configuration/descriptor failure (`Packages/ContainerizationEngine/Tests/DoryHVTests/BoundedSerialConsolePublisherTests.swift:6-77`). This is source and fixture closure, not a measured boot-speed claim. | Project the receipt into candidate telemetry, add exit-to-enqueue and batch-flush latency samples, and collect verbose-boot CPU/wall time, syscall count, overflow, log durability, and shutdown evidence on exact media. A clean receipt is required; dropping console bytes to win a benchmark is not. |
| Closed P1 source defect / RawHV managed boot | **Software scanout production now scales with exact damage instead of materializing the full resource first.** `publishScanoutFrames` first proves the complete backing covers the resource, then copies only intersecting dirty rows across validated fragmented backing entries and publishes a tightly packed stride. Cursor snapshots retain their separate explicit 256×256 full-image bound. `softwareScanoutCopiedBytes` records the producer delta independently of worker scanout copy bytes, and the adversarial fragmented fixture proves a 2×2 RGBA update crossing a backing boundary copies exactly 16 bytes. The software path remains distinct from the schema-3 dual worker, whose bounded `createResource3D` command is required for VirGL2. These are structural byte-work and authority facts, not measured frame time or a working accelerated frame. | Project producer copy bytes through candidate telemetry and collect flush-to-present latency, CPU, memory bandwidth, fragmented-copy call count, mailbox/upload bytes, frame pacing, and visual integrity under exact physical workloads. Keep software and accelerated observations separate; signed dual-worker admission exists, but no physical qualification or release performance evidence does. |
| Closed P1 source defect / RawHV managed boot | **The software display mailbox no longer adds full-frame or dirty-union copy amplification.** The ordinary one-update path retains the producer's immutable `Data` and drains with zero mailbox copies; only backlog enters a host-page-derived sparse-cell accumulator with per-pixel validity, so distant damage never turns holes into copied or uploaded pixels (`Packages/ContainerizationEngine/Sources/dory-hv/DesktopMetalDisplay.swift:292-380`, `Packages/ContainerizationEngine/Sources/dory-hv/DesktopMetalDisplay.swift:444-623`). Sparse materialization runs after the producer lock is released, and its process-wide byte reservation remains live through Metal consumption. Exact counters distinguish received, staging-copy, drain-copy, upload, drop and pending bytes/depth, aggregate across scanouts, and now project through the closed daemon telemetry schema. Twenty-five focused lifetime/telemetry tests include the seeded overlap/hole property and pass with the `dory-hv` build. Obsolete full-surface staging, dirty-union expansion, the unreachable desktop OpenGL presenter, and its test-only texture mailbox state are gone. This is structural byte-work evidence, not physical FPS or latency. | Retain fragmented-damage call counts and the new byte/depth telemetry in the physical collector; collect producer-to-present latency, main-thread time, upload bytes, frame intervals, CPU and correctness under idle and saturated backlogs. Keep this software path visible and separate from accelerated qualification. |
| Closed P1 source defect / RawHV managed boot | **AppKit input publication is now enqueue-only with bounded, generation-fenced guest-ring work.** `VirtioInput.send(frame:)` validates an entire semantic frame, updates desired key/button state, replaces only adjacent pure motion, keeps key/release/scroll order, and admits at most 256 pending frames without taking the transport queue lock (`Packages/ContainerizationEngine/Sources/DoryHV/VirtioInput.swift:493-540`). One coalesced worker drains no more than 64 chains/events per turn, yields fairly, and rejects or waits across reset so no revoked generation publishes late (`Packages/ContainerizationEngine/Sources/DoryHV/VirtioInput.swift:620-705`, `Packages/ContainerizationEngine/Sources/DoryHV/VirtioInput.swift:720-925`). Focused tests hold the guest ring lock while proving host send returns, verify exact key/scroll/release order and motion-only replacement, deterministic latency/depth gauges, and both active/queued reset races (`Packages/ContainerizationEngine/Tests/DoryHVTests/VirtioInputHardeningTests.swift:283-570`). All 27 device-owned counters/gauges project through the desktop and daemon telemetry schema without sampling the ring (`Packages/ContainerizationEngine/Sources/dory-hv/DesktopMode.swift:552-607`; `Packages/ContainerizationEngine/Tests/DoryHVTests/DesktopDeviceTelemetryTests.swift:69-161`). This is source and fixture closure, not a physical input-latency claim. | Add host-event and presented-frame timestamps to the existing enqueue/publication data, retain raw distributions rather than only the maximum, and run pointer, keyboard, scroll, resize, CPU-pressure and GPU-pressure physical campaigns. Dropped semantic transitions or software-frame stalls invalidate the observation. |
| Closed P1 source-policy defect / RawHV managed boot | **Sustained guest work no longer claims AppKit's highest scheduling class or inherits an unspecified receive class.** Candidate scheduling revision 1 leaves `userInteractive` to input/presentation and assigns vCPU threads, the primary machine launch, block workers, network TX/RX, and concurrent shared-filesystem workers to `userInitiated` (`Packages/ContainerizationEngine/Sources/DoryHV/Machine.swift:7-25`, `Packages/ContainerizationEngine/Sources/DoryHV/VirtioBlk.swift`, `Packages/ContainerizationEngine/Sources/DoryHV/VirtioNet.swift`, `Packages/ContainerizationEngine/Sources/DoryHV/VirtioFS.swift`; `Packages/ContainerizationEngine/Sources/dory-hv/DesktopMode.swift`). The canonical schema-5 execution authority carries that exact revision and rejects another (`dory-core-swift/Sources/DoryOperations/RuntimeLaunchEnvelope.swift`; `Packages/ContainerizationEngine/Sources/dory-hv/main.swift`). A focused three-test policy suite and clean full package build pass. Apple's QoS contract identifies `userInteractive` with UI/event work and `userInitiated` with immediate work that prevents use of the app; this is a semantically correct candidate split, not measured proof that revision 1 is optimal. | Run matched physical scheduling-profile campaigns with runnable pressure, wakeups, context switches, input-to-present tails, storage/network/shared-filesystem latency and throughput, thermals, power, and guest workload completion under CPU/storage/network/GPU mixed load. Keep revision 1 unqualified or revise it through a new envelope/candidate identity if the complete result regresses. |
| Closed P1 source/authority defect / RawHV managed desktop boot | **Block transfer amplification, unbounded drains, and hidden single-queue topology are closed.** Production uses zero-copy `preadv`/`pwritev` directly over validated guest segments, caps vectors and host operations, records partial/interrupted/failed syscalls, and bounds each ordered worker turn by chains, bytes, and range operations (`Packages/ContainerizationEngine/Sources/DoryHV/VirtioBlk.swift:137-247`, `Packages/ContainerizationEngine/Sources/DoryHV/VirtioBlk.swift:925-1022`). DISCARD and WRITE_ZEROES have explicit range/byte/operation limits; reset fences admitted host I/O and late completion, and one global transfer/flush condition preserves durability ordering across queues (`Packages/ContainerizationEngine/Sources/DoryHV/VirtioBlk.swift:1248-1301`). Canonical runtime-envelope schema 5 binds admitted memory/vCPUs plus one system-disk queue per admitted vCPU, rejects queue counts above vCPUs, removes split resolved CPU/memory flags from launch, and passes the exact count through `DesktopMode`; its conditional FD 6 renderer authority does not alter the disk contract. Fifteen focused canonical-envelope tests are green; focused disk materialization also proves a four-queue backend advertises `VIRTIO_BLK_F_MQ`. These are structural/test facts, not throughput or durability measurements. | Retain the canonical topology and global flush fence. Collect physical single-versus-multiqueue request/flush latency distributions, throughput, IOPS, syscall/segment/partial counts, queue depth/fairness, CPU per byte, discard/zeroing, reset-under-load and crash-integrity evidence before calling storage fast. VZ EFI/NVMe remains a separate cell; Engine mode remains a separate workload and still needs its own topology authority. |
| Closed P1 source defect / RawHV managed boot | **Free-page reporting no longer performs synchronous reclaim on the notifying vCPU.** `backendManaged` notifications only bind/coalesce a generation and enqueue a serial utility worker; production admits at most 32 ranges/64 MiB per report and executes exactly one report per worker turn before fair self-rescheduling (`Packages/ContainerizationEngine/Sources/DoryHV/VirtioBalloon.swift:23-31`, `Packages/ContainerizationEngine/Sources/DoryHV/VirtioBalloon.swift:64-213`, `Packages/ContainerizationEngine/Sources/DoryHV/VirtioBalloon.swift:254-324`). Complete descriptor/range admission still precedes host mutation, while a lifecycle fence prevents reclaim from starting after reset or QueueReady revocation and prevents late used-ring publication (`Packages/ContainerizationEngine/Sources/DoryHV/VirtioBalloon.swift:326-417`, `Packages/ContainerizationEngine/Sources/DoryHV/VirtioBalloon.swift:477-521`). Counters expose worker turns/yields/coalescing/revocation and total/maximum report time. Seven focused tests prove enqueue-only kicks, complete validation, fair yielding, release failure, queued reset revocation, and reset fencing of an in-flight release; the combined target is green. This closes vCPU ownership structurally, not the later cost of reclaim/refault. | `GuestMemory.releaseRange` still unmaps/advises under its page-state lock and reuse restores one host page per stage-2 fault. Collect report size/latency, lock time, reclaimed bytes, fault bursts, restore latency, guest pressure, mixed-workload impact, and queue fairness on exact physical candidates before changing batch or reclaim policy. |
| Closed P1 source defect / RawHV managed boot | **Entropy generation and RNG ring draining no longer execute on the notifying vCPU.** `backendManaged` kicks only bind/coalesce the current lifecycle generation and enqueue one serial utility worker. Production fills at most 4 KiB per request, completes at most eight requests per fair turn, retains the exact admitted chain through typed publication, and self-reschedules if bounded work remains (`Packages/ContainerizationEngine/Sources/DoryHV/VirtioRng.swift`). Reset and QueueReady changes revoke queued work and use a lifecycle fence to prevent late in-flight publication; provider failure never exposes provider-touched bytes to the guest. Worker turns, yields, coalescing, revocation, generated bytes, and deterministic latency maxima are explicit counters. Nine focused tests cover enqueue-only/coalesced work, reset and QueueReady revocation, in-flight fencing, bounded yielding, provider failure, partial completion, validation, and malformed rings; isolated Release `DoryHV` and `dory-hv` builds pass. This is structural ownership/build evidence, not a physical latency or entropy-throughput result. | Collect request-to-publication latency distributions, guest CSPRNG readiness, boot impact, host CPU, worker fairness and mixed-load interference on each exact physical candidate/media cell. Retain the bounded generation-fenced worker even if a benchmark suggests larger turns; any policy change needs a new candidate and starvation evidence. |
| P2 / RawHV managed boot | **VirtioFS pays an isolated per-request serialization boundary with caching disabled.** Positive cache validity is zero and coherent caching is hard-disabled. Each admitted request converts guest bytes to `Data`, crosses the broker/XPC channel, and the worker ultimately materializes `[UInt8]` for `FuseServer`. Validation and execution now share that one immutable worker-side array instead of materializing the request twice. The two nested binary codecs no longer build payload-sized `[UInt8]` intermediaries or rebase a second payload copy on decode: each encoder stages only its 72-byte or 16-byte fixed header into one pre-sized `Data`, and each decoder retains a bounded `Data` slice through the outer RPC and inner service frame. After transport send, the broker drops the complete request payload and retains only identity, deadline, and bounded reservations through guest-publication acknowledgement rather than keeping the payload beside the encoded XPC frame. A nested 4 KiB fixture requires the real non-zero slice indices and all broker/root-authority tests remain green. Production admits bounded approximately-one-MiB frames and 32 concurrent calls. A typed frontend permit gate mirrors that exact ceiling before `pop`: excess chains stay guest-owned, deferred request queues resume FIFO as permits return, and a controlled 40-request burst across eight queues proves saturation completes without worker/VM fail-stop. The frontend also exposes exact protocol-boundary request, worker-response, and guest-published payload bytes; completed/failed/in-flight/peak request counts; and total/maximum admission-to-completion latency through daemon telemetry. A focused success fixture proves exact byte ownership and a reset race proves failed work returns in-flight depth to zero. These are source, payload, and lifecycle facts—not physical XPC copy counts or measured speed. | Preserve worker isolation and retain these counters in candidate evidence. Add per-stage frontend/broker/XPC/worker latency, actual copy/allocation counts, XPC frame bytes, broker reservation depth, opcode mix, distributions, and coherence evidence. Consider shared memory or batching only after measurement; enable caching only after invalidation correctness is proved. |
| Closed P0 configuration defect / VZ connected exact NIC | **The VZ file-handle attachment's real lower bound is no longer confused with the generic NIC capability floor.** A direct host configuration probe rejects MTU 1280 and validates 1500. Connected exact VZ plans therefore default to and require at least 1500, while the generic/RawHV contract and disconnected VZ NIC remain valid at 1280. Values below 1500 fail before directory, socket, or process side effects. The isolated verification batch passes 113/113 structural tests plus `dory-vmm` and `doryd` builds. | Treat this as configuration correctness only, not higher throughput or lower latency. Bind the exact network datapath and storage policy in signed qualification, then collect matched native-NAT versus file-handle/gvproxy throughput, latency, loss, CPU, sleep/wake, VPN, and host-network-change evidence. |
| Closed P1 source defect / VZ generic ISO | **Generic Linux no longer runs Docker-only host services.** The typed VZ host-service plan starts only lifecycle/control for EFI/ISO guests, adds agent/shell proxies for direct-kernel Linux, and confines the Docker proxy plus one-second curl/port-discovery timer to the Docker engine role. A focused contract test and Release `dory-vmm` build pass. This removes source-visible unused listeners and periodic Docker probing; it is not a measured CPU, power, or latency claim. | Bind the service profile in the future immutable VZ launch envelope. Collect process-tree wakeups, timer firings, helper CPU/RSS, idle power, boot latency, functional agent/shell readiness, and Docker dynamic-port behavior on exact candidates; absence of required services invalidates a result. |
| P2 / VZ generic ISO | **An exact NIC contract selects a Dory-owned userspace boundary.** Supplying an exact interface makes the VZ launcher choose gvproxy, carrying one Ethernet frame per Unix datagram (`dory-core-swift/Sources/DoryVMMKit/DoryVMMGVProxyNetwork.swift:48-50`). Its socket configuration already uses a 4 MiB receive buffer and 1 MiB send buffer (`dory-core-swift/Sources/DoryVMMKit/DoryVMMGVProxyNetwork.swift:244-276`); those values are not identified here as defects. | Compare VZ native NAT and gvproxy with the same candidate/workload before changing selection. Attribute gvproxy CPU, datagrams, drops, backpressure, latency, and throughput; do not infer Virtualization.framework internals. |
| P2 / both paths | **Resource defaults drift before the resolved plan.** Desktop/installer policy defines 2 vCPU/4 GiB minimum and 4 vCPU/8 GiB recommended (`dory-core-swift/Sources/DoryOperations/DoryVMResourcePolicy.swift:437-477`); the creation UI derives 4-8 vCPUs and 4-8 GiB from the host (`Dory/Features/Sheets/NewMachineSheet.swift:1027-1041`), while legacy VMM and decoded machine defaults remain 2 vCPU/2 GiB (`dory-core-swift/Sources/DoryVMMKit/DoryVMM.swift:24-46`; `dory-core-swift/Sources/DorydKit/MachineManager.swift:248-307`). | One resolved resource receipt must be the launch authority. Record legacy migration inputs, but never let hidden fallback defaults define a qualifying run. Calibrate resource classes physically instead of inventing a universal tuning value. |
| P2 / both paths | **Internal telemetry and host cost are asymmetric.** RawHV owns device/fault/resource counters; VZ does not expose equivalent Dory-internal queues. App, daemon, VMM, renderer, FS worker, gvproxy, and short-lived helpers may all serve one operation. | Use common black-box product metrics plus backend-specific diagnostics. Missing VZ internals are `unavailable`, not inferred parity. Single-PID RSS/CPU and broad host deltas cannot qualify the complete operation. |

Further source inspection may identify other instrumentation sites, but it MUST preserve the same
evidence labels. Only candidate-bound physical traces establish timing severity, tail behavior, or
an improvement. Existing generic benchmarks with mutable fixtures remain diagnostics and MUST NOT
be imported into budget calibration.

## Primary mechanism references

- Apple [VZVirtualMachineConfiguration](https://developer.apple.com/documentation/virtualization/vzvirtualmachineconfiguration)
  documents the validated CPU, memory and device configuration boundary.
- Apple's [Hypervisor framework overview](https://developer.apple.com/documentation/hypervisor)
  defines vCPUs as host threads and MMIO emulation as host work performed after an exit before
  re-entering the guest; [`hv_vcpu_run`](https://developer.apple.com/documentation/hypervisor/hv_vcpu_run%28_%3A%29)
  blocks the owning thread until that exit. These are the mechanism reasons Dory bounds and
  attributes exit handling; they do not quantify the cost of any source defect.
- Apple [Recording Performance Data](https://developer.apple.com/documentation/os/recording-performance-data)
  defines the signpost/unique-interval workflow used to correlate concurrent host stages in
  Instruments. Candidate evidence still retains raw samples and Dory's cross-process bindings.
- Apple defines [`userInteractive`](https://developer.apple.com/documentation/dispatch/dispatchqos/userinteractive)
  as its highest-priority QoS for UI event handling and animation, and
  [`userInitiated`](https://developer.apple.com/documentation/dispatch/dispatchqos/userinitiated)
  as immediate work that prevents active use of the app. Those definitions motivate scheduling
  revision 1's semantic split; matched physical evidence still decides whether the profile meets
  Dory's complete responsiveness, throughput, thermal, and power budgets.
- Apple [VirtIO graphics configuration](https://developer.apple.com/documentation/virtualization/vzvirtiographicsdeviceconfiguration),
  [VirtioFS configuration](https://developer.apple.com/documentation/virtualization/vzvirtiofilesystemdeviceconfiguration),
  and [disk-image attachment](https://developer.apple.com/documentation/virtualization/vzdiskimagestoragedeviceattachment)
  are the primary VZ mechanism references. Dory still owns product-level performance proof.
- Apple's [GUI Linux sample](https://developer.apple.com/documentation/virtualization/running-gui-linux-in-a-virtual-machine-on-a-mac)
  defines the matching-architecture EFI/ISO portability boundary; it does not claim guest 3D.
- Mesa's [Virtio-GPU Venus documentation](https://docs.mesa3d.org/drivers/venus.html) defines the
  required guest virtio-gpu parameters, host-visible blob path, and host Vulkan prerequisites.
- The Khronos [Vulkan synchronization specification](https://registry.khronos.org/vulkan/specs/latest-ratified/pdf/vkspec.pdf)
  defines SYNC_FD copy-payload semantics and permits `-1` only for an already-signaled exported
  payload. Dory's renderer gate executes signal and export rather than accepting property queries.
- Apple's [`VZFileHandleNetworkDeviceAttachment.maximumTransmissionUnit`](https://developer.apple.com/documentation/virtualization/vzfilehandlenetworkdeviceattachment/maximumtransmissionunit)
  documents the socket-buffer relationship for the file-handle network path. Dory's current 4:1
  receive-to-send setting follows that recommendation; comparative product evidence is still
  required for datapath selection.
- The OASIS [VirtIO 1.3 specification](https://docs.oasis-open.org/virtio/virtio/v1.3/virtio-v1.3.html)
  is the device/protocol source; it does not define Dory's UX budgets.
- Linux's primary [blk-mq documentation](https://docs.kernel.org/block/blk-mq.html) explains the
  software/hardware queue split and the parallelism and fairness responsibilities that Dory must
  bind when advertising a VirtIO-block queue topology.
- Linux kernel [`/proc` documentation](https://docs.kernel.org/filesystems/proc.html), PSI, and
  cgroup-v2 documentation define the guest measurement sources used above.
- Ubuntu's official [Jammy ARM64 libc6 package](https://packages.ubuntu.com/jammy/arm64/libs/libc6)
  identifies its glibc 2.35 baseline; Debian's official
  [Bookworm ARM64 libc6 package](https://packages.debian.org/bookworm/arm64/libc6) identifies
  glibc 2.36. Guest renderer ABI qualification must bind exact package state rather than infer it
  from a distro label.
- Khronos Vulkan and the Wayland protocol define API/protocol timing boundaries. Dory's evidence
  contract defines how those boundaries become a signed product claim.
