# Competitor-derived regression coverage

Last reset for the Dory 0.4 workstream on 2026-07-18.

This is an executable regression index, not an issue backlog. The referenced upstream reports are
failure fixtures that Dory must continue to resist. Dory's own GitHub issues are considered fixed;
`LAUNCH BLOCKER` below means the implementation still needs exact-candidate or physical-environment
certification, not that the product fix is missing.

| Competitor failure class | Dory coverage | Mandatory closure evidence |
|---|---|---|
| Cached/offline boot and stale runtime state ([Lima 5188](https://github.com/lima-vm/lima/issues/5188), [Apple container 1707](https://github.com/apple/container/issues/1707), [Apple container 1895](https://github.com/apple/container/issues/1895)) | **FULL — source regression covered** by the offline bundled-boot and exact guest-agent gates. | Keep `offline-bundled-boot-gate.sh` and the fresh/restart guest-agent hashes in release qualification. |
| Runtime backend switching can crash file sharing ([Docker Desktop 7825](https://github.com/docker/for-mac/issues/7825)) | **FULL — structurally excluded** because Dory has one HostFS/VirtioFS implementation and no runtime gRPC-FUSE switch. | Keep the production-source rejection check and bind-coherence campaign mandatory. |
| Compose one-off containers steal long-running routes ([OrbStack 2576](https://github.com/orbstack/orbstack/issues/2576)) | **FULL — source regression covered** by `testComposeOneOffCannotStealLongRunningServiceRoute`. | Run the route reconciler test and runtime Compose campaign on every exact candidate. |
| Docker archive streams and one-shot exit visibility are incomplete ([Apple container 1908](https://github.com/apple/container/issues/1908), [Apple container 1501](https://github.com/apple/container/issues/1501)) | **FULL — source regression covered** by bidirectional `docker cp` and explicit `exited:37` assertions. | Bind the exact Docker CLI and engine hashes to the runtime campaign. |
| Kubernetes services or APIs are unreachable after network changes ([Colima 1339](https://github.com/abiosoft/colima/issues/1339), [Colima 1595](https://github.com/abiosoft/colima/issues/1595)) | **LAUNCH BLOCKER — exact artifact certification**; implementation and bounded gates exist. | Prove API, service, ingress, DNS, restart, VPN, and sleep/wake reachability on the notarized candidate. |
| BuildKit cancellation, cache export, or builder death hangs the client ([BuildKit 6008](https://github.com/moby/buildkit/issues/6008), [BuildKit 6209](https://github.com/moby/buildkit/issues/6209), [Buildx 556](https://github.com/docker/buildx/issues/556)) | **FULL — source regression covered** by bounded cancel/recovery and private-registry cache gates. | Retain exact Buildx/Docker/engine digests and post-cancel API-liveness evidence. |
| Multi-platform storage, Nix GC, or amd64 builds regress ([Apple container 1537](https://github.com/apple/container/issues/1537), [OrbStack 2538](https://github.com/orbstack/orbstack/issues/2538), [Apple container 1825](https://github.com/apple/container/issues/1825)) | **LAUNCH BLOCKER — exact artifact certification**; deterministic FEX and source conformance gates pass. | Repeat default-platform, Nix, Arch, mmdebstrap, exec, and BuildKit fixtures with the shipped rootfs and clients. |
| Large headers, proxy concurrency, or API framing wedges unrelated requests ([Apple containerization 790](https://github.com/apple/containerization/issues/790)) | **FULL — source regression covered** by the bounded concurrent runtime/API campaign. | Preserve deadline, half-close, large-body, backpressure, and unrelated-request evidence. |
| Proxy/DNS configuration or recovery is incomplete ([Lima 5225](https://github.com/lima-vm/lima/issues/5225), [Rancher Desktop 6943](https://github.com/rancher-sandbox/rancher-desktop/issues/6943), [OrbStack 2587](https://github.com/orbstack/orbstack/issues/2587)) | **LAUNCH BLOCKER — corporate-network certification**; the current implementation has scoped DNS, route, proxy, and source-preserving-LAN controls. | Certify PAC/manual proxy, custom CA, split DNS, VPN route churn, physical LAN peers, and sleep/wake on the exact app. |

## Decision

Public release remains **NO-GO** until every exact-artifact and physical-environment row is promoted
to `FULL` by retained, hash-bound evidence. A passing source test never substitutes for the shipped
app, helper, kernel, rootfs, client, and environment named by a release gate.
