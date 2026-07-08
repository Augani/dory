# dory-core-swift

The Swift side of the Rust-sidecar re-platform. `doryd` is the launchd control-plane daemon; it
links the `dory-ffi` Rust staticlib as `DoryFFI.xcframework` and serves an XPC control protocol.

## Build

```sh
../scripts/build-dory-ffi-xcframework.sh
DEVELOPER_DIR=/Applications/Xcode-26.6.0-Release.Candidate.app/Contents/Developer swift build
DEVELOPER_DIR=/Applications/Xcode-26.6.0-Release.Candidate.app/Contents/Developer swift build --product doryd
DEVELOPER_DIR=/Applications/Xcode-26.6.0-Release.Candidate.app/Contents/Developer swift build --product dorydctl
DEVELOPER_DIR=/Applications/Xcode-26.6.0-Release.Candidate.app/Contents/Developer swift build --product dory-vmm
DEVELOPER_DIR=/Applications/Xcode-26.6.0-Release.Candidate.app/Contents/Developer swift test
```

The build script produces `artifacts/DoryFFI.xcframework` plus generated UniFFI Swift bindings under
`Sources/DoryCore/generated/`.

## Manual launchd verification

The automated tests use an anonymous XPC listener. To verify the real launchd MachService path:

```sh
# 1. build + install doryd
swift build -c release --product doryd
sudo cp .build/release/doryd /usr/local/bin/doryd
codesign --force -s - /usr/local/bin/doryd

# 2. load the LaunchAgent
cp launchd/dev.dory.doryd.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/dev.dory.doryd.plist

# 3. confirm it is up
tail /tmp/doryd.log
ls -l ~/.dory/dory.sock

# 4. uninstall
launchctl bootout gui/$(id -u)/dev.dory.doryd
rm ~/Library/LaunchAgents/dev.dory.doryd.plist
```

A tiny client that connects via `NSXPCConnection(machServiceName: "dev.dory.doryd")` and calls
`protocolVersion` should print `1`.

`dorydctl` is the small local control CLI for smoke tests and readiness automation:

```sh
swift run dorydctl engine status
swift run dorydctl docker telemetry
swift run dorydctl machine list
swift run dorydctl machine create dev --kernel /path/to/Image --rootfs /path/to/rootfs.raw
swift run dorydctl network status
swift run dorydctl balloon status
swift run dorydctl balloon reconcile
swift run dorydctl health
```

The CLI intentionally mirrors the plist-safe XPC surface. Use `docker agent-info|ports|telemetry`
for agent control smoke tests, `network replace-routes --json routes.json` for local domain routing,
`remote connect|push|status` for SSH-backed agents, and `doctor-json`/`incidents` for health gates.

Debug app builds also bundle `doryd`, `dorydctl`, `dory-vmm`, and `dory-network-helper` into
`Dory.app/Contents/Helpers` and generate `Dory.app/Contents/Resources/dev.dory.doryd.plist` with
those absolute helper paths. You can bootstrap that plist directly for app-closed smoke tests, then
boot it out with `launchctl bootout gui/$(id -u)/dev.dory.doryd`.

## Docker-tier dataplane

`doryd` can be pointed at a running `dory-hv engine --agent-vsock-forward <path>` socket:

```sh
DORYD_AGENT_VSOCK_FORWARD=/tmp/dory-hv-forward.sock \
DORYD_AUTOSTART_DOCKER_TIER=1 \
swift run doryd
```

The Swift side binds `~/.dory/dory.sock`, hands that listener fd to the Rust
`startDataplaneForward` FFI entry, and the Rust dataplane dials the forward socket with the
`HostToGuest{cid:3, port:1026}` preamble for each docker connection.

When `DORYD_ACTIVITY_SOCK` is set, or by default under `DORYD_STATE_DIR`, doryd starts a private
activity socket. The dataplane reports meaningful docker connections there (`/_ping` is ignored),
allowing `IdleController` to idle-sleep the helper while keeping `dory.sock` bound. The current
actuation stops/restarts the helper process; true dory-hv VM pause/resume still needs the helper API.

The same forward socket is also used for guest agent control. `AgentControl` connects with a
`HostToGuest{cid:3, port:1024}` preamble and exposes `info`, `clockSync`, `portsWatch`, and
`telemetry`; docker wake attempts a clock sync when agent control is enabled.

For app-side dogfooding before the final legacy deletion gate, the normal Dory engine preference now
uses doryd by default. The app calls doryd's `engineStart` over XPC, reads `dorySocketPath`, treats
that daemon-owned socket as its Docker runtime, and does not bind the legacy in-app `DockerShim`
server. Use `DORY_APP_DISABLE_DORYD=1` only for explicit legacy-engine development.

## Memory ballooning

`BalloonController` computes guest memory set-points from a Darwin host memory snapshot and each
guest's agent telemetry (`memTotalKB`, `memAvailableKB`, PSI). Under host warning/critical pressure it
reclaims in bounded steps while preserving a protected guest working-set floor; under nominal host
pressure it can grow guests that report low available memory or high PSI.

The XPC `balloonStatus` method is read-only: it returns the current host snapshot, every visible
guest target, and the subset of changed targets that are safe to apply. `balloonReconcile` computes
the same plan and applies changed targets through the configured `BalloonActuator`. For local
machines, `dory-vmm` advertises a private `0600` Unix control socket in its ready handoff; doryd sends
a `setBalloonTarget` request there, and the helper updates the VM's
`VZVirtioTraditionalMemoryBalloonDevice` target. The machine manager tracks the live target separately
from the boot memory ceiling so a reclaimed VM can grow again when guest pressure returns. Docker-tier
reclaim remains handled inside the engine helper's free-page/reporting loop.

To let `doryd` own the helper process, provide the helper, kernel, and gvproxy paths instead:

```sh
DORYD_HV_HELPER=/path/to/dory-hv \
DORYD_HV_KERNEL=/path/to/dory-hv-kernel \
DORYD_GVPROXY=/path/to/gvproxy \
DORYD_AUTOSTART_DOCKER_TIER=1 \
swift run doryd
```

Useful knobs:

- `DORYD_HOME`: runtime home, defaulting to the user's home.
- `DORYD_STATE_DIR`: docker-tier helper state, defaulting to `~/.dory/hv`.
- `DORYD_AGENT_VSOCK_FORWARD`: override the forward socket path.
- `DORYD_ACTIVITY_SOCK`: override the dataplane activity socket path.
- `DORYD_AGENT_CONTROL=0`: disable docker-tier guest agent control.
- `DORYD_WAKE_DNS_PROBES`: comma-separated `host[:port]` probes re-resolved after host wake.
- `DORYD_MEMORY_MB` / `DORYD_CPUS`: helper VM resources.
- `DORYD_ENGINE_ROOTFS`: optional prebuilt engine rootfs.
- `DORYD_GPU=venus`, `DORYD_AMD64=1`, `DORYD_PUBLISH_HOST=0.0.0.0`: opt-in engine modes.
- `DORYD_HV_RESTART_LIMIT`: helper crash restart budget, default `3`.

## Local domains

`NetworkingController` owns the non-privileged `*.dory.local` path. When `DORYD_NETWORKING=1` or
`DORYD_DNS_PORT` is set, `doryd` starts a UDP DNS server bound to `127.0.0.1` on a high port
(`1053` by default), starts the high-port HTTP proxy, and starts a high-port TLS proxy backed by a
`DoryLocalCA` identity. The XPC surface exposes
`networkReplaceRoutes` for app-fed `{hostname,address,port}` route tables and `networkStatus` for the
active suffix, ports, listener state, and route list.

This intentionally does not mutate `/etc/resolver`, pf, or the system trust store. Those remain
separately-authorized privileged helper work.

`DoryLocalCA` can generate the local CA, issue per-domain certificates, and export PKCS#12 identities
with private key material at `0600`. Installing the CA into the system trust store is represented only
as `systemTrustInstallCommand()`; doryd does not execute it automatically.

`dory-network-helper` is the privileged execution path for that plan. It reads a
`NetworkingAuthorizationPlan` JSON document, re-derives the expected plan from the scalar
configuration, refuses tampered paths/commands, and then writes `/etc/resolver/<suffix>`,
`/etc/pf.anchors/dev.dory`, loads it as `com.apple/dev.dory` under macOS's built-in `com.apple/*`
anchor point, enables pf, and installs LocalCA trust when present. Use `--dry-run --plan-json -` to
validate a plan without touching the system.

## Machine lifecycle

`MachineManager` is doryd's per-machine helper owner. When `DORYD_VMM_HELPER` points at an executable,
the daemon exposes `machineCreate`, `machineStart`, `machineStop`, `machineDelete`, and `machineList`
over XPC and starts one helper process per machine with the machine id, state dir, kernel, rootfs,
memory, and CPU arguments.

Machine definitions are durable: `machineCreate` writes
`<machine-state-dir>/<id>/machine.json` at `0600`, and a restarted doryd reloads those definitions as
stopped machines. Starting a reloaded machine launches a fresh per-machine `dory-vmm` helper against
the same state directory.

The package includes a `DoryVMMKit` target plus a `dory-vmm` executable. In normal doryd mode, when
`--kernel` and `--rootfs` are present, the helper builds a Virtualization.framework VM configuration,
attaches the rootfs as `/dev/vda`, enables entropy, balloon, serial logging, and virtio-socket, starts
the VM, exposes `state-dir/dockerd.sock` as a raw proxy to guest vsock port `1026`, and waits for the
guest control port `1024`. It duplicates the VZ connection fd into the Rust agent client, performs a
real `info` RPC, and only sends ready handoff with the agent's reported build after `dory-agent`
answers. In development, `doryd` can discover `.build/debug/dory-vmm`; release bundles should still
set `DORYD_VMM_HELPER` explicitly and sign the helper with the virtualization entitlement.

For contract tests and legacy callers, `--exit-after-handoff`, `--hold-seconds`, `--handoff-only`, or
missing `--kernel`/`--rootfs` keep the immediate handoff shim behavior.

By default, doryd also creates a private `0600` Unix handoff socket per machine and passes
`--handoff-sock` to the helper. A helper must connect back with a JSON `VmmReadyMessage`; it may also
attach file descriptors with `SCM_RIGHTS`. Required-handoff machines stay `starting` until that message
arrives, then become `running` with the reported agent build, dockerd socket path, shell socket path,
balloon control socket path, and fd count in status. `DORYD_VMM_READY_HANDOFF=0` disables the wait for
tests or legacy helpers.

This is the doryd-side lifecycle and the helper-side VZ scaffold. A real on-hardware ready result
still depends on a signed helper plus a bootable kernel/rootfs where `dory-agent` runs as PID 1 and
listens on the expected vsock ports.

## Remote machines

`RemoteMachineManager` embeds the Rust SSH/sync stack through `DoryCore.connectRemoteAgent`. SSH
private keys are loaded by identifier from the macOS Keychain service `dev.dory.ssh` by default; tests
inject an in-memory key store. The XPC surface uses plist-safe dictionaries:

- `remoteConnect(config)`: requires `id`, `host`, `user`, `privateKeyID`, `hostKey`, `endpointPath`,
  and `remoteRoot`; optional `port`, `build`, `hostKeyType`, and endpoint variants.
- `remotePush(id, localRoot, remoteRoot)`: runs host-authoritative sync; an empty `remoteRoot` uses the
  configured default.
- `remoteStatus(id)`: returns `state`, `lastError`, and the latest `info`/`telemetry` dictionaries.

## Health and incidents

`HealthReporter` emits daemon-native checks in the same result shape as `dory doctor --json`:
`id`, `status`, `code`, `title`, `detail`, plus optional `action` and `data`. The XPC protocol exposes
both `health` (dictionary) and `doctorJSON` (pretty JSON string) so the app and CLI can consume the
same contract while more doctor checks move in-process.

The basic socket/API group now mirrors the pinned doctor ids for `socket.exists` and `socket.ping`;
the latter performs an in-process Docker `GET /_ping` over the configured unix socket.

`IncidentWriter` is doryd's single incident timeline writer. It appends whole JSON lines under one
process-local lock, creates the file at `0600`, and honors `DORY_INCIDENTS` in the daemon entry point
with the existing default of `~/.dory/incidents.jsonl`. The XPC `incidents(limit)` method returns the
newest entries first.

## Host Sleep/Wake

`HostWakeCoordinator` registers an `IORegisterForSystemPower` observer through `IOKitPowerEventSource`
on its own run-loop thread, so it keeps working under `dispatchMain()` and with the app closed. On
`kIOMessageSystemHasPoweredOn`, it re-runs docker guest `clockSync` when the docker tier is running,
re-probes configured DNS targets, and records a `host.wake` incident.
