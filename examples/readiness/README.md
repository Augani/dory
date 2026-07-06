# Dory Readiness Examples

This folder is a committed, user-shaped readiness pack for validating a Dory app build after you
install or launch it. It uses the same things a user expects to work:

- Docker API/version/info
- image pull/build/run
- published localhost ports
- `*.dory.local` reverse-proxy routing
- bind mounts, named volumes, custom networks, DNS
- logs, inspect, cp, save/load, resource limits
- Docker Compose via the Docker CLI plugin
- Dockerized Next.js app build/run with a live browser URL
- host AI bridge reachability via `host.dory.internal` for Metal-backed macOS services
- Linux machine create/start/stop/exec/commit/clone behavior
- optional Kubernetes via Dory's k3s container path

The suite defaults to the tools bundled in `/Applications/Dory.app` and the Dory socket at
`~/.dory/dory.sock`, so it does not require Docker Desktop, Colima, OrbStack, or a host Docker
install.

Run the default Docker + Compose suite against the installed app:

```sh
examples/readiness/run.sh
```

Run Kubernetes too:

```sh
examples/readiness/run.sh --with-kubernetes
```

Open the Dockerized Next.js app in your browser and leave it running on a fixed port
(`http://127.0.0.1:18081` by default):

```sh
examples/readiness/run.sh --only-nextjs --open-browser
```

Use another fixed port if needed:

```sh
examples/readiness/run.sh --only-nextjs --open-browser --nextjs-port 3001
```

Skip the host AI bridge check when you only want Docker plumbing:

```sh
examples/readiness/run.sh --skip-host-ai
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

- Next.js is included by default because it catches real-world Docker build, Node, app-server,
  port-forward, and browser-opening behavior. Use `--skip-nextjs` for a faster infrastructure-only
  pass.
- The host AI bridge check starts a tiny macOS HTTP service and verifies containers on both the
  default Docker network and a custom network can call it at `host.dory.internal`. The shared VM
  bridges ports `11434`, `1234`, and `18190` from containers to macOS loopback. This is the
  supported Apple GPU path for AI workloads today: run the accelerator on macOS with Metal
  (Ollama, LM Studio, MLX, llama.cpp, etc.) and call it from Linux containers. In-guest GPU
  compute is tracked as an experimental virtio-gpu Venus/Vulkan path gated by virglrenderer and
  MoltenVK; release bundles can carry that renderer only when a compatible pinned virglrenderer
  artifact is available.
- `docker run` and `docker exec` exit codes work, but attached stdout/stderr may be quiet through
  the current Dory HV/gvproxy path. The suite keeps these as explicit checks so this user-visible
  behavior does not disappear into a broad "green" run.
- Linux machines are included by default. Use `--skip-machines` only when you need a quick Docker
  and Compose-only pass.

Use this pack with the lower-level engine suite when you need device/VM-specific coverage:

```sh
scripts/readiness.sh --engines dory --online --file-watch
```
