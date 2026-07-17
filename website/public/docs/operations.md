# Operate Dory

This guide covers the stable Dory 0.3.2 operating surface on Apple Silicon Macs running macOS 14 or later.

## Install and verify

```sh
brew install --cask Augani/dory/dory
open -a Dory
dory version
dory doctor --active
```

Dory provides `docker`, `docker compose`, and `dory` through `~/.dory/bin` while doryd runs. The optional Kubernetes component adds `kubectl`. A separate Docker Desktop or Docker CLI install is not required.

The Homebrew cask and direct download install Docker Core. Use Settings > Components or `dory component install ID` to add Kubernetes, Linux Machines, or individual desktop distributions. The app shows exact signed download and installed sizes before each installation.

When upgrading from an older release, quit Dory, uninstall the old app, and install Dory 0.3.2 Docker Core. Normal uninstall preserves the selected `.dorydrive`. Keep only one Dory.app in Applications, then add the optional components you use.

## Components

```sh
dory component list
dory component install kubernetes
dory component install linux-machines
dory component install desktop-ubuntu
dory component verify desktop-ubuntu
dory component remove desktop-ubuntu
```

Desktop distributions add the shared Linux Desktop Runtime automatically. Removing an optional component deletes only its installed payload. Containers, volumes, cluster state, machine disks, snapshots, and exports stay on the selected data drive.

## Linux desktops and servers

The app separates graphical Linux Desktops from lightweight Linux Servers. A new desktop can use Debian 13, Ubuntu 24.04 LTS, or Kali rolling with Xfce, systemd, Bash, and a configurable login user. Its display uses a true 2x guest framebuffer with matching Xfce scaling and follows the Mac window as it resizes.

Desktop creation also controls CPU, memory, development recipe, Mac home sharing, and scoped folders. Each desktop has a thin-provisioned 64 GiB disk in the selected Dory data drive. Headless servers use Alpine with an initial root `/bin/sh` login. Install `linux-machines` for headless servers or a matching `desktop-*` component for graphical machines.

## Engine resources

Settings > Engine & Daemon controls CPU and the elastic memory ceiling. Applying a change restarts the engine and restores containers that were running. This setting also changes the memory reported by the Docker API to tools such as Minikube.

Use native arm64 images when possible. Common linux/amd64 images use the bundled FEX runtime on Apple Silicon.

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

## Bind mounts and file watchers

```sh
dory mount --json
dory doctor --json --only mounts,watch,filelock
```

These checks cover host edits, write and truncate behavior, locks, spaces in paths, and file-change delivery. Use them when Vite, Tailwind, Webpack, Rails, or another watcher does not rebuild.

## Migrate an existing runtime

Open Settings > Migrate & Compare. Keep the source runtime running and installed while Dory performs its read-only inventory and preflight.

Dory can import from Docker Desktop, OrbStack, Colima, Rancher Desktop, Podman, or another Docker-compatible Unix socket. The transaction can preserve images and tags, named volumes, custom networks, container definitions, writable layers, port bindings, Compose labels, and running, stopped, or paused state.

Validate the imported workload before removing the source. Dory does not delete source data.

## Auto-Idle

```sh
dory mode auto-idle
dory idle status --json
dory idle history --json
```

The app offers Always On, Auto-Idle, Battery Saver, and Manual Stop. Published ports, labeled projects, and Kubernetes can be configured as blockers.

## Diagnose and repair

```sh
dory doctor --json
dory doctor --json --active
dory doctor --json --diff
dory repair all --json
dory support bundle --json --active
```

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
