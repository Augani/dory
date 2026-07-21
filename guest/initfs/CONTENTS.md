# Dory VM initfs

`guest/initfs/build.sh` builds the initfs images used by Dory's VM engines:

- `guest/out/initfs-arm64.ext4`
- `guest/out/initfs-amd64.ext4`

The builder is intentionally reproducible from pinned public inputs in `guest/initfs/PINS`:

- Alpine minirootfs 3.21.7 for `arm64` and `amd64`
- Docker static 29.6.1 for `arm64` and `amd64`
- crun 1.28 static OCI runtime for explicit `--runtime crun` use on `arm64` and `amd64`
- FEX-Emu 2607 commit `1cc4b93e7a71c883ec021b71359f136394dc1f3c`, Dory's
  hash-locked container-FD, proc-less chroot, and nested-exec patch, and static-PIE ARM64
  executables on `arm64`
- Dory's guest agent from `guest/out/dory-agent-<arch>`

Runtime contents added by Dory:

- `/sbin/init`: mounts `proc`, `sysfs`, `devtmpfs`, `devpts`, `tmpfs` for `/run` and `/tmp`, and cgroup v2, then execs `dory-agent` as PID 1.
- `/usr/bin/dory-agent`: guest RPC agent listening on vsock port 1024.
- `/usr/local/bin/dockerd`, `containerd`, `runc`, `runc.real`, `dory-runc`, `crun`, `docker-init`, `docker-proxy`, `ctr`, `docker`, and `containerd-shim-runc-v2`. `runc` and `dory-runc` enter Dory's wrapper, which injects the read-only private FEX bundle before delegating to `runc.real`; covering the conventional path is required for BuildKit. crun remains selectable explicitly.
- `/usr/lib/dory/fex`: the static-PIE, read-only FEX runtime, configuration data,
  source/build provenance (including the exact Ubuntu snapshot package inventory), and redistribution notices used for seccomp-correct
  x86-64 translation on Apple Silicon. Dory relocates translator-owned descriptors above the guest's
  normal low-FD range so descriptor-sensitive tools such as `mmdebstrap` see native Linux semantics.
  Static PIE linking keeps the binfmt interpreter available across nested `chroot` boundaries and
  relocatable around guest VMA reservations without copying Dory internals into user-created root
  filesystems. Kernel-native x86 shebang handling, private interpreter-state propagation, canonical
  merged-root paths, and argument-preserving descriptor exec keep shell, Python, package-manager,
  Docker exec, and inherited-seccomp chains on one Linux-compatible execution path.
  The OCI wrapper also injects a reserved 1 MiB `nosuid,nodev,noexec` tmpfs at `/run/dory-fex`;
  every translated process in one container shares its private FEXServer socket there, including
  package-manager sandbox users with no writable home directory.
- `/etc/resolv.conf` and `/etc/hostname`.
- `iptables`/`ip6tables`, loop-device and ext4 tools, and cgroup-v2 support used by Dory's
  dedicated sandbox VMs for uid-scoped egress policy and bounded scratch storage. Sandbox workload
  uid/gid and process, file-size, open-file, and wall-time constraints are applied by `dory-agent`
  before it execs untrusted code.
- Standard runtime directories: `/var/lib/docker`, `/var/run`, `/var/log`, `/run`, `/tmp`.

Boot behavior:

- Bring up `lo` and, when present, `eth0` via BusyBox `udhcpc`.
- Validate and expand an existing ext4 filesystem, mount `/dev/vdb` at `/var/lib/docker`, and run
  `fstrim` at boot, hourly, and during shutdown so virtio discard can return free blocks to the host.
  The host-generated boot contract
  permits formatting only for a validated, unallocated sparse blank. Existing ext4 resize or mount
  failures power off; the generic init also refuses to start dockerd without the persistent mount.
- Start `dockerd` only on `unix:///var/run/docker.sock`; host access is relayed through the guest
  agent's vsock service, so no unauthenticated Docker TCP API exists inside the guest network.
- Enable Docker's age and value-aware BuildKit garbage collection with a 2 GB cache ceiling. Active
  build data is preserved while unused cache is reclaimed before it can dominate the sparse drive.
- Listen on TCP 2377 for a shutdown request, trim, sync, unmount Docker state, and power off.
- Exec `/usr/bin/dory-agent` as PID 1 when present.
- Hand PID 1 to `docker-init` only when `dory-agent` is absent, falling back to a long sleep loop.

To inventory a built image on a machine with `debugfs`:

```sh
debugfs -R 'ls -l /' guest/out/initfs-arm64.ext4
debugfs -R 'ls -l /usr/local/bin' guest/out/initfs-arm64.ext4
debugfs -R 'cat /sbin/init' guest/out/initfs-arm64.ext4
```
