# Dory VM initfs

`guest/initfs/build.sh` builds the initfs images used by Dory's VM engines:

- `guest/out/initfs-arm64.ext4`
- `guest/out/initfs-amd64.ext4`

The builder is intentionally reproducible from pinned public inputs in `guest/initfs/PINS`:

- Alpine minirootfs 3.21.7 for `arm64` and `amd64`
- Docker static 27.5.1 for `arm64` and `amd64`
- Dory's guest agent from `guest/out/dory-agent-<arch>`

Runtime contents added by Dory:

- `/sbin/init`: mounts `proc`, `sysfs`, `devtmpfs`, `devpts`, `tmpfs` for `/run` and `/tmp`, and cgroup v2.
- `/usr/bin/dory-agent`: guest RPC agent listening on vsock port 1024.
- `/usr/local/bin/dockerd`, `containerd`, `runc`, `docker-init`, `docker-proxy`, `ctr`, `docker`, and `containerd-shim-runc-v2`.
- `/etc/resolv.conf` and `/etc/hostname`.
- Standard runtime directories: `/var/lib/docker`, `/var/run`, `/var/log`, `/run`, `/tmp`.

Boot behavior:

- Bring up `lo` and, when present, `eth0` via BusyBox `udhcpc`.
- Mount `/dev/vdb` at `/var/lib/docker` when a persistent Docker state disk is attached.
- Start `/usr/bin/dory-agent` when present.
- Start `dockerd` on `unix:///var/run/docker.sock` and `tcp://0.0.0.0:2375`.
- Listen on TCP 2377 for a shutdown request, sync, unmount Docker state, and power off.
- Hand PID 1 to `docker-init` when present, falling back to a long sleep loop.

To inventory a built image on a machine with `debugfs`:

```sh
debugfs -R 'ls -l /' guest/out/initfs-arm64.ext4
debugfs -R 'ls -l /usr/local/bin' guest/out/initfs-arm64.ext4
debugfs -R 'cat /sbin/init' guest/out/initfs-arm64.ext4
```
