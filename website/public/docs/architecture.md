# Dory production architecture

Dory has one production owner for its local engine: the per-user `doryd` LaunchAgent. The native
app and CLI submit intent over same-user, production-signature-authenticated XPC. Docker clients use
the owner-only `~/.dory/dory.sock`; a shared Rust dataplane classifies each request and relays it to
dockerd's private guest Unix socket. Dory does not expose unauthenticated Docker TCP in the guest.

On Apple-silicon macOS 15 or later, doryd launches the signed Hypervisor.framework `dory-hv`
helper. macOS 14 uses the signed Virtualization.framework `dory-vmm` fallback. Both use the same
kernel/rootfs/data format, Rust guest agent, versioned handshake/multiplexer/protobuf protocol,
Docker dataplane, selected `.dorydrive`, and userspace gvproxy network contract.

## Ownership

| Layer | Owner and boundary |
|---|---|
| UI and settings | Dory.app presents state and sends user intent; it does not launch a second local engine. |
| Control plane | doryd owns lifecycle, readiness, repair budgets, machines, networking reconciliation, health, and the Docker socket. |
| Docker bytes | Rust DoryCore classifies every HTTP request, applies policy, and preserves hijack/half-close streams over a private VM channel. |
| VM | dory-hv on macOS 15+, dory-vmm on macOS 14. Virtualization entitlements are confined to these signed helpers. |
| Guest | dory-agent owns typed control; dockerd listens on a private Unix socket. Temporary proxy/CA/sandbox material is placed on tmpfs. |
| Network | provenance-pinned gvproxy owns guest NAT/DNS/ports. Root-owned resolver/PF changes require one re-derived explicit dory-network-helper plan. |
| Storage | The manifest/volume-identity-checked `.dorydrive` owns images, containers, volumes, networks, machine disks, and snapshots. Missing or substituted drives fail closed. |
| Machine backups | doryd owns an owner-only durable scheduler. It re-import-verifies every local recovery bundle, periodically boots a disposable verifier, publishes atomically, and retains only scheduler-created snapshots and archives. |
| Updates | An owner-only journal binds app/config/component generations and a verified snapshot reference. Failed smoke restores safe replaceable state and never guesses at a durable-data downgrade. |

## Capability status

- **Supported:** Apple-silicon Docker/Compose/Buildx on macOS 14+, raw-HV on macOS 15+, Sonoma VZ
  fallback, explicit external Docker sockets, dedicated agent sandbox VMs, Build Activity for
  Dory-launched work, exact-selection transactional migration, verified scheduled local machine
  backups, Dory's control MCP, and host USB discovery.
- **Preview:** Venus/Vulkan on the arm64 raw-HV path, remote SSH workspace foundations, and custom
  machine kernel/rootfs inputs within the published image contract.
- **Unavailable:** USB attach/detach/replay, audio passthrough, managed remote/offsite machine
  backup, third-party MCP catalog/gateway, image-update orchestration, mDNS/multicast relay or
  general L2 bridging, Intel public releases, and Windows/Linux host apps.

Agent sandboxes are separate VMs. They run non-root, share no host files/network/credentials by
default, enforce egress and resource policy, and are removed by default. See the source repository's
[`SANDBOX_THREAT_MODEL.md`](https://github.com/Augani/dory/blob/main/SANDBOX_THREAT_MODEL.md).

The complete source-of-truth document, including boot/repair, update, storage, and trust-boundary
details, is [`ARCHITECTURE.md`](https://github.com/Augani/dory/blob/main/ARCHITECTURE.md).
Post-0.4 proposals are kept separately in
[`POST_V0.4_PRODUCT_DESIGNS.md`](https://github.com/Augani/dory/blob/main/POST_V0.4_PRODUCT_DESIGNS.md)
so design intent is never presented as a shipped capability.
