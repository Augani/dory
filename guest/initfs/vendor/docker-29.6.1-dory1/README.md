# Dory Docker 29.6.1 start-intent patch

This directory carries Dory's maintained source patch for the Docker Engine bundled into the
managed guest initfs. The currently pinned initfs still consumes Docker's upstream static tarballs
from `guest/initfs/PINS`; this patch is staged for review and producer integration before those
binary pins are replaced.

Provenance:

- upstream: https://github.com/moby/moby
- upstream tag: `docker-v29.6.1`
- tag object: `5259f1f37f10f37594a18eab40604e3e91622fe9`
- source commit: `8ec5ab355a34b2a0e2b3238d67bdefe77fefa982`
- upstream license: Apache License 2.0, provided by Moby's `LICENSE` file
- Dory patch: `patches/docker-start-intent.patch`
- Dory patch SHA-256: `0cd760859b4b95ad5f424fa5ea60bb2d48511a5154124adacdf715291ea7d85e`

The patch addresses a pre-acknowledgement start checkpoint window in Docker 29.6.1. Upstream
`daemon/start.go` starts the containerd task before checkpointing Docker's running state. If the
daemon or VM dies after the task has begun executing but before that checkpoint is renamed over
`config.v2.json`, Docker can later restore the container as `created` with exit code 0 even though
work already ran. Dory observed this while injecting a renderer-worker failure during active GPU
work: the shader process emitted its submitted marker, the worker was killed, and the recovered
Docker metadata showed `created exit=0` with no completion marker.

The patch adds a typed `StartIntent` field to Docker's container metadata. Docker checkpoints this
intent after `initializeCreatedTask` and before `Task.Start`; if that checkpoint fails, start returns
an error before the task can execute. Ordinary failed-start cleanup clears the intent. A successful
running checkpoint also clears the intent. During daemon restore, an intent with a live containerd
task is promoted to running using the restored task handles; an intent without a task is resolved to
a stopped interrupted state with exit code 255 and an inspectable error when no containerd exit
status is available. If containerd reports a stopped task with an exit status, Docker preserves that
exit code and exit time. The start-intent reconciliation does not delete the container, writable
layer, config, logs, host config, or volumes; Docker's existing restore-time policies such as
explicit `AutoRemove` handling still apply outside this patch.

Focused validation performed from the patched source clone:

```sh
GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go test -c \
  -o /private/tmp/dory-moby-start-intent-tests/container.test ./daemon/container
GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go test -c \
  -o /private/tmp/dory-moby-start-intent-tests/daemon.test ./daemon
SOCK=/private/tmp/dory-build-endpoint.signed.20260905010631.65811/e.sock
CID=$(DOCKER_HOST=unix://$SOCK docker create --name dory-moby-start-intent-tests debian:12-slim sh -c \
  'set -eu; \
   /tmp/container.test -test.run "Test(StartIntent|ClearStartIntent)" -test.v; \
   /tmp/daemon.test -test.run "Test(ReconcileStartIntent|StartIntentCheckpointFailure|TaskStartFailureCleanup|SuccessfulStartCheckpoint)" -test.v')
DOCKER_HOST=unix://$SOCK docker cp /private/tmp/dory-moby-start-intent-tests/container.test $CID:/tmp/container.test
DOCKER_HOST=unix://$SOCK docker cp /private/tmp/dory-moby-start-intent-tests/daemon.test $CID:/tmp/daemon.test
DOCKER_HOST=unix://$SOCK docker start -a $CID
DOCKER_HOST=unix://$SOCK docker rm -f $CID
```

The actual run copied the two test binaries into a throwaway container on the existing ordinary
build endpoint and passed:

- `TestStartIntentCheckpointsAndLoadsFromDisk`
- `TestClearStartIntentRemovesCheckpointField`
- `TestStartIntentCheckpointFailureDoesNotStartTask`
- `TestTaskStartFailureCleanupClearsIntentOnDisk`
- `TestSuccessfulStartCheckpointClearsIntentOnDisk`
- `TestReconcileStartIntentWithNoTaskMarksExitedWithoutDeletingContainer`
- `TestReconcileStartIntentWithLiveTaskRestoresRunningAndClearsIntent`
- `TestReconcileStartIntentAlreadyRunningClearsIntentOnDisk`
- `TestReconcileStartIntentIndeterminateStatusRetainsIntentOnDisk`
- `TestReconcileStartIntentCreatedTaskDoesNotPromoteRunning`
- `TestReconcileStartIntentStoppedTaskPreservesKnownExitStatus`
- `TestReconcileStartIntentPausedTaskRestoresPausedState`

Producer integration design:

1. Fetch the exact Moby tag object above and check out commit
   `8ec5ab355a34b2a0e2b3238d67bdefe77fefa982`.
2. Apply `patches/docker-start-intent.patch` with `git apply --index` and verify a clean tree aside
   from the patch.
3. Build native Linux Docker static binaries inside a pinned ARM64 builder image or Dory build guest,
   using the Moby project's Docker static build targets for both `linux/arm64` and `linux/amd64`.
   The builder must pin its base image digest, Go/toolchain version, package snapshot, and
   `SOURCE_DATE_EPOCH` from the source commit timestamp before replacing initfs binary pins.
4. Run the focused patch tests above plus Moby's relevant daemon/container start tests under Linux.
5. Replace `docker_arm64` and `docker_amd64` in `guest/initfs/PINS` only after recording the produced
   tarball SHA-256 values and updating the initfs input fingerprint to include this vendor directory.

No runtime metadata rewrite or container deletion is part of this design. The durable intent is the
only authority used to reconcile the interrupted pre-running-checkpoint state. If the already
checkpointed Docker state is Running or Paused but still carries a stale start intent, this patch
only clears that marker; the surrounding upstream restore flow still owns any later reconciliation
for status lookup errors, live-restore shutdown, restart policy, and AutoRemove behavior.

## Proposed pinned static producer

The producer should live in this vendor directory after review, following the existing
`guest/initfs/vendor/fex-2607-dory1` convention: a small `rebuild.sh`, a pinned builder definition,
a package/input inventory, and checked receipts. It should build a complete Docker static tuple, not
only `dockerd`, so the initfs does not mix a patched daemon with unrelated containerd/runc/helper
binaries.

Concrete source and input contract:

- clone `https://github.com/moby/moby` at tag object
  `5259f1f37f10f37594a18eab40604e3e91622fe9` and commit
  `8ec5ab355a34b2a0e2b3238d67bdefe77fefa982`;
- apply `patches/docker-start-intent.patch` and reject any extra source diff;
- use Moby's Dockerfile `all` target, which exports `dockerd`, `docker-proxy`, `containerd`,
  `containerd-shim-runc-v2`, `ctr`, `runc`, `docker-init`, rootless helpers, and container utility
  helpers from scratch;
- override and record the upstream Dockerfile defaults instead of inheriting floating values:
  `GO_VERSION=1.25.9` to match `go.mod`, `BASE_DEBIAN_DISTRO=bookworm`, `XX_VERSION=1.9.0`,
  `CONTAINERD_VERSION=v2.2.5`, `RUNC_VERSION=v1.3.6`, `TINI_VERSION=v0.19.0`,
  `ROOTLESSKIT_VERSION=v3.0.1`, `CRUN_VERSION=1.21`, and
  `CONTAINERUTILITY_VERSION=aa1ba87e99b68e0113bd27ec26c60b88f9d4ccd9`;
- pin the builder base images by digest, including `golang:1.25.9-bookworm`,
  `tonistiigi/xx:1.9.0`, `busybox`, and any source-fetch helper images used by BuildKit;
- use a Debian snapshot timestamp and package inventory for build packages installed by Moby's
  Dockerfile stages, then export that inventory beside the binaries;
- set `SOURCE_DATE_EPOCH` from the Moby source commit timestamp and pass
  `DOCKER_GITCOMMIT=8ec5ab355a34b2a0e2b3238d67bdefe77fefa982` plus a Dory-local version suffix so
  `dockerd --version` identifies the patched tuple without pretending to be the upstream tarball.

Review command shape:

```sh
./guest/initfs/vendor/docker-29.6.1-dory1/rebuild.sh arm64
./guest/initfs/vendor/docker-29.6.1-dory1/rebuild.sh amd64
```

Each invocation should run Docker BuildKit against an isolated build context and output a tarball
with the same top-level `docker/` layout as Docker's static download tarballs, because
`guest/initfs/build.sh` already installs that shape. The tarball must contain at least:

- `docker/dockerd`
- `docker/docker-proxy`
- `docker/containerd`
- `docker/containerd-shim-runc-v2`
- `docker/ctr`
- `docker/runc`
- `docker/docker-init`

Required producer verification before replacing `guest/initfs/PINS`:

1. unpack each produced tarball and verify every required executable exists, is executable, and
   reports the expected architecture;
2. run `file` or `xx-verify --static` equivalents to reject dynamically linked outputs;
3. run `dockerd --version`, `containerd --version`, `runc --version`, `docker-init --version`, and
   `docker-proxy --version` inside the matching Linux architecture;
4. run the focused start-intent test binaries under Linux for both supported architectures;
5. build an initfs from the candidate tarball and rerun the Dory Docker lifecycle checks, including
   interrupted start-intent recovery, before updating `docker_arm64` and `docker_amd64` in
   `guest/initfs/PINS`.

This producer design is intentionally not wired into `guest/initfs/build.sh` or `guest/initfs/PINS`
yet. The current repository change is only the reviewed source patch and provenance/design record.
