# Dory vs. Docker Desktop vs. OrbStack

A factual comparison for teams choosing a container runtime on macOS (Apple silicon).
Every claim below links to a primary source — vendor licensing pages, official docs, or
public tracker issues — so you can verify it yourself. Where a number is Dory's own internal
measurement, it is labeled as such and is not presented as independently verified.

## The short version

Two things cost you nothing to adopt and are hard to reverse:

1. **Dory is permanently free and open source (GPL-3.0).** There is no paid tier, no seat count,
   and no account to create. That removes both a per-seat license line item *and* the ongoing
   burden of tracking who is entitled to a commercial seat when your headcount or revenue crosses
   a vendor's threshold.
2. **Open source is the one commitment a vendor can't quietly revoke.** Pricing and free-tier terms
   for closed-source tools have been changed before, and some users have publicly said they no
   longer trust closed-source freemium runtimes for exactly that reason (see the citations below).
   With a GPL-3.0 codebase, the terms you build on are the terms you keep.

Neither of these depends on any performance benchmark. They are true on day one.

## Comparison table

| | **Dory** | **Docker Desktop** | **OrbStack** |
|---|---|---|---|
| **License / cost** | Free. No paid tier, no seat count. | Free for individuals, education, and small business; a paid subscription is required for organizations with **250+ employees or US$10M+ in annual revenue**. [[1]](#1) | Free for personal use; a paid subscription (**US$8/user/month**, billed annually) is required for **all commercial use**. [[2]](#2) |
| **Open source** | Yes — GPL-3.0, full source on GitHub. [[3]](#3) | No (proprietary; the underlying Docker Engine is open, the Desktop app is not). | No (proprietary). An open-source request has been open since 2023. [[4]](#4) |
| **Account required** | No account, no sign-in. | Docker account required to accept subscription terms for paid use. [[1]](#1) | Not required for personal use. |
| **2024 price history (context)** | n/a (free). | Subscription prices were raised in 2024 (Pro US$5→US$9/mo, Team US$9→US$15/mo per seat), and paid terms were later extended to cover university faculty and staff. [[5]](#5) | — |
| **Idle memory posture (macOS)** | Runs all containers in **one shared VM** so idle memory stays flat as you add containers. Dory measures roughly **4.7× less idle memory than the one-VM-per-container model** for two containers (~122 MB vs ~574 MB). *Measured by Dory; a reproducible public benchmark is forthcoming — treat this as Dory's own figure, not an independent result.* | Users have reported a persistent idle footprint in the **~3–4 GB** range, tied to a fixed VM memory block that macOS does not reclaim, plus elevated idle CPU/battery reports. [[6]](#6) [[7]](#7) [[8]](#8) | Also uses a single shared VM (one of the reasons its footprint is low). A head-to-head Dory-vs-OrbStack memory comparison is pending publication of Dory's benchmark. |
| **Kubernetes version selection** | Runs **k3s**, which publishes multiple release channels, so more than one Kubernetes minor version can be selected. | Bundled Kubernetes tracks the Docker Desktop release. | Ships **one** auto-bumped Kubernetes version; the docs point users who need a specific version to kind/k3d. A request for selectable versions has been open since Nov 2023. [[9]](#9) |
| **Platform** | macOS 26+ on Apple silicon for the standalone shared-VM engine; a Docker-API proxy mode works on older macOS/Intel against an existing engine. [[3]](#3) | macOS (Intel + Apple silicon), Windows, Linux. | macOS (Apple silicon; Intel support is limited). |

## Notes on what this table does and doesn't claim

- The idle-memory row deliberately uses the **corroborated ~3–4 GB** Docker Desktop baseline and
  labels Dory's ~4.7× figure as an internal measurement. It does **not** claim any specific
  multiple against OrbStack — that comparison isn't published yet.
- This is not a claim that Docker Desktop or OrbStack behave badly. They are capable tools; the
  table is about **licensing model, openness, and design posture**, which are the factors that
  matter when a team is deciding what it can standardize on without a future cost or compliance
  surprise.

## Why the licensing angle matters even if you're under the thresholds today

Docker Desktop's paid requirement keys off **company size and revenue**, not usage. [[1]](#1) A
team that adopts it while small inherits a compliance task the moment it grows past 250 employees
or US$10M in revenue: someone has to notice the threshold, buy seats, and track entitlement.
OrbStack's paid requirement keys off **commercial use** at US$8/user/month. [[2]](#2) Dory removes
the line item and the tracking entirely — there is nothing to count.

## Sources

<a id="1"></a>[1] Docker subscription / pricing — free tier limited to individuals, education, and
small businesses (fewer than 250 employees **and** under US$10M in annual revenue); larger
organizations require a paid subscription.
- https://www.docker.com/pricing/
- https://docs.docker.com/subscription/desktop-license/

<a id="2"></a>[2] OrbStack pricing — free for personal use, paid subscription required for
commercial use (US$8/user/month billed annually).
- https://orbstack.dev/pricing

<a id="3"></a>[3] Dory source and license (GPL-3.0), backends, and platform requirements.
- https://github.com/Augani/dory
- https://github.com/Augani/dory/blob/main/LICENSE

<a id="4"></a>[4] OrbStack open-source request (open since 2023).
- https://github.com/orbstack/orbstack/issues/359

<a id="5"></a>[5] Docker 2024 subscription price increase and later extension of paid terms to
university faculty/staff.
- https://www.docker.com/blog/november-2024-updated-plans-announcement/

<a id="6"></a>[6] Docker Desktop macOS memory not released to host (fixed VM block).
- https://github.com/docker/for-mac/issues/6186

<a id="7"></a>[7] Docker Desktop macOS high idle CPU report.
- https://github.com/docker/for-mac/issues/5070

<a id="8"></a>[8] Docker Desktop macOS resource-usage report.
- https://github.com/docker/for-mac/issues/6655

<a id="9"></a>[9] OrbStack Kubernetes version selection request (open since Nov 2023); OrbStack
ships a single auto-updated Kubernetes version.
- https://github.com/orbstack/orbstack/issues/777
