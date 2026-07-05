# Dory Readiness Examples

This folder is a committed, user-shaped readiness pack for validating a Dory app build after you
install or launch it. It uses the same things a user expects to work:

- Docker API/version/info
- image pull/build/run
- published localhost ports
- bind mounts, named volumes, custom networks, DNS
- logs, inspect, cp, save/load, resource limits
- Docker Compose via the Docker CLI plugin
- Linux machine create/start/stop/exec/commit/clone behavior
- optional Kubernetes via Dory's k3s container path

Run the default Docker + Compose suite against the installed app:

```sh
examples/readiness/run.sh
```

Run Kubernetes too:

```sh
examples/readiness/run.sh --with-kubernetes
```

The runner defaults to:

- app: `/Applications/Dory.app`
- Docker socket: `unix://$HOME/.dory/dory.sock`
- kubeconfig: `$HOME/.kube/dory-config`

Useful overrides:

```sh
DORY_APP=/path/to/Dory.app examples/readiness/run.sh
DORY_DOCKER_HOST=unix://$HOME/.dory/engine.sock examples/readiness/run.sh
DORY_READINESS_PROJECT=myrun examples/readiness/run.sh --keep
```

Current known-gate checks:

- `docker run` and `docker exec` exit codes work, but attached stdout/stderr may be quiet through
  the current Dory HV/gvproxy path. The suite keeps these as explicit checks so this user-visible
  behavior does not disappear into a broad "green" run.
- Linux machines are included by default. Use `--skip-machines` only when you need a quick Docker
  and Compose-only pass.

Use this pack with the lower-level engine suite when you need device/VM-specific coverage:

```sh
scripts/readiness.sh --engines dory --online --file-watch
```
