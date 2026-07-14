# Contributing to Dory

Thanks for your interest in improving Dory. This is a native macOS app written in Swift/SwiftUI.

## Getting set up

- macOS 15 (Sequoia) or later, on Apple silicon or Intel
- Xcode 26 or later

```sh
git clone https://github.com/Augani/dory.git
cd dory
scripts/build.sh    # compile-check
scripts/test.sh     # run the test suite
```

You can also open `Dory.xcodeproj` in Xcode and build/run from there.

Rebuilding the Apple Silicon guest additionally requires Rust, `e2fsprogs`, and `patchelf`:

```sh
brew install e2fsprogs patchelf
guest/initfs/build.sh arm64
```

The builder verifies every downloaded package, the relocated FEX output, the toolchain fingerprint,
and the final ext4 contents before publishing `guest/out/initfs-arm64.ext4`.

## Project layout

| Path | What it holds |
|---|---|
| `Dory/Models` | `AppStore` (the single observable app state) and domain models |
| `Dory/Runtime` | The `ContainerRuntime` protocol and its backends (Docker, Apple, Shared VM, Mock) |
| `Dory/Shim` | The `doryd` Docker-API socket server |
| `Dory/Compose` | The bounded official Compose v2 runner plus YAML utilities used by machine recipes |
| `Dory/Net` | Local CA / TLS, `*.dory.local` routing, DNS, port forwarding |
| `Dory/Engine` | Healthcheck state machine, event synthesis, anonymous-volume tracking |
| `Dory/Features` | SwiftUI views, organized by screen |
| `Dory/DesignSystem` | Theme, glyphs, and shared components |
| `Packages/ContainerizationEngine` | DoryHV, the raw Hypervisor.framework engine, plus the Virtualization.framework helper fallback |
| `DoryTests` / `DoryUITests` | Unit, integration, and UI tests |

## Coding conventions

- **Self-documenting code.** Skip comments that restate what the code already says; reserve them
  for genuinely non-obvious invariants.
- **Defensive by default.** Validate inputs, prefer `guard` for early exits, and use optional
  chaining / nil-coalescing over force-unwraps.
- **Strict types.** Avoid `Any`; prefer enums over stringly-typed values.
- **SwiftUI patterns.** State lives in `AppStore` (an `@Observable @MainActor` class) injected via
  `@Environment`. Views are pure expressions of state, with no view models.
- **No new dependencies.** The transport, YAML parser, and Docker-API client/server are
  intentionally hand-rolled. Keep it that way unless there's a strong reason.

## Before opening a pull request

1. `scripts/build.sh` succeeds.
2. `scripts/test.sh` passes.
3. New behavior has a test where practical.
4. Commits are focused, with `type: description` messages (`feat:` / `fix:` / `refactor:` /
   `docs:` / `test:`).

## Public release prerequisites

The public Release workflow fails closed unless repository configuration includes:

- Developer ID/notarization secrets listed at the top of `.github/workflows/release.yml`;
- `SPARKLE_PRIVATE_KEY` (the existing secret name; `SPARKLE_ED_PRIVATE_KEY` is accepted as a
  legacy fallback) and `HOMEBREW_TAP_DEPLOY_KEY`, an Ed25519 deploy key with write access only to
  `Augani/homebrew-dory`;
- a clean physical Apple-silicon runner labeled `self-hosted`, `macOS`, `arm64`, `dory`, and
  `release`, with the compatible Venus virglrenderer/MoltenVK runtime, at least 30 GiB free, and a
  persistent runner home shared by consecutive workflow jobs; and
- only when explicitly running the later roadmap track (`DORY_ENABLE_INTEL_ROADMAP=1`), a physical
  Intel runner labeled `self-hosted`, `macOS`, `intel`, and `dory`. Intel is skipped by default and
  never blocks or contributes artifacts to the Apple-Silicon release.

Release jobs rebuild guest assets from the release SHA, run two independent clean-install
candidate gates, then stage immutable artifacts without publishing. The dedicated runner executes
the isolated 16→128 GiB growth/discard/persistence gate, then the bounded
runtime/backpressure/restart gate followed by the eight-hour endurance and 25-hour
same-connection TCP gates concurrently. A later job with fresh
credentials must rehash that exact candidate and the runner-local evidence before publication;
missing hardware, credentials, persistent evidence, or either duration pass fails closed.

## Reporting issues

Open a GitHub issue with steps to reproduce, what you expected, what happened, and your macOS and
Dory versions.

By contributing you agree that your contributions are licensed under the project's
[GPL-3.0](LICENSE) license.
