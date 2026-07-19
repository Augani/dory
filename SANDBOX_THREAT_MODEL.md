# Dory sandbox threat model

Status: supported v0.4 contract. This document describes `dory sandbox`, not ordinary Dory Linux
machines or containers.

## Security objective

Run an untrusted, non-interactive development command without giving it ambient access to host
files, credentials, local services, private networks, or an unlimited lifetime/resource budget.
Dory uses one dedicated Linux VM per disposable or named sandbox. The macOS host, the signed Dory
app/helpers, `doryd`, the VMM, and the selected kernel/rootfs are trusted computing base.

The sandbox is intended to contain a malicious dependency, build script, or coding-agent command.
It is not a boundary against a malicious macOS administrator, a caller already authorized to use
the lower-level `dory machine exec` operator interface, or a vulnerability in macOS
Virtualization.framework/Hypervisor.framework, Dory's VMM, the guest kernel, or the guest agent.

## Default boundary

| Surface | Default | Explicit grant |
|---|---|---|
| Host filesystem | No host shares | `--mount HOST[:GUEST[:ro\|rw]]`; omitted mode is read-only |
| Scratch disk | 256 MiB persistent ext4 inside the dedicated VM | `--disk-mb 32..640`; setup also reserves 64 MiB of guest-root headroom, and explicit host `:rw` grants are outside this quota |
| Identity | Host numeric uid/gid, never root (uid 65534 when invoked by host root) | `--elevated`, accepted only with `--network full` |
| Network | `none`; IPv4 and IPv6 denied for the workload uid | `outbound` plus `--allow-network HOST[:PORT]`, or explicit `full` |
| DNS | Blocked in `none` | `outbound` permits TCP/UDP 53 only to Dory's guest resolver; `full` is unrestricted |
| Secrets | None | `--secret-env NAME`, sent in memory over stdin/XPC/agent RPC and omitted from argv/manifests |
| SSH agent | No host bridge | `--ssh-agent`; exposes signing operations, not private-key material |
| Lifetime | Disposable; daemon expiry is also persisted as crash cleanup | `--keep --name NAME [--ttl-seconds N]`, then `--reuse NAME` |
| Resources | 2 CPUs, 2 GiB RAM, 256 MiB disk, 128 processes, 1,024 FDs, 600 seconds | Bounded CLI options within documented limits |

`outbound` resolves each hostname on the host at launch and pins the resulting IPv4/IPv6 addresses
and port in the run manifest and guest firewall. Guest DNS may return a different address later, but
the workload cannot connect to it unless it was pinned. Loopback, the host gateway/services,
RFC1918/ULA private LANs, link-local/metadata addresses, and every other destination are denied by
default; an exact IP/hostname and port can be individually granted.

## Enforcement sequence

1. `doryd` clones a verified machine rootfs and starts a dedicated VM with no shares except explicit
   grants and Dory's read-only boot configuration.
2. Before untrusted code runs, a root-only setup call mounts the bounded sandbox disk and installs
   nft-backed iptables rules matched to the future workload uid.
3. The guest agent starts the workload as the non-root uid/gid with `RLIMIT_NPROC`, `RLIMIT_FSIZE`,
   and `RLIMIT_NOFILE`; the agent owns a process group and kills the tree at the wall deadline.
4. The CLI deletes disposable state. Independently, `doryd` periodically deletes any sandbox whose
   persisted expiry is due, including sandboxes orphaned by a CLI crash, logout, sleep, or daemon
   restart.

The boot/setup interval contains only trusted Dory code. Network filtering is workload-uid scoped,
so the root guest agent and daemon can finish control operations while untrusted egress stays denied.

## Credential and persistence semantics

Secret values are never placed in machine configuration, VMM arguments, snapshots, incident logs,
run manifests, or sandbox command argv. They exist in the host caller environment, an anonymous
pipe, the in-memory XPC/agent request, and the child environment. A command can deliberately print,
copy, or exfiltrate a granted secret; granting it is authority to use it. Dory redacts by omission,
not by trying to recognize arbitrary command output.

The SSH-agent grant permits the sandbox to request signatures from every identity currently exposed
by that agent. Use a constrained/dedicated agent when repository trust is uncertain. Revoking or
restarting the host agent terminates that authority.

Named sandboxes retain their VM rootfs and bounded `/dory-sandbox` workspace. Reuse refuses missing
or inconsistent manifests, changed mount grants, expired TTLs, and SSH-agent grant mismatches.
Snapshots contain sandbox filesystem state but never the ephemeral secret environment.

## Operator and escape hatches

`--elevated` is an explicit trust decision. Root can change guest firewall/mount state, so Dory only
allows it with `--network full` and records it in the manifest. A `:rw` host mount can modify or
delete files under that exact host directory. `network full` can reach whatever the host network and
VPN permit. These are visible grants, not sandbox-equivalent defaults.

An authorized user can always stop/delete a sandbox with `dory sandbox kill NAME`. Lower-level
machine commands are an administrator/operator surface and can bypass sandbox policy; do not expose
them to an untrusted agent. MCP read-only mode blocks both machine execution and sandbox creation.

## Release evidence

`scripts/sandbox-security-gate.sh` runs commands inside exact-candidate sandbox VMs and must prove:
non-root identity, read-only mount denial, absent ambient SSH/secret grants, secret-manifest omission,
DNS/network denial, exact outbound grants, disk/process/FD/wall caps, rollback, named reuse, kill,
and daemon-owned TTL deletion. Missing physical VM/network inputs fail the release gate rather than
being recorded as a skip.
