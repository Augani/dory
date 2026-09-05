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

## Pinned static producer

The reviewed producer for this patch lives in this directory:

```sh
./guest/initfs/vendor/docker-29.6.1-dory1/rebuild.sh arm64
./guest/initfs/vendor/docker-29.6.1-dory1/rebuild.sh amd64
```

The producer records a pre-build input fingerprint for this Dockerfile, rebuild script, patch, PINS, and pinned build constants using root-relative path labels. It refuses to write final candidate files if that fingerprint changes before the final per-file same-filesystem renames. It clones Moby at the exact tag object and commit listed above, applies
`patches/docker-start-intent.patch`, and builds only the patched `dockerd` through Moby's
`hack/make.sh binary-daemon` static build path. It then fetches the already pinned upstream Docker
static tarball from `guest/initfs/PINS`, verifies its SHA-256, replaces only `docker/dockerd`, and
checks that every other upstream static executable remains byte-for-byte unchanged. This preserves
Docker CLI, containerd, runc, docker-init, docker-proxy, ctr, and shim binaries from the upstream
29.6.1 tuple unless a later reviewed change proves one of those binaries also has to change.

The builder is pinned by digest and records its inputs in a receipt beside each generated tarball:

- `golang:1.25.9-bookworm@sha256:298734aec230b5f3e8cee450ce6d7eccc39f1797ba548ee90d57e9803030c6c3`
- `tonistiigi/xx:1.9.0@sha256:c64defb9ed5a91eacb37f96ccc3d4cd72521c4bd18d5442905b95e2226b0e707`
- `debian:12-slim@sha256:88200866dfff7ea7f5cbcb6ec7c8a701889efe6fe859fe64d6990e4b07ea4171` for the Linux `dockerd --version` verification container
- Debian package snapshot `20260713T000000Z` for the build packages installed in the builder
- `SOURCE_DATE_EPOCH=1782422754`, derived from the pinned Moby commit timestamp
- `VERSION=29.6.1-dory1` and
  `DOCKER_GITCOMMIT=8ec5ab355a34b2a0e2b3238d67bdefe77fefa982-dory-start-intent`

Each generated tarball uses the same top-level `docker/` layout consumed by
`guest/initfs/build.sh`. The producer verifies required executables, rejects any non-dockerd byte
change in the upstream tuple, runs `file` on the patched daemon, and executes `dockerd --version`
inside the matching Linux architecture before writing a receipt, and checks Docker's recorded container exit state for that verification container. If runtime verification is explicitly
skipped, the receipt records `runtimeVerification.status=skipped`; such an artifact is not eligible
for production `PINS` replacement until a later run records `passed`. Replacing `guest/initfs/PINS` is a
separate reviewed step after both architecture artifacts and initfs boot validation are complete.
