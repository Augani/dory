# Post-v0.4 product designs

Status: design record, 2026-07-19. None of the capabilities in this document is promoted beyond
the status in `ARCHITECTURE.md`. This document records what already exists, the missing product
contract, the security boundary, and the evidence required before a later release can change that
status.

## Shared rules

Every capability follows the same release discipline:

1. The app, CLI, daemon, and public documentation use one schema and one capability status.
2. Secrets stay in Keychain or an ephemeral grant; durable configuration stores only secret IDs.
3. Network and filesystem inputs are untrusted even when the user selected them.
4. A multi-step mutation has an owner-only journal, exact pre-state, explicit cancellation, and a
   recovery route. “Best effort” rollback is not a success state.
5. Preview is not shorthand for untested. Preview still needs a bounded contract and negative tests;
   supported additionally requires the exact physical and duration gates for the advertised scope.
6. Telemetry and diagnostics identify the failing stage without collecting source, credentials, or
   remote file contents.

## 1. Safe cloud-image or OCI-rootfs import

### What exists

Linux Machines already accept an explicit kernel and raw root filesystem. `dory machine create`
can require a canonical SHA-256 manifest, an SSH signature in Dory's image namespace, an exact
signer identity, and a separately obtained allowed-signers policy. The bundled Dory kernel/rootfs
pair is recursively code-signed. This is an artifact trust contract, not an importer: Dory does not
claim that an arbitrary disk boots, contains the guest agent, or supports its virtual hardware.

### First product contract

The first importer should derive a machine disk from one of two bounded inputs:

- a digest-pinned OCI image containing one Linux root filesystem for the host architecture; or
- a supported, digest-pinned cloud image whose partition/filesystem format is explicitly listed.

It should use a Dory-qualified kernel and init path by default. Arbitrary ISO installation,
interactive installers, third-party kernels, DKMS, and mixed-architecture multi-image imports stay
outside this contract.

The pipeline is: resolve immutable descriptor; verify signature/trust policy when supplied; enforce
compressed and expanded byte limits; unpack in a no-network, no-host-mount worker; reject traversal,
special files, unsafe hard links, setuid/setgid capabilities, and ambiguous ownership; validate the
architecture and userspace ABI; construct a new sparse ext4 image without modifying the source;
install a version-matched guest-agent unit and virtual-hardware prerequisites into the derived copy;
boot a disposable machine; require agent, filesystem, network, clock, shutdown, and reboot probes;
then publish the disk, provenance, and content digest atomically.

### Threat model and failure behavior

- Treat manifests, layers, whiteouts, xattrs, symlinks, sparse extents, and decompression ratios as
  hostile. Extraction must be descriptor-relative and must never interpret a path through the host
  filesystem.
- Never run imported binaries on macOS. All boot probing happens inside a disposable VM with no
  host shares, no ambient credentials, and no network until the user explicitly enables the probe.
- A signature establishes publisher identity, not safety. Dory still applies structural and boot
  validation.
- A failed import removes only operation-owned staging objects. It retains a small redacted report
  and the immutable source digest, not a partially usable disk.

### Promotion gates

Golden fixtures must cover OCI whiteouts, hard links, sparse files, UID/GID preservation, systemd
and non-systemd images, malicious archives, signature failure, decompression bombs, full disks,
interruption at every publication boundary, five reboot cycles, clock/network/agent readiness, and
source non-mutation. Physical qualification must include internal and external APFS destinations.

## 2. MCP catalog and gateway

### What exists

`dory mcp serve` is Dory's local stdio control server. It exposes Dory doctor, engine, machine,
sandbox, wait, and event tools, and has a read-only mode. It is intentionally not a registry or
transport proxy for unrelated MCP servers.

### First product contract

Add a separate `dory mcp catalog` namespace and data model. A catalog entry contains a stable ID,
display metadata, transport, executable or endpoint identity, declared tools/resources, required
secret IDs, sandbox/network policy, source provenance, and a last-observed capability digest.

The first gateway should support local stdio servers launched in a Dory sandbox and explicitly
configured HTTPS servers. Discovery is read-only; enabling a server is a separate consent action.
The client sees the upstream namespace (`server-id.tool-name`) and provenance on every result.
Dory's own control MCP remains a distinct built-in server and can never be shadowed by catalog data.

### Threat model and policy

- Tool descriptions and results are untrusted content, not policy. They cannot request new mounts,
  secrets, network destinations, or Dory control privileges.
- Default to no host mounts, no secrets, and no network. Each grant is server-specific, visible,
  revocable, and absent from logs.
- Pin remote TLS identity and make redirects cross-origin only with new consent. Bound message size,
  concurrency, duration, subprocess count, and stdout/stderr.
- Detect tool-name collisions, capability drift, executable replacement, and catalog downgrade.
  Disable on drift until reviewed; do not silently accept a broader tool set.
- Read-only describes Dory's tools only. The gateway must report the independent mutation class of
  every upstream tool rather than implying that transport through Dory makes it safe.

### Promotion gates

Require hostile-server fixtures for oversized/framing-invalid JSON-RPC, prompt/tool description
injection, secret echo, fork bombs, hangs, capability drift, executable substitution, TLS failure,
and reconnect storms. Audit logs must prove decisions without retaining arguments marked secret.

## 3. Remote Docker/workspace UI

### What exists

The daemon has an SSH remote-agent transport with pinned host-key or known-hosts verification,
Keychain lookup by private-key ID, bounded agent calls, host-authoritative push, exec, telemetry,
and XPC/CLI status. Connections and configurations are currently memory-only. There is no complete
workspace UI, reconnect policy, edit/remove lifecycle, conflict workflow, or durable fleet model.

### First product contract

Persist an owner-only, versioned remote-workspace record containing no private key: workspace ID,
host/port/user, host-key policy and observed fingerprint, key ID, remote root, sync mode, include and
exclude rules, last common manifest digest, last successful agent version, and reconnect policy.
Key creation/import/removal is a separate Keychain operation with reference checks.

Start with one-way host-authoritative sync. Before each push, compare the remote tree to the last
common manifest. If remote files changed, stop and show a path-level conflict preview; never erase
them because “push” was clicked. Offer download-as-recovery-copy or explicit overwrite with an exact
target confirmation. Two-way merge is a later contract.

The UI needs offline, connecting, connected, degraded, conflict, and failed states; deterministic
backoff with a manual retry; host-key-change quarantine; per-stage progress; last-success time; and
clear separation between the local Dory engine, a remote Docker endpoint, and a remote workspace.

### Threat model and failure behavior

- Never accept a changed host key as a reconnect convenience. Show old/new fingerprints and require
  an explicit trust-policy update.
- Validate and confine remote roots. Refuse root, home, empty, traversal, symlink-escaped, device,
  socket, and special-file destinations.
- Do not forward the user's SSH agent by default. A key ID grants only the named workspace.
- Journal uploads with content digests and atomic remote publication. Interrupted transfers resume
  from verified chunks or restart; they do not leave a published mixed tree.
- Commands show their remote host/root and mutation class before execution. Output and telemetry are
  bounded and redact declared secrets.

### Promotion gates

Test first connect, offline launch, sleep/wake, network changes, daemon restart, SSH restart, expired
keys, host-key rotation, agent upgrade mismatch, 10k-file incremental sync, rename/delete, remote
edits, symlink races, interruption at every stage, and two clients racing the same remote root.

## 4. Image update checks and health-verified replacement

### What exists

Dory retains local repository digests, preserves digest-pinned pulls, supports registry credentials,
pull/build/push, and can inspect container definitions. It does not currently provide an update
availability model, bulk check, or transactional replacement of containers that use mutable tags.

### First product contract

Checking and applying are separate operations. A check resolves the exact registry, credential ID,
platform, manifest/index digest, config digest, and selected child manifest without pulling or
changing a tag. It records `unknown` rather than “up to date” when authorization, platform selection,
rate limits, proxy, CA, or registry semantics prevent a trustworthy comparison.

The UI supports manual check for one image and an explicitly selected bulk check. Digest-pinned
references are immutable and never shown as “update available.” Locally built, dangling, or
unresolvable images get a reason-coded non-checkable state.

Applying an update is container-oriented: capture the exact image/content digest and complete create
spec; pull and verify the candidate; create a shadow container with conflicting ports withheld;
run its declared or user-selected health check; quiesce the old container; atomically switch the
published definition; verify ports and health; and retain the previous content/spec until the user
or retention policy releases it. Volumes are never rolled back as part of an image rollback.

### Threat model and failure behavior

- Registry tags are attacker-controlled mutable pointers. Always bind decisions and rollback to
  content digests, registry identity, platform, and credentials used.
- Do not execute an image-provided health command with host privileges. It runs inside the candidate
  container with its normal grants and bounded output/time.
- Detect downgrade, platform drift, manifest-to-config mismatch, signature-policy failure, and a tag
  changing between check and pull. Re-resolve immediately before application.
- Bulk application is never default. Show dependency/order, ports, health contracts, and rollback
  limitations before mutation; journal each container independently.

### Promotion gates

Use authenticated/private, proxy/CA, multi-platform, rate-limited, tag-race, deleted-tag, malicious
manifest, unhealthy candidate, port collision, interrupted switch, volume marker, and automatic
rollback fixtures. A successful rollback must restore the old digest/spec and preserve volume data.

## 5. Bounded mDNS/multicast support

### What exists

Dory provides routed container/machine connectivity, custom domains, low-port forwarding, and
source-preserving LAN/Tailscale access. These solve ordinary TCP/UDP and client-IP use cases, not
link-local multicast discovery, broadcast-dependent appliances, or a general Ethernet segment.

### First product contract

Research a bounded mDNS relay before a bridge. The relay should be opt-in per Dory network and per
Mac interface, support only UDP 5353 to 224.0.0.251/ff02::fb, parse DNS messages, enforce packet and
record limits, drop malformed/unicast-response abuse, suppress loops by message digest/interface,
apply TTL expiry, and allow an optional service-type allowlist. Diagnostics show each participating
interface, direction, service type, drops, and loop suppression.

SSDP, LLMNR, arbitrary multicast, broadcast, raw Ethernet, DHCP, and promiscuous capture remain out
of scope. If HomeKit or appliance evidence proves mDNS relay insufficient, design a separate bounded
bridge profile with a dedicated VM NIC, one chosen physical interface, explicit DHCP/MAC exposure,
sleep/VPN/interface reconciliation, and a prominent corporate-network warning. Do not overload the
existing routed LAN mode with hidden L2 behavior.

### Threat model and promotion gates

Prevent amplification, reflection across interfaces/VPNs, discovery leakage between work and home
networks, packet loops, cache poisoning, oversized TXT records, and stale services after sleep or
interface removal. Physical testing needs Wi-Fi and Ethernet, VPN connect/disconnect, sleep/wake,
interface churn, IPv4/IPv6, duplicate service names, high-rate hostile traffic, and complete cleanup.

## 6. Stabilized Venus/Vulkan GPU contract

### What exists

Dory already has an opt-in Apple-silicon raw-HV path: a distinct provenance-verified GPU kernel,
virtio-gpu/Venus device, Venus-capable virglrenderer, MoltenVK ICD/dylib, Docker `--gpus` rewrite,
fail-closed asset selection, settings availability checks, and a headless default. It remains preview
because no stable API/performance envelope or retained physical conformance campaign supports a
general GPU claim.

### Supported-scope proposal

Do not promise CUDA, Metal inside Linux, video encode/decode, OpenCL, display acceleration, training
performance, or parity with native Apple frameworks. The first stable scope should be Vulkan 1.x
compute and a named set of graphics/compute workloads on Apple silicon, raw-HV only, with exact
guest Mesa/virglrenderer/MoltenVK versions and explicit resource limits.

Expose reason-coded availability (host, engine path, kernel, renderer symbols/version, ICD, guest
driver, device, container request), active clients, mapped bytes, resets, renderer RSS/FD/thread
counts, and last fault. A renderer or guest fault must fail the requesting workload without taking
the Docker control plane, data drive, or non-GPU containers with it. Disabling GPU must remove the
device and return to the qualified headless kernel after one controlled restart.

### Promotion gates

Retain Vulkan loader/`vulkaninfo`, selected Vulkan CTS, buffer/image mapping, synchronization,
multi-container isolation, allocation exhaustion, malformed command streams, renderer crash/restart,
sleep/wake, engine restart, eight-hour churn, and memory/FD growth evidence. Benchmark named real
workloads against CPU fallback and report distribution and correctness; never infer broad GPU
performance from one demo.

## Recommended order after v0.4

| Order | Capability | Why |
|---:|---|---|
| 1 | Safe OCI/cloud-image import | High user demand; existing signed-input boundary gives it a strong starting point. |
| 2 | Remote workspace UI | Much of the transport exists; persistence, conflict safety, and UX unlock the value. |
| 3 | Image update checks | Read-only checks are useful early; transactional application can graduate separately. |
| 4 | MCP catalog/gateway | Valuable for agents, but expands the tool/secret trust boundary substantially. |
| 5 | Bounded mDNS relay | Prefer a narrow answer to discovery needs before considering L2 bridging. |
| 6 | GPU stabilization | Continue evidence work without making it a dependency for the default developer path. |

User evidence can change this order. It must not weaken the security or promotion gates.
