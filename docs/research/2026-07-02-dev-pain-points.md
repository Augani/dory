# Developer Pain-Point Research → Dory Product Opportunities

Date: 2026-07-02. Method: 5-angle web sweep (Reddit/HN/GitHub issues/blogs/docs), 23 sources fetched,
102 claims extracted, top 25 adversarially verified by 3 independent votes each → 15 confirmed,
10 refuted (refuted claims listed at bottom — do NOT use them in copy).

## Ranked opportunities

### 1. Licensing/pricing exodus — ship the message, not code (complexity: NONE)
Docker Desktop is paid at 250+ employees OR $10M+ revenue; 2024 price hikes (Pro $5→$9, Team $9→$15);
late-2024 extension to university faculty/staff; institutional bans (Argonne/DOE, primary-sourced).
OrbStack requires $8/user/mo for ALL commercial use, and its closed-source freemium model is actively
distrusted (orbstack#1831 cites LogMeIn/TeamViewer precedents; #359 open-source request; HN users staying
on Colima over it). **Dory's free+open positioning is the answer to both — and open source is the only
trust commitment that can't be revoked.** Action: landing page + comparison table leading with license
cost AND seat-tracking/compliance burden removal.

### 2. Resource overhead — double down on the shipped moat (complexity: SHIPPED + benchmark)
Docker Desktop idles at a corroborated 3-4GB (fixed VM block macOS can't reclaim); >20% idle CPU and
battery complaints are primary-sourced (docker/for-mac #6186 #5070 #6655). Dory's shared-engine already
measures ~4.7x less idle memory than OrbStack — but that's OUR number. Action: publish a reproducible
public benchmark (methodology + scripts) before using it in marketing. CAVEAT: use the corroborated
3-4GB baseline, never the refuted "6GB for one Postgres" anecdote or "8-13x less than OrbStack".

### 3. Bind-mount filesystem speed — the category-defining unsolved pain (complexity: HIGH)
Structural, affects EVERY tool: VS Code docs officially warn bind mounts through the VM boundary are
slow (`yarn install` guidance); colima#146 measured the penalty; even OrbStack admits 75-95%-of-native
ceiling. Nobody has solved it. If Dory delivers best-in-class host file sharing (or a smart default:
cached sync / copy-on-first-run / virtiofs tuning), it's the single biggest differentiator available.
Prerequisite: benchmark Dory's CURRENT bind-mount performance vs native/DD/OrbStack (unmeasured today).

### 4. K8s version selection — close a 2-year-open incumbent gap (complexity: MEDIUM)
orbstack#777 (open since Nov 2023): users need the last ~3 minors selectable at cluster creation;
OrbStack ships ONE auto-bumped version and officially redirects users to kind/k3d. Dory runs k3s, which
publishes multiple channels — a version picker at cluster creation directly converts OrbStack's k8s
users who are forced onto Kind today.

### 5. Working pod metrics in one-click k8s (complexity: LOW-MEDIUM)
orbstack#2217 (open Nov 2025): `kubectl top pod` fails; HPA/VPA depend on pod metrics (k8s docs).
Verification nuance: the narrow claim (HPA needs metrics-server resource metrics) is 3-0 confirmed; the
broad "OrbStack k8s is unusable/all monitoring broken" was REFUTED — keep claims narrow. Action: bundle
+ verify metrics-server in Dory's k3s; demo HPA working locally.

### 6. Beat Apple's own Container framework on networking — benchmark + messaging (complexity: LOW)
Apple Container's per-container-VM design measures ~5x slower container-to-container networking
(single-source absolute numbers; multi-source qualitative cause). Dory's shared-engine co-locates
containers in one VM and structurally avoids this. Action: measure Dory's C2C throughput and publish
next to Apple Container's — "built on Apple's tech, without Apple's tax".

## Open questions (from the harness)
- Dory's actual bind-mount perf vs native/DD/OrbStack — unmeasured; prerequisite for #3.
- Dory's actual C2C Gbps — architectural argument sound, numbers unverified.
- How big is the k8s-gaps audience relative to cost/memory pains? (narrower but concrete)
- podman/devcontainer-ergonomics/VM-dev-machine angles produced no surviving claims — worth a targeted
  follow-up sweep.

## Refuted claims — never use these
- OrbStack forcefully shuts down containers on failed license check (1-2) / phone-home-as-spyware (0-3)
- "OrbStack k8s unusable for monitoring/HPA" broad form (0-3)
- Docker Desktop "2-4GB vs OrbStack 150-300MB (8-13x)" (0-3); "25-40% of native FS, npm 3-4x slower" (0-3)
- Colima pytest 21.65s-vs-10.29s specific benchmark numbers (0-3)
- Apple Container "builder VMs can't reach internet" conclusion bundle (0-3)
- Podman Desktop "spotty Compose compatibility" as documented fact (0-3)

## Source quality note
Strongest: license docs, GitHub issues, VS Code official docs (primary). Weakest: vendor-adjacent
comparison blogs — every number from those was either corroborated elsewhere or refuted and excluded.
