# Apple `container` Backend Correctness — Design Spec

**Scope:** correctness of the *already-wired* Apple `container` surface, not endpoint completeness. Dory's switch-driver engine is the Shared-VM in-process `dockerd` (default), which — like the Docker backend — is a full transparent proxy (`supportsRawProxy == true`), so it is *not* in scope here. This cycle targets the **non-proxy** runtimes (`AppleContainerRuntime`, and by sharing, the mock), where Dory's own `DockerShim` translates each endpoint by hand. The goal: where a real `docker` CLI client (or Dory's own Compose engine) actually drives the Apple backend, it must not get a *wrong* answer. Today several wired endpoints return fabricated success.

The audit found four wired-but-wrong behaviors, ranked by blast radius:

1. **Exit codes are fabricated.** `DockerShim` hardcodes `POST /containers/{id}/wait` → `{"StatusCode":0}` (`DockerShim.swift:108`), and `AppleContainerRuntime` does not override `containerExitCode(_:)`, so the protocol-extension default returns `nil`. Consequence: `docker wait`, foreground `docker run`, and Compose `service_completed_successfully` (`ComposeEngine.waitForCompletion`, `ComposeEngine.swift:136`) **always report success** even when the container exited non-zero. This silently breaks CI-style "run a job, check it passed" flows and `depends_on: condition: service_completed_successfully`.
2. **CPU is always 0 in the snapshot.** `AppleContainerRuntime.map(_:stats:)` and the Shared/Docker container list both feed the GUI and `GET /containers/json`; the Apple path hardcodes `cpuPercent: 0` (`AppleContainerRuntime.swift:92`) even though `statsByID` already fetched `ACStats`. `sampleCPU` (used by the detail view) computes a delta but divides by wall-clock only, never by core count, so a 4-core container pegged at 400% wall reports 100% — but more importantly the *list* CPU is dead. A real `docker stats` against the Apple backend would surface this if ever wired.
3. **Image-pull progress is a single fake blob.** `DockerShim.pullImage` emits one `{"status":"Pulled ..."}` line *after* `runtime.pull` returns (`DockerShim.swift:150`). Real dockerd streams incremental `{"status":"Pulling fs layer","id":...,"progressDetail":{...}}` objects per layer. A `docker pull` against the Apple backend shows nothing, then "Pulled", which misleads scripts that parse pull progress and gives no liveness during a long pull.
4. **`logs`/`streamLogs` drop timestamps and the level is keyword-guessed.** `AppleContainerRuntime.logs`/`streamLogs` always emit `timestamp: ""` (`AppleContainerRuntime.swift:156,181`), so the shim's `logsResponse` writes frames with no leading RFC3339 timestamp even though the request implies `timestamps=1`. `container logs` does not interleave a timestamp like dockerd's `--timestamps`, but Dory can pass `--timestamps`-equivalent or fall back honestly rather than emitting a bare line the CLI then can't align.

## Decisions

The fix is concentrated in two pure, testable translation seams plus two small runtime methods. No new endpoints are synthesized; we only correct values on endpoints that already run.

- **Real exit codes (highest value).** Add `containerExitCode(_:)` to `AppleContainerRuntime` backed by `container inspect`. The Apple status JSON exposes the exited state but `ACStatus` currently decodes only `state`/`startedDate`/`networks` — extend `ACStatus` with `exitCode: Int?` (Apple's `container inspect` status carries the process exit code; decode it defensively as optional). Then route the shim's `/wait` through the runtime instead of a constant: a new pure helper `ContainerWait.statusCode(_ code: Int?) -> Int` (nil → treat as unknown-but-nonzero per dockerd's "could not determine" is *not* desirable; nil → `0` only when the container is genuinely gone — so the shim passes the inspected code through and falls back to `0` *only* when inspect itself is unavailable, matching today's behavior for the gone case but reporting the truth when present). The shim's `/wait` branch becomes `await runtime.containerExitCode(parts[1])` mapped through `ContainerWait.statusCode`. `ComposeEngine.waitForCompletion` already calls `containerExitCode` directly, so adding the override fixes `service_completed_successfully` with zero call-site change.
- **Honest list CPU.** Thread the already-fetched `ACStats.cpuUsageUsec` into `map(_:stats:)`. Because a single `container stats --no-stream` sample is a cumulative counter (not a rate), the snapshot cannot derive an instantaneous % from one shot — so the *honest* fix is: leave list `cpuPercent` at `0` (a single cumulative read is not a rate) but **fix `sampleCPU` to divide by online CPU count** so the detail-view live number is correct. Add `cpus: Int?` decoding to `ACStats` (Apple reports per-core usage or a cpu count; if absent, fall back to `ACResources.cpus` from the container config, else `1`). Extract the math into a pure `AppleStatsMath.cpuPercent(deltaUsec:elapsedUsec:cpus:) -> Double` clamped `0…(100×cpus)` then normalized — matching dockerd's `(cpuDelta/systemDelta)×onlineCPUs×100` semantics as closely as a usec-counter allows. This keeps the COMPATIBILITY "two-sample CPU sampler" claim honest.
- **Streamed pull progress.** Keep `runtime.pull` (blocking `container image pull`) but make `DockerShim.pullImage` a *streaming* response (`ShimResponse.streaming`) that emits an initial `{"status":"Pulling from <repo>","id":"<tag>"}` line, runs the pull, and on completion emits `{"status":"Status: Downloaded newer image for <ref>"}` then `{"status":"Pulled ..."}`. This is honest (we cannot synthesize per-layer byte progress from a CLI that doesn't expose it) but matches dockerd's *framing* (newline-delimited JSON status objects, a "from"/"Downloaded" pair) so CLI progress parsers don't choke. The JSON shaping moves into a pure `PullProgress.lines(repo:tag:reference:) -> [String]` for testing.
- **Logs honesty.** Make `AppleContainerRuntime.logs`/`streamLogs` request timestamps from `container logs` if supported (`--timestamps` probe), parsing the leading RFC3339 token into `LogLine.timestamp` via the existing `DockerLogFrames.makeLine` shape; when unavailable, leave `timestamp: ""` (current behavior) rather than fabricate. Factor the line-splitting into a pure `AppleLogParse.line(_ raw: String) -> LogLine` so the timestamp/level extraction is unit-tested and shared by both the batch and follow paths.

Reuse, not reinvention: all four lean on existing patterns — `DockerLogFrames.makeLine` (timestamp+level), the `ShimResponse.streaming` used by `/build` and `/events`, the `runJSON` decode path, and the `ContainerSpec`/`DockerCreateRequest` round-trip already covered by tests.

## Components

- **`Dory/Runtime/Apple/AppleContainerModels.swift`** (modify): add `exitCode: Int?` to `ACStatus`; add `cpus: Int?` (and, if present in the JSON, `systemUsageUsec`/`onlineCPUs`) to `ACStats`. Decoding stays defensively optional — pure data, no behavior.
- **`Dory/Runtime/Apple/AppleContainerRuntime.swift`** (modify):
  - add `func containerExitCode(_ id: String) async -> Int?` via `container inspect <id> --format json`, reading `status.exitCode` (nil when running or absent).
  - `sampleCPU`: replace the wall-clock-only math with `AppleStatsMath.cpuPercent(...)` passing the resolved CPU count.
  - `logs`/`streamLogs`: route raw lines through `AppleLogParse.line`.
- **`Dory/Runtime/Apple/AppleStatsMath.swift`** (new, pure/testable): `static func cpuPercent(deltaUsec: Int64, elapsedUsec: Double, cpus: Int) -> Double`.
- **`Dory/Runtime/Apple/AppleLogParse.swift`** (new, pure/testable): `static func line(_ raw: String) -> LogLine` (RFC3339-prefix detection → `timestamp`/`message` split + reused level heuristic).
- **`Dory/Shim/ContainerWait.swift`** (new, pure/testable): `static func statusCode(_ inspected: Int?) -> Int` (inspected code passthrough; nil → `0` fallback for the container-gone case).
- **`Dory/Shim/PullProgress.swift`** (new, pure/testable): `static func lines(repo: String, tag: String, reference: String) -> [String]` (newline-free JSON status strings, dockerd-shaped framing).
- **`Dory/Shim/DockerShim.swift`** (modify):
  - `/wait` branch → `let code = await runtime.containerExitCode(parts[1]); return ShimResponse.json(Data("{\"StatusCode\":\(ContainerWait.statusCode(code))}".utf8))`.
  - `pullImage` → `ShimResponse.streaming(contentType: "application/json")` emitting `PullProgress.lines(...)` around the `runtime.pull` call. Note: this only affects the non-proxy path; `supportsRawProxy` backends still hit the verbatim proxy and are untouched.

## Error handling

- `containerExitCode` returns `nil` on any inspect failure or while the container is still running; `ContainerWait.statusCode(nil)` yields `0` (the prior behavior for the gone case) so we never throw from `/wait`. A *present, nonzero* code now propagates truthfully — that is the fix.
- `sampleCPU` keeps its `try?`/guard chain; if CPU count can't be resolved it defaults to `1` (current effective behavior) so the number is never worse than today, only better when count is known. Output stays clamped `0…100` after per-core normalization.
- `pullImage` streaming: if `runtime.pull` throws, emit a final `{"errorDetail":{"message":...},"error":...}` JSON line (dockerd's error framing) and stop the stream — the CLI then reports a failed pull instead of a hung stream. No partial "Pulled" line is emitted on failure.
- `AppleLogParse.line` never throws; a line with no parseable timestamp keeps `timestamp: ""` (honest) and the message verbatim.

## Testing

Unit (`DoryTests/`), all on pure logic, following the `RuntimeHelpersTests`/`ReviewFixTests` style:

- **`AppleStatsMathTests`** — `cpuPercent(deltaUsec: 800_000, elapsedUsec: 800_000, cpus: 1)` → `100`; `cpus: 4` with the same full-core delta → `25` (per-core normalized); zero delta → `0`; negative/garbage delta clamped to `0`; over-100 wall on 1 core clamped to `100`.
- **`ContainerWaitTests`** — `statusCode(0) == 0`; `statusCode(137) == 137`; `statusCode(nil) == 0`. Paired with a `ReviewFixTests`-style fake runtime returning `containerExitCode == 137` to assert Compose `service_completed_successfully` now *fails* (mirror the existing `#13` test at `ReviewFixTests.swift:121`, flipping the expectation for a nonzero Apple-style code).
- **`PullProgressTests`** — `lines(repo:"nginx",tag:"latest",reference:"nginx:latest")` produces valid JSON objects (decodable), the first carries a `status` containing "Pulling from nginx", the last contains "nginx:latest", and none contains an embedded `\n`.
- **`AppleLogParseTests`** — RFC3339-prefixed line → non-empty `timestamp` + stripped `message`; bare line → empty `timestamp`, verbatim `message`; an `ERROR`-bearing message → `.error` level (reusing the existing heuristic).

Build/snapshot verification: `scripts/build.sh` (must compile clean — new files added to the target), then `scripts/shots.sh` for the container-detail CPU sparkline + logs surfaces that consume `sampleCPU`/`streamLogs`. CLI cross-check (manual, when an Apple `container` host is available): `DORY_RUNTIME=appleContainer`, then `docker run --rm alpine sh -c 'exit 7'; echo $?` must print `7`; `docker wait <id>` of an exited-nonzero container must print the real code; `docker pull alpine` must show newline-delimited JSON status objects.

## Non-goals (this cycle)

- Per-layer byte-accurate pull progress (the `container` CLI does not expose it — synthesizing fake byte counts would be *less* honest than the status-framing fix).
- True instantaneous list-CPU from a single cumulative sample (impossible without a second read; the detail-view two-sample path is the correct place and is what we fix).
- Full create-body flag coverage (the long tail in COMPATIBILITY's `🟡` row) — this track is correctness of wired flags, and the wired create path (image/cmd/env/ports/labels/restart) already round-trips; expanding mounts/network-mode/ulimits/cap-add is a separate completeness track.
- Swarm, plugins, secrets, distribution, or any endpoint no client runs against the Apple backend — explicitly out of scope.
- Any change to the Shared-VM or Docker proxy backends (they forward verbatim and are already correct).
