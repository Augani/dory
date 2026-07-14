# Dory Runtime Architecture

Status: adopted 2026-07-09.

Dory has four separate runtime roles. Keeping these roles separate is part of the product architecture, not an implementation detail.

## Owners

- `Dory.app` owns user intent and presentation. It opens settings, shows success/failure notices, reconciles the installed LaunchAgent, and asks `doryd` to start/wake/sleep the engine over XPC.
- `doryd` owns durable runtime state and engine lifecycle. Runtime mode and idle policy are read from `~/.dory/config.json` through `IdlePolicyStore`; doryd decides whether the Docker tier starts immediately or arms its socket for wake-on-use.
- `launchd` owns only daemon supervision. Its plist points at the bundled helpers, static ports, static domain suffix, logging, and KeepAlive/RunAtLoad. It must not carry user runtime mode.
- Helpers own execution. `dory-hv` owns the Docker VM, `dory-vmm` owns machine VMs, `gvproxy` owns userspace networking transport, and bundled CLI helpers are reconciled into `~/.dory/bin`.

## Startup Contract

On daemon launch:

- `always-on` starts the Docker tier immediately.
- `manual`, `auto-idle`, and `battery-saver` arm the Docker socket without treating launchd environment as policy.
- `battery-saver` preserves the configured Auto-Idle delay but caps its effective delay at five minutes.
- `DORYD_FORCE_AUTOSTART_DOCKER_TIER=1` is reserved for development smoke tests.

On app launch:

- the app reconciles the LaunchAgent from the installed bundle;
- if doryd is available but the engine is not running, the app promotes the engine to running so Docker commands work after opening Dory;
- idle policy decides whether doryd may sleep the engine again later.

On settings changes:

- runtime mode and idle policy are persisted through doryd and confirmed with an in-app notice;
- settings notices must describe the applied state, not only the requested state;
- if a settings action has multiple owners, for example host CLI files plus a daemon LaunchAgent refresh, the app must report partial application instead of a blanket success;
- LaunchAgent refreshes are for static daemon settings such as host CLI repair, domain suffix, and ports;
- settings failures use settings notices instead of unrelated global action errors.

## Docker Reachability Contract

Docker reachability is a product invariant, not a benchmark convenience.

- The stable user socket is `~/.dory/dory.sock`; app code should prefer the doryd-reported socket path when doryd owns the engine.
- Terminal integration installs stable user commands into `~/.dory/bin`; UI copy and terminal launch commands must use `docker`, `docker compose`, and `dory machine shell <name>`, not bundle-private helper paths.
- App terminal affordances may resolve private helpers for internal diagnostics, but user-facing machine shells require the stable `dory` command. `TerminalSession` must not carry bundle-private `dorydctl` paths.
- Opening Dory means "make Docker usable now." The app may promote a stopped or sleeping doryd-owned Docker tier to running, but doryd remains the owner of durable runtime mode and later sleep decisions.
- If doryd cannot start the Docker tier, the app must leave the backend as disconnected instead of silently falling back to another local Docker engine while the preference is Dory.

## Regression Guards

Keep tests around these boundaries:

- LaunchAgent plist generation must not include `DORYD_AUTOSTART_DOCKER_TIER`.
- stale launchd runtime hints must not override persisted runtime mode.
- the stable user command for machines is `dory machine shell <name>`, not a full helper path.
- legacy terminal-session payloads that contain private helper paths decode without reusing those paths.

## Engine Performance Contract

Performance work follows the same ownership split as lifecycle work.

- Product benchmarks must run against `/Applications/Dory.app` and its installed helpers unless the run is explicitly labeled as an experiment.
- LaunchAgent environment is not a tuning database. Temporary keys such as `DORYD_CPUS` may be used to falsify a hypothesis, but must be removed after the run unless the behavior is promoted into source and tests.
- Engine sizing, scheduler policy, storage semantics, cache policy, and file-sharing behavior belong in source-owned configuration paths, not hand-edited plists.
- A benchmark optimization graduates only when it has a source change, a regression guard or focused test where practical, an installed-app smoke, and a saved raw benchmark directory.
- Failed experiments must be actively reverted from source, the installed app, and the live LaunchAgent before another product-state run.
- Benchmark reports must separate product-state runs from one-off environment experiments.

### Host-share coherence contract

Fast host sharing is allowed to graduate only when it preserves both namespace coherence and native
Linux watcher behavior.

- A FUSE node ID belongs to one host object for its entire lookup lifetime. Host replacement creates
  a new monotonic node ID; `FORGET` and `BATCH_FORGET` release lookup references.
- Host-writable shares default to zero entry/attribute TTL, no negative dentries, no keep-cache, and
  no writeback until reverse invalidation is negotiated and healthy end to end.
- Cache readiness requires a live macOS event source, a negotiated virtio-fs notification queue,
  posted guest buffers, successful FUSE initialization, and an ordered invalidation/fsnotify path.
- Event overflow, queue loss, root replacement, sleep/wake discontinuity, or protocol mismatch moves
  the share to degraded mode and disables cache-dependent behavior.
- A reverse-invalidation deadline covers request quiescence as well as guest acknowledgment. Missing
  the deadline permanently closes that backend's request-publication gate until VM replacement; work
  admitted before the boundary cannot publish a used-ring response afterward. A host syscall already
  begun by that work cannot be canceled or rolled back and retains normal host last-writer semantics;
  the boundary fences only response publication and admission of new work.
- Production host shares reject virtio-fs DAX, including read-only DAX. Direct guest mappings bypass
  the FUSE request gate: writable mappings can still store after a failed reverse invalidation, and
  read-only mappings can still serve stale bytes while recovery is pending. DAX may return only after
  a host-owned vCPU-quiesce boundary is implemented and proven under host edits and atomic replacement.
- Polling visibility is not HMR correctness. Release validation must include a host edit observed by
  a guest inotify-backed watcher.
- Performance experiments that violate these conditions may be used to measure upside, but must be
  explicitly labeled unsafe and reverted immediately afterward.

The current benchmark strategy is:

- protect the fast guest-local container bridge path, while keeping its measurement boundary honest:
  the current container-to-container iperf result never crosses `VirtioNet` or gvproxy and therefore
  proves neither host/Internet throughput nor a lead over other desktop network stacks;
- rank the external path only from same-session, interleaved DNS, TCP/TLS, fixed-download, and
  concurrent-registry measurements, with Dory device-drop and gvproxy retransmit counters retained;
- keep vCPU scheduling and I/O workers inside `dory-hv`, because those are custom-VMM advantages;
- avoid kernel churn until the engine execution path proves the guest kernel is the bottleneck;
- prefer narrow, falsifiable experiments over broad bundles of unrelated tuning.
