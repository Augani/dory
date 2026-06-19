# Contributing to Dory

Thanks for your interest in improving Dory. This is a native macOS app written in Swift/SwiftUI.

## Getting set up

- macOS 26 (Tahoe) or later, on Apple silicon
- Xcode 27 or later

```sh
git clone https://github.com/Augani/dory.git
cd dory
scripts/build.sh    # compile-check
scripts/test.sh     # run the test suite
```

You can also open `Dory.xcodeproj` in Xcode and build/run from there.

## Project layout

| Path | What it holds |
|---|---|
| `Dory/Models` | `AppStore` (the single observable app state) and domain models |
| `Dory/Runtime` | The `ContainerRuntime` protocol and its backends (Docker, Apple, Shared VM, Mock) |
| `Dory/Shim` | The `doryd` Docker-API socket server |
| `Dory/Compose` | YAML parser, interpolation, dependency graph, and the Compose engine |
| `Dory/Net` | Local CA / TLS, `*.dory.local` routing, DNS, port forwarding |
| `Dory/Engine` | Healthcheck state machine, event synthesis, anonymous-volume tracking |
| `Dory/Features` | SwiftUI views, organized by screen |
| `Dory/DesignSystem` | Theme, glyphs, and shared components |
| `Packages/ContainerizationEngine` | In-process VM boot harness on Apple's `containerization` framework |
| `DoryTests` / `DoryUITests` | Unit, integration, and UI tests |

## Coding conventions

- **Self-documenting code.** Skip comments that restate what the code already says; reserve them
  for genuinely non-obvious invariants.
- **Defensive by default.** Validate inputs, prefer `guard` for early exits, and use optional
  chaining / nil-coalescing over force-unwraps.
- **Strict types.** Avoid `Any`; prefer enums over stringly-typed values.
- **SwiftUI patterns.** State lives in `AppStore` (an `@Observable @MainActor` class) injected via
  `@Environment`. Views are pure expressions of state — no view models.
- **No new dependencies.** The transport, YAML parser, and Docker-API client/server are
  intentionally hand-rolled. Keep it that way unless there's a strong reason.

## Before opening a pull request

1. `scripts/build.sh` succeeds.
2. `scripts/test.sh` passes.
3. New behavior has a test where practical.
4. Commits are focused, with `type: description` messages (`feat:` / `fix:` / `refactor:` /
   `docs:` / `test:`).

## Reporting issues

Open a GitHub issue with steps to reproduce, what you expected, what happened, and your macOS and
Dory versions.

By contributing you agree that your contributions are licensed under the project's
[GPL-3.0](LICENSE) license.
