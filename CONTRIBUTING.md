# Contributing to Dory

Dory is a native macOS app written in Swift and SwiftUI, with supporting Swift and Rust packages.

## Setup

- Apple Silicon Mac running macOS 15 or later for engine development.
- Xcode 26 or later.
- Rust when changing `dory-core` or rebuilding guest components.

```sh
git clone https://github.com/Augani/dory.git
cd dory
scripts/build.sh
scripts/test.sh
```

You can also open `Dory.xcodeproj` in Xcode.

## Project layout

| Path | Purpose |
|---|---|
| `Dory/` | App, UI, Docker integration, Compose, networking, and machines |
| `dory-core-swift/` | Daemon and shared Swift packages |
| `dory-core/` | Rust guest, dataplane, synchronization, and FFI components |
| `Packages/ContainerizationEngine/` | Hypervisor and Virtualization framework engines |
| `guest/` | Linux guest build inputs |
| `DoryTests/` and package `Tests/` | Unit and integration tests |
| `DoryUITests/` | macOS UI tests |

## Guidelines

- Keep changes focused and explain non-obvious invariants.
- Validate inputs and fail safely around user data, networking, and virtualization.
- Prefer concrete types and enums over loosely typed dictionaries.
- Avoid adding dependencies without a clear product benefit.
- Add or update tests when behavior changes.
- Use concise commit messages such as `fix: preserve volume data during migration`.

Before opening a pull request, run:

```sh
scripts/build.sh
scripts/test.sh
```

## Reporting issues

Open a GitHub issue with reproduction steps, expected and actual behavior, macOS version, Mac model,
and Dory version. Attach a redacted support bundle when it helps diagnose the problem.

Contributions are licensed under [GPL-3.0](LICENSE).
