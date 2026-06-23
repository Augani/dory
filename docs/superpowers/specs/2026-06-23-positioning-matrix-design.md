# Positioning Matrix — Dory vs OrbStack vs Docker Desktop — Design Spec

**Track:** Positioning / comparison matrix — the marketing artifact of the Docker/K8s parity cycle, shipping first as a quick win. This is the *communication layer* for the other three tracks (Kubernetes workload surface, Docker Engine API correctness, Linux/portable dev machines): when each of those lands a capability, it upgrades one or more rows here.

Today Dory's public positioning is split across three honest-but-scattered surfaces: `COMPATIBILITY.md` (an internal, dense, per-endpoint capability matrix), `README.md` (a feature list), and `docs/index.html` (a landing page leading on memory + free/open-source). There is **no single head-to-head artifact** the team can show a person evaluating Dory against OrbStack or Docker Desktop. The goal of this track is a new public doc — `docs/comparison/dory-vs-orbstack-vs-docker-desktop.md` — that states, dimension by dimension, an honest verdict (**win / tie / partial / lag**) for Dory against both incumbents. Its credibility *is* its value: every row must be defensible against `COMPATIBILITY.md` ground truth, and the rows where Dory currently lags (thin K8s workload surface until track 2 ships; ecosystem/distribution maturity) must be stated plainly, not buried.

This spec designs that doc (dimensions, verdicts, sourcing, maintenance hook). The build step writes the doc itself; this cycle does not.

## Decisions

- **One public Markdown doc**, `docs/comparison/dory-vs-orbstack-vs-docker-desktop.md`, not an HTML page. Markdown renders on GitHub (where the README's "Compatibility" link already points readers), is diffable in PRs alongside `COMPATIBILITY.md`, and is trivially linkable from `docs/index.html` later. No new build tooling.
- **Verdict legend (Dory's column only):** every row gets a one-word verdict for Dory plus a short evidence clause.
  - **win** — Dory beats *both* incumbents on this dimension.
  - **tie** — Dory matches the better incumbent (parity, no clear edge).
  - **partial** — Dory does it, but with a real, named limitation vs the incumbents.
  - **lag** — an incumbent is clearly ahead today; state why and (if true) what closes it.
  The OrbStack and Docker Desktop columns are plain factual cells (what *they* do), not verdicts — Dory is the only thing being graded, which keeps the doc honest rather than a hit piece.
- **Source of truth is `COMPATIBILITY.md`.** Every Dory verdict must trace to a row there (or to README/landing claims that themselves trace to it). The doc carries a one-line header: *"Dory verdicts are sourced from [COMPATIBILITY.md]; incumbent columns reflect publicly documented behavior as of <date>."* No claim about Dory may exceed what `COMPATIBILITY.md` asserts. Where `COMPATIBILITY.md` says 🟡/🛠️/⛔, the doc says **partial** or **lag**, never **win**.
- **Structure:** a short intro (what Dory is, what this table grades, the honesty pledge + sourcing line) → **the matrix** (one row per dimension below) → a **"Where Dory lags today"** call-out section that re-states the lag rows in prose with the path to parity → a **"How we keep this honest"** maintenance-hook footer naming which track upgrades which rows. Lead with the three rows Dory wins on (memory, install size/self-contained, free/open-source + licensing freedom) — those are the switch-drivers.
- **Dimensions and honest Dory verdicts** (≥13, per the brief). Verdicts below are the *designed* values for the build agent to fill in; each is justified against `COMPATIBILITY.md`:

  | # | Dimension | Dory verdict | Justification (ground truth) |
  |---|---|---|---|
  | 1 | Memory footprint (multi-container) | **win** | LEAD. One shared VM; measured 2 containers = ~122 MB vs ~574 MB per-container (~4.7×), gap widens per container. Both incumbents run heavier (DD's Linux VM; OrbStack is lean but Dory's headline is the shared-VM measurement). State the measurement, not a vague "lighter". |
  | 2 | Install size & self-contained | **win** | ~155 MB on disk / ~80 MB zipped, single signed `.app`, macOS 26+ only, no Docker Hub/Homebrew/Docker Desktop needed (engine image pulled on first run). DD is a multi-hundred-MB install. |
  | 3 | Open-source & free | **win** | GPL-3.0, no paid tier, no account, no telemetry. DD requires a paid subscription for large orgs; OrbStack has a paid Pro tier. Dory has neither gate. |
  | 4 | Commercial licensing freedom | **win** | No per-seat/large-org licensing terms (vs DD's commercial license requirement); fully FOSS. Caveat row text: GPL-3.0 copyleft obligations apply to redistribution — state it, it's the honest footnote. |
  | 5 | Docker Engine API parity | **tie** (Docker backend) / **partial** (default shared-VM backend) | Docker backend is a full transparent proxy → near-100% parity, but that backend *proxies an existing engine* (companion, not replacement). The default **shared-VM** backend runs real `dockerd`-in-VM (broad coverage, build/BuildKit/exec/cp/logs/stats/events all verified) — so for the engine that ships by default, parity is **tie** on the verified core with a **partial** caveat on the long tail of create-body flags (the Apple/mock translation layer). Be precise about *which backend*. |
  | 6 | Kubernetes | **partial** | One-click k3s in the shared VM is verified (host `kubectl`, pod deploy, `*.k8s.dory.local` HTTP+HTTPS). But the in-app **workload surface is thin** — pod list + apply, not the rich k8s management OrbStack/DD ship. Honest **partial**; **track 2 upgrades this row** toward tie as the workload UI lands. |
  | 7 | Linux machines / portable dev machines | **tie** | Create/start/stop/delete Ubuntu/Debian/Fedora/Alpine VMs verified via `MachineProvider`; GUI picker. OrbStack's machines are mature; Dory matches the core. Portability/SSH polish is **track 4**'s area — note it as the edge to watch. |
  | 8 | File sharing & performance | **partial** | Bind-mount sharing via virtiofs is verified working (`docker run -v ~/proj:/app` reads/writes live). But file-sharing *performance* under a real dev loop is **not yet benchmarked** (`COMPATIBILITY.md` says so explicitly) — OrbStack's perf is a known strength. **partial**, not **win**, until benchmarked. |
  | 9 | `*.dory.local` domains + local HTTPS | **tie** | `DoryDNS` + `DoryReverseProxy` + `DoryTLSProxy` with `LocalCA`; verified `http`/`https://name.dory.local → 200`. Parity with OrbStack's `*.orb.local`. System-wide install is consent-gated (same one-time admin grant OrbStack needs). |
  | 10 | x86/amd64 emulation | **partial** | qemu binfmt auto-install verified (`--platform linux/amd64 → x86_64`) on the default backend. Rosetta-fast x86 is **delivered via the bundled `dory-vm` helper / `dory vm` CLI** but **not yet on the default shared-VM path / no GUI entry point** — so the *fast* path is gated behind the CLI. OrbStack ships Rosetta x86 in the mainline. Honest **partial** with the path named. |
  | 11 | Volume browser | **tie** | `VolumeBrowser` lists + reads files inside volumes; GUI sheet; export-via-tar + copy-path + breadcrumbs already shipped (recent WS5 work). Matches OrbStack's volume browsing. |
  | 12 | Migration from Docker Desktop / OrbStack | **tie** | `MigrationAssistant` imports images + containers into Dory's shared VM. Matches the incumbent on-ramp story. |
  | 13 | `dory` CLI (vs OrbStack's `orb`) | **tie** | `scripts/dory` wraps engine + machines + kubectl + `dory vm`. Parity with `orb` for the core verbs; not as broad as `orb`'s full surface — keep verdict honest as **tie** on core, note breadth gap in clause. |
  | 14 | Ecosystem & distribution maturity | **lag** | Honest. No notarized auto-updater shipped yet (Sparkle feed/Homebrew Cask are scaffolding); notarization needs an Apple Developer account (external gate); macOS 26+ floor is narrow; community/ecosystem is nascent vs DD's years of mindshare. This is the credibility row — stating a clear **lag** is what makes the wins believable. |
  | 15 | Platform breadth | **lag** | Dory is Apple-silicon macOS 26+ only. DD runs on macOS (Intel + Apple), Windows, Linux; OrbStack is macOS but supports older versions. Dory's floor is the narrowest. Honest **lag**, no path this cycle. |

- **Tone:** factual, measurement-led, no superlatives the matrix can't defend. Where a verdict is **win**, cite the number (~4.7×, ~80 MB zipped, $0). Where it's **lag**, say so in one sentence without hedging.
- **Maintenance hook (the row→track map)** lives in a "How we keep this honest" footer in the doc *and* is restated here so the build agent wires it:
  - **Track 2 (Kubernetes workload surface)** owns/upgrades **row 6 (Kubernetes)** — `partial → tie` as the in-app workload UI lands.
  - **Track 3 (Docker Engine API correctness)** owns/upgrades **row 5 (Engine API parity)** — tightens the shared-VM `partial` (create-body flag long tail) toward `tie`/`win`.
  - **Track 4 (Linux / portable dev machines)** owns/upgrades **row 7 (machines)** and the SSH/portability edge, and contributes to **row 8 (file sharing)** if perf gets benchmarked.
  - **Distribution work (outside this cycle's three tracks)** owns **rows 14–15** — they only move when notarized auto-update / broader platform support ship; flagged so no one silently upgrades them.

## Components

- **`docs/comparison/dory-vs-orbstack-vs-docker-desktop.md`** (new) — the public comparison doc. Sections: intro + honesty/sourcing line; the 3-column matrix (Dory / OrbStack / Docker Desktop) with the 15 dimensions and Dory verdicts above; "Where Dory lags today" prose call-out (rows 6, 8, 10, 14, 15); "How we keep this honest" maintenance-hook footer with the row→track map. Not affiliated-with disclaimer footer (mirrors `docs/index.html`'s "Not affiliated with Docker, Inc. or OrbStack").
- **`docs/comparison/`** (new directory) — holds this doc and any future per-competitor deep-dives.
- **`README.md`** (modify, build step) — add one line under the existing "See COMPATIBILITY.md…" pointer linking to the new comparison doc ("How Dory compares to OrbStack and Docker Desktop → …"). Single-line addition; no restructure.
- **`docs/index.html`** (modify, *optional* build step / can defer) — a "Compare" nav link / footer link to the rendered comparison. Out of scope to design the HTML here; noted so the build agent knows the hook exists.
- **`COMPATIBILITY.md`** — **read-only source of truth**. Not modified by this track. The comparison doc *links back to it* as the citation.

No Swift source files are touched by this track. There is no pure logic to unit-test; verification is editorial (link/claim review), defined under Testing.

## Error handling

This is a documentation artifact — there is no runtime error surface. The "error handling" equivalent is **claim integrity**:

- **No unsourced Dory claim.** Every Dory verdict cell must trace to a `COMPATIBILITY.md` row (or README/landing claim that itself traces there). If a desired claim has no ground-truth backing, it must be downgraded (e.g. **win → partial**) or dropped — never asserted speculatively.
- **No 🟡/🛠️/⛔ → win.** A capability marked gated, partial, or unsupported in `COMPATIBILITY.md` may not be rendered as **win**.
- **Backend precision.** Any Engine-API / x86 / parity claim must name the backend it holds for (Docker proxy vs default shared-VM vs `dory vm` helper). A claim that's true only on the Docker *proxy* backend may not be presented as a property of the default engine.
- **Incumbent fairness.** OrbStack/Docker Desktop cells state publicly documented behavior with an "as of <date>" qualifier; no invented limitations. If unsure of an incumbent capability, state it neutrally rather than guessing in Dory's favor.
- **Dead-link guard.** All internal links (to `COMPATIBILITY.md`, README, releases) and external links (OrbStack/Docker pricing pages cited for the free/licensing rows) must resolve at build time.

## Testing

No `DoryTests/` unit tests — this track ships a doc, not pure logic. Verification is an **honest-claim / link-check review checklist** the build agent runs before merge:

- **Claim trace.** For each of the 15 Dory verdict cells, confirm a backing `COMPATIBILITY.md` line exists and the verdict word (win/tie/partial/lag) does not over-state it. Spot-check the five wins (rows 1–4) carry their numbers (~4.7×, ~80 MB zipped, $0/GPL-3.0).
- **Lag honesty.** Confirm rows 6, 8, 10, 14, 15 read as **partial/lag** and that the "Where Dory lags today" section restates each with the real reason (thin k8s workload surface; un-benchmarked file-share perf; CLI-gated Rosetta; no notarized auto-update; macOS-26-only platform floor).
- **Backend precision.** Confirm every Engine-API / x86 / parity row names the backend it applies to.
- **Maintenance map present.** Confirm the "How we keep this honest" footer maps row 6→track 2, row 5→track 3, rows 7/8→track 4, rows 14–15→distribution — so the next cycle knows exactly what to flip.
- **Link check.** All internal + external links resolve (run a link checker or manual click-through); `README.md` gains exactly one pointer line to the new doc.
- **Build/snapshot:** `scripts/build.sh` must still compile (sanity — no source touched, so this is a no-op gate confirming the doc-only change broke nothing). `scripts/shots.sh` is **not applicable** (no UI surface changes); note it as N/A rather than running it.

## Non-goals (this cycle)

- **Writing the comparison doc itself** — that is the build step; this spec only designs it.
- **Designing the `docs/index.html` "Compare" page / nav integration** — the hook is noted; the HTML/landing redesign is a separate effort.
- **Per-competitor deep-dive pages** (a full "Dory vs OrbStack" long-form, a separate "Dory vs Docker Desktop") — the single 3-way matrix is the high-value artifact; deep-dives can come later in `docs/comparison/`.
- **Benchmarking file-sharing performance** to upgrade row 8 — that's track-4/measurement work; until it exists the row stays **partial**.
- **Auto-generating the matrix from `COMPATIBILITY.md`** — tempting, but the comparison framing (verdicts, incumbent columns) is editorial; hand-authored + checklist-verified is the right call for a marketing artifact this cycle.
- **Localization / translated versions.**
