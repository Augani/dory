# Releasing Dory

`scripts/dory-release.sh` is the only operator-facing release command. Do not manually dispatch
release workflows or call the build, qualification, catalog, Pages, or Homebrew implementation
scripts. Keeping those pieces independently testable is useful; making a release operator
coordinate them is not.

## Actions

| Command | One responsibility | Public mutation |
|---|---|---|
| `scripts/dory-release.sh check VERSION` | Prove clean exact `main`, version/build identity, workflow contract, and release absence | No |
| `scripts/dory-release.sh candidate VERSION` | Build, sign, notarize, staple, verify, and download one private modular candidate | No |
| `scripts/dory-release.sh status [RUN_ID]` | Show the current candidate/publication state | No |
| `scripts/dory-release.sh publish VERSION` | Run qualification-gated GitHub, Pages/appcast/catalog, and Homebrew publication and verify the live result | Yes |

Candidate staging waits by default and downloads the exact artifact beneath
`release-build/candidates/`. Use `--no-wait` only when another operator will monitor the printed run
URL. A candidate never creates a tag, GitHub Release, appcast, Pages catalog, or Homebrew update.

Public publication also waits by default. It cannot bypass physical qualification or publish a
candidate built from a different commit. If a code change lands after candidate staging, stage and
qualify a new candidate from the new exact `main` commit.

## Internal boundaries

- `.github/workflows/release-candidate.yml` produces private immutable candidate bytes.
- `.github/workflows/release.yml` owns qualification-gated public mutation.
- `scripts/release.sh` is the internal macOS asset builder used by those workflows.
- `scripts/qualify-release-candidate.sh` and the evidence verifiers implement the physical gate.
- `scripts/publish-release.sh` remains only as a compatibility shim for older automation.

These are implementation details. New release procedures and documentation should call only
`scripts/dory-release.sh`.
