# Operate Dory

This guide covers Dory's supported operating surface on Apple Silicon Macs running macOS 14 or later.

## Install and verify

```sh
brew install --cask Augani/dory/dory
open -a Dory
dory version
dory doctor --active
```

Dory provides `docker`, `docker compose`, and `dory` through `~/.dory/bin` while doryd runs. The optional Kubernetes component adds `kubectl`. A separate Docker Desktop or Docker CLI install is not required.

The Homebrew cask and direct download install Docker Core. Use Settings > Components or `dory component install ID` to add Kubernetes, Linux Machines, or individual desktop distributions. The app shows exact signed download and installed sizes before each installation.

Use Settings > Updates for a normal in-place upgrade. Dory verifies the signed app and component
candidate, free space, selected drive, compatible schema path, and an exact last-known-good
snapshot before replacement. On next launch it checks the Docker API, a durable volume marker,
pre-existing container and port behavior, and Kubernetes when enabled. Safe replaceable state
rolls back automatically; an unsafe durable-data downgrade produces an owner-only recovery export
instead of guessing. Inspect the same transaction with `dory upgrade status --json` and
`dory upgrade recovery --json`. Uninstall/reinstall remains a recovery option and preserves the
selected `.dorydrive`, but it is not the normal upgrade path.

## Components

```sh
dory component list
dory component install kubernetes
dory component install linux-machines
dory component install desktop-ubuntu
dory component verify desktop-ubuntu
dory component remove desktop-ubuntu --confirm desktop-ubuntu
```

Desktop distributions add the shared Linux Desktop Runtime automatically. Removing an optional component deletes only its installed payload. Containers, volumes, cluster state, machine disks, snapshots, and exports stay on the selected data drive.

## Linux desktops and servers

The app separates graphical Linux Desktops from lightweight Linux Servers. A new desktop can use Debian 13, Ubuntu 24.04 LTS, or Kali rolling with Xfce, systemd, Bash, and a configurable login user. Its display uses a true 2x guest framebuffer with matching Xfce scaling and follows the Mac window as it resizes.

Desktop creation also controls CPU, memory, development recipe, Mac home sharing, and scoped folders. Each desktop has a thin-provisioned 64 GiB disk in the selected Dory data drive. Headless servers use Alpine with an initial root `/bin/sh` login. Install `linux-machines` for headless servers or a matching `desktop-*` component for graphical machines.

### Verified scheduled machine backups

```sh
dory machine backup schedule dev --frequency daily --keep 7 --verify-every 7
dory machine backup status dev
dory machine backup run dev
dory machine backup remove dev
```

Every scheduled run exports a local `.dorymachine` bundle and re-imports it before publication. The
first and configured periodic runs also start a disposable imported machine and require it to run.
Creating the consistent snapshot briefly stops a running source machine and restores its prior
state. Retention touches only scheduler-owned snapshots and archives, never manual snapshots. Dory
does not provide managed S3/offsite backup; copy verified recovery bundles to independent storage
when that is part of your backup policy.

## Engine resources

Settings > Engine & Daemon controls CPU and the elastic memory ceiling. Applying a change restarts the engine and restores containers that were running. This setting also changes the memory reported by the Docker API to tools such as Minikube.

Use native arm64 images when possible. Common linux/amd64 images use the bundled FEX runtime on Apple Silicon.

Build Activity records durable status, logs, cache use, and cancellation for builds launched by the
Dory app. It does not claim safe cancellation control over builds launched by unrelated clients.

## Storage

Default drive:

```text
~/Library/Application Support/Dory/Dory.dorydrive
```

```sh
dory data path
dory data capacity --json
dory data grow 256 --json
dory data backup ~/Desktop/dory.dorybackup
dory data verify ~/Desktop/dory.dorybackup
```

Dory grows sparse Docker storage without reserving the full logical size. It refuses shrinking and unsafe replacement. Restore always targets a new path, and selecting a restored drive is explicit.

## Local networking

Published ports use localhost by default:

```sh
docker run -d --name web -p 8080:80 nginx
curl http://localhost:8080
dory routes --json
```

Optional local domains, trusted HTTPS, ports 80 and 443, and published ports below 1024 use one Dory-owned macOS authorization plan:

```sh
dory network authorization-plan --json
dory network authorize --json --dry-run
dory network authorize --json --apply
```

Settings > Network can also change the Docker bridge subnet, domain suffix, and internal resolver or proxy ports. Use a private /16 through /24 bridge that does not overlap a VPN or local network. Applying a bridge change restarts the engine but preserves data. LAN and Tailscale access are disabled by default and require explicit opt-in.

Corporate connectivity has its own guided Settings > Network profile and CLI lifecycle:

```sh
dory network corporate sample > corporate-profile.json
dory network corporate plan --file corporate-profile.json
dory network corporate apply --file corporate-profile.json
dory network corporate status --json
dory network corporate disable
```

The profile separates the observed macOS system/PAC layer, dockerd pulls, BuildKit/default
container proxy injection, registry mirrors/insecure registries, CA trust scopes, and split DNS.
Plan is non-mutating. Apply preserves unrelated Docker config, uses guest tmpfs for daemon settings,
and restarts only dockerd when its effective digest changes. Status identifies the DNS server,
route, proxy, and CA IDs for every explicit probe and reports bridge/VPN subnet collisions.

## Bind mounts and file watchers

```sh
dory mount --json
dory doctor --json --only mounts,watch,filelock
```

These checks cover host edits, write and truncate behavior, locks, spaces in paths, and file-change delivery. Use them when Vite, Tailwind, Webpack, Rails, or another watcher does not rebuild.

## Agent-ready named sandboxes

Create one prepared environment for repeated local development or agent work:

```sh
dory sandbox create my-project --workspace .
dory sandbox exec my-project -- COMMAND
dory sandbox reset my-project --json
dory sandbox kill my-project
```

Dory installs its core agent toolkit once and detects common project toolchains from the workspace.
Use repeated `--tool` options to select Node, Python, Go, Rust, Java, Ruby, DevOps, Docker CLI, or
Kubernetes tools explicitly. The workspace is mounted read-write at `/workspace`; other host files,
network access, secrets, and the SSH agent remain unavailable unless granted.

Tools and caches persist until the sandbox is reset or killed. Reset returns the guest to its clean
prepared baseline without changing the host workspace. The 8 GB root filesystem is sparse and grows
physically only when data is written. Inspect the current grants and limits with
`dory sandbox inspect NAME --json`.

## Migrate an existing runtime

Open Settings > Migrate & Compare. Keep the source runtime running and installed while Dory performs its read-only inventory and preflight.

Dory can import from Docker Desktop, OrbStack, Colima, Rancher Desktop, Podman, or another
Docker-compatible Unix socket. Choose all objects or an exact set of images, volumes, networks, and
containers; Dory closes required dependencies automatically. Selected-scope capacity, collision,
and portability checks run before writes. Success proves requested, automatically selected,
verified, and deliberately omitted objects, and Dory re-inventories the source before completion so
an omitted object changing during staging cannot hide source drift. Any target mutation is rolled
back if the transaction fails.

Validate the imported workload before removing the source. Dory does not delete source data.

## Auto-Idle

```sh
dory mode auto-idle
dory idle status --json
dory idle history --json
```

The app offers Always On, Auto-Idle, Battery Saver, and Manual Stop. Published ports, labeled projects, and Kubernetes can be configured as blockers.

## Transactional upgrades and recovery

Settings > Updates is the normal in-place path. Before Sparkle takes control, Dory verifies the
signed candidate, archive, free space, component compatibility, selected drive, and readable schema
interval; records the exact last-known-good app, configuration, verified component generation, and
snapshot reference; and quiesces the engine without deleting workloads.

On the next launch Dory checks the Docker API, immutable volume marker, pre-existing container and
published port, plus Kubernetes when enabled. A failed check restores the exact prior app/config and
component generation only when the durable schema remains readable. It never blindly downgrades the
data drive. Unsafe schema rollback stops in a recovery-required state and creates an owner-only
export.

```sh
dory upgrade status --json
dory upgrade recovery --json
```

The commands are read-only. Homebrew installations can use
`brew upgrade --cask Augani/dory/dory`; ordinary uninstall remains a recovery option and preserves
the selected data drive.

## Diagnose and repair

```sh
dory readiness --json
dory doctor --json
dory doctor --json --active
dory doctor --json --diff
dory repair all --json
dory support bundle --json --active
```

`dory readiness` is the fastest automation check: it proves the VM, guest agent, selected data
mount, network, dockerd, host socket/context, and optional Kubernetes separately. Every stage has a
reason code, deadline, elapsed time, and a named non-destructive repair. The Health screen and
doctor JSON also attribute process footprint/FDs/threads, guest memory composition, sparse and
guest disk usage, reclaim candidates, watcher queue pressure, and Dory-owned network state. Three
rising samples warn before a hard resource limit is reached.

Review the repair dry run before adding `--apply`. A broad repair does not restart the engine automatically. Use an explicit engine target and `--restart-engine` only when stopping running workloads is acceptable.

## Clean up

```sh
dory cleanup --json
dory cleanup --json --apply
```

The first command only reports candidates. Named volumes are excluded unless `--include-volumes` is also present.

## Uninstall

```sh
brew uninstall --cask Augani/dory/dory
```

Normal uninstall preserves the selected data drive. Deleting workload data is a separate explicit action.

## Ask for help

Include the Dory version, macOS version, Mac model, failing command or tool, and a redacted support bundle when opening an issue.

For ownership and trust boundaries, read the [architecture guide](architecture.md). For performance
claims and the matching release evidence asset, read [performance evidence](performance.md).
