# Opportunity #5 — pod metrics: ALREADY WON (no code needed)

Date: 2026-07-02. Verified live against Dory's one-click k3s on this machine.

## The incumbent gap
OrbStack issue #2217 (open since Nov 2025): `kubectl top pod` fails with
`podmetrics.metrics.k8s.io not found`; HPA/VPA depend on pod metrics and can't function.

## Dory's result — pod metrics served out of the box
Dory's `KubernetesProvisioner` runs `rancher/k3s … --disable=traefik` (metrics-server is NOT disabled),
so k3s bundles and deploys metrics-server automatically. Live output:

```
$ kubectl top nodes
NAME           CPU(cores)   CPU(%)   MEMORY(bytes)   MEMORY(%)
e80c04178154   254m         5%       552Mi           13%

$ kubectl top pod -A
NAMESPACE     NAME                                      CPU(cores)   MEMORY(bytes)
kube-system   coredns-...                               13m          12Mi
kube-system   local-path-provisioner-...                3m           7Mi
kube-system   metrics-server-...                        39m          13Mi
```

`kubectl top pod` returning real per-pod CPU/memory is exactly the capability #2217 reports missing in
OrbStack. **Dory already has it; no code change required.**

Timing note for demos: metrics-server is `ContainerCreating` for ~13s after node-Ready, and the metrics
API begins serving ~20s after node-Ready — so a demo should wait ~30s before running `top`.

Caveat (honesty): an end-to-end HPA-scaling capture was not cleanly recorded in this session (the
verification loop's glob matched the `50%` target substring prematurely and the test cluster was torn
down before HPA populated `cpu: X%/50%`). HPA reads the same metrics API that `top pod` demonstrably
serves, so it follows — but a clean HPA screenshot/GIF is a TODO for the marketing demo.

## Action
- Marketing/docs: a short "local HPA that actually works" demo (deploy → `kubectl autoscale` → load →
  watch it scale) — capture the HPA populating a real target %.
- Optionally pin the metrics-server version / add a readiness `--k8s` assertion that `top pod` returns
  rows, so a future k3s bump can't silently regress it.
