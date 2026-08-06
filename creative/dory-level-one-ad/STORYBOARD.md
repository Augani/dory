---
format: 1080x1080
duration: 21s
message: "Dory goes beyond containers to deliver a complete local Linux workspace in one native Mac app."
arc: "Feature-Benefit Cascade"
audience: "Apple Silicon Mac developers using containers, Kubernetes, Linux machines, or coding agents"
mode: autonomous
music: custom — deterministic 132 BPM Dory electronic bed, ducked under narration
captions: skipped — every spoken claim is represented by large on-screen copy
---

## Video direction

- **Palette system:** warm-white `cream` is the canvas; navy `ink` carries every headline and outline; Dory blue is the progression/current color; amber is reserved for the playful challenge and button press; green marks verified completion. All colors and type roles come from `frame.md`.
- **Visual grammar:** tactile capsule cards, 2px ink outlines, soft hard-offset shadows, a restrained paper-grain layer, and six to eight purposeful foreground/midground/background roles per frame. Semantic icons are deterministic SVG line drawings; the Dory fish and app icon stay exact and animate only through wrappers.
- **Motion grammar:** every entrance uses an explicit `fromTo` state on one paused GSAP timeline. Long-tail `power3`/`expo` settles are the default; the one playful exception is the physical KEEP GOING press. Reveals follow the spoken cue across the back half of each beat, with velocity-matched internal seams and no mid-frame exits.
- **Rhythm:** Frames 1 and 2 escalate; Frame 3 is the fast clarity turn; Frame 4 deliberately settles into a dead-still final read for the last ~1.2s. Holds may use only one finite low-amplitude jitter on a tiny accent—never scale breathing or camera drift.
- **Framing:** keep all load-bearing copy and UI inside the top ~83% and the central X-feed safe area. Primary type is phone-readable; small labels are chrome only. Each frame has a dominant focal point plus a secondary action or proof point.
- **Never:** no competitor marks, unqualified performance claims, invented product screens, purple cyberpunk gradients, generic particles, tiny dashboard copy, slideshow front-loading, screensaver motion, infinite loops, random values, CSS animations, or a slow back-half pan/push.

## Frame 1 — Level One

- scene: A lone container cube reaches a dead end; the exact Dory fish nose-bops an amber KEEP GOING button and opens the route upward.
- voiceover: "A local runtime that stops at containers? That's level one."
- duration: 4.55s
- poster: 3.85s
- transition_in: crossfade
- status: animated
- src: compositions/frames/01-level-one.html
- type: hook
- persuasion: Category contrast
- beat: curiosity + playful challenge
- blueprint: cta-morph-press — adapt the lone-widget opener into a physical level-up control
- asset_candidates: assets/dory-logo.svg — exact canonical Dory fish
- focal: assets/dory-logo.svg
- roles: dory-logo = cutout; abstract container cube = supporting; KEEP GOING control = supporting; dead-end rail = background
- sfx: weighted thunk, level stamp, tactile lock, portal whoosh

narrativeRole: Turn a familiar container runtime into the starting line, creating a competitive contrast without naming or misrepresenting another product.

keyMessage: Containers are the beginning of Dory's story, not the end.

Adapt: keep the blueprint's physical press as the signature move, replace the cursor with the exact Dory fish, and let the pressed control open the route into Frame 2.

Scene 1 (0.00–0.32s): a large blue container cube lands just left of center on a thick navy route that ends at an amber stop cap; the compact `LOCAL RUNTIME` title pill seats upper-left. Asymmetric 60/40, three depth layers; **spring-pop entrance** (`spring-pop-entrance`) uses a smooth settle and the rail draws toward the stop (`svg-path-draw`).

Scene 2 (0.32–2.60s): `STOPS AT` reveals in the upper third, then the huge outlined `CONTAINERS?` pill locks beneath it exactly as the question is spoken. The cube nudges the stop cap once; the exact Dory fish peeks in from the right edge, aimed at the route. Rule-of-thirds, hero copy fills ~70% width; **per-word staggered reveal** (`dynamic-content-sequencing`) and a finite cap reaction (`press-release-spring`) carry the cue.

Scene 3 (2.60–3.55s): the container card condenses at the same center into a navy `LEVEL 1` badge, with an inverse **zoom-through** seam at peak velocity (`cut-catalog.md`). `THAT'S` lands as small chrome above; `LEVEL ONE.` is the dominant read. Centered hero, high contrast, no camera move.

Scene 4 (3.55–4.55s): an amber `KEEP GOING` capsule rises directly under the badge; the exact Dory fish nose-bops slightly off-center. Fish and button compress in lockstep, release a bounded blue ring, and the route opens upward behind them. **Button press** (`physics-press-reaction`) is the signature; the ring uses `cursor-click-ripple`. Hold the open route for the transition—no manual exit.

## Frame 2 — Keep Going

- scene: One continuous arcade rail activates six tactile miniature worlds: Docker + Compose, Kubernetes, full Linux desktops, persistent servers, migration + recovery, and isolated agent sandboxes.
- voiceover: "Dory starts with Docker and Compose—then keeps going: one-click Kubernetes, full Linux desktops, persistent servers, migration, recovery, and isolated agent sandboxes."
- duration: 9.73s
- poster: 8.15s
- transition_in: zoom-through 0.44s
- status: animated
- src: compositions/frames/02-keep-going.html
- type: feature_showcase
- persuasion: Value stacking + show-don't-tell proof
- beat: escalation + excitement
- blueprint: grid-card-assemble — adapt the self-assembling breadth grid into six sequential level worlds
- asset_candidates:
- focal: deterministic six-level capability board
- roles: capability board = cutout; level rail = supporting; LEVEL UP header = supporting; glow/current path = background
- sfx: core thunk, portal whoosh, six magnetic locks, verification chime

narrativeRole: Prove the promise through breadth, with each capability unlocking as evidence that Dory covers more of the local development stack.

keyMessage: Dory combines the local capabilities developers otherwise manage as separate layers.

Adapt: keep the accumulating grid and sequential slot assembly, but make the six cards connected arcade worlds on one continuous route; no card arrives before its spoken capability. The final sandbox card is the signature completion beat.

Scene 1 (0.00–2.35s): the route from Frame 1 zooms through and lands as a blue current line inside a 2×3 board. `DORY STARTS WITH` seats above one large blue `DOCKER + COMPOSE` capsule; its container-stack line icon draws and a tiny `01` node verifies. The remaining five slots are faint outlined sockets, not readable cards. Asymmetric 70/30 opening into a dense board; **zoom-through** seam, **SVG self-draw** (`svg-path-draw`), then a low-drama slot assemble (`center-outward-expansion`).

Scene 2 (2.35–3.20s): on “then keeps going,” the current races beyond node 01, the headline swaps in place to `KEEP GOING`, and five sockets brighten in sequence without revealing their labels. Full-width strip across the upper third; **in-place token cycle** (`discrete-text-sequence`) plus a one-pass traveling glow (`ambient-glow-bloom`).

Scene 3 (3.20–4.45s): `02  ONE-CLICK KUBERNETES` slides a short path into the upper-right slot; a three-node cluster joins under a drawn crown/cluster line icon. The current snaps to node 02 on the spoken cue. Two-card top row, Docker remains co-resident but de-emphasized; **item stagger-assemble** (`center-outward-expansion`) and **SVG self-draw** (`svg-path-draw`).

Scene 4 (4.45–5.70s): `03  FULL LINUX DESKTOPS` seats middle-left; three tiny monitor tabs labeled `DEBIAN`, `UBUNTU`, `KALI` step on inside the card. The current locks at node 03. 2×3 grid continues accumulating; **discrete state sequence** (`discrete-text-sequence`) and a single magnetic settle.

Scene 5 (5.70–6.82s): `04  PERSISTENT SERVERS` seats middle-right; a server-stack icon gains a green status dot and a short `PERSISTENT` proof rail. The current advances and holds. **Short-path assemble** (`center-outward-expansion`) plus **stat fill** (`stat-bars-and-fills`).

Scene 6 (6.82–8.18s): `05  MIGRATION + RECOVERY` seats lower-left. `MIGRATE` locks first, then `RECOVER` replaces the secondary state exactly on its second spoken cue; a bridge arrow draws between two tiny volumes and ends in a green check. **In-place token cycle** (`discrete-text-sequence`) and **SVG self-draw** (`svg-path-draw`) preserve both cues without adding a seventh world.

Scene 7 (8.18–9.73s): the largest lower-right card arrives last: `06  ISOLATED AGENT SANDBOXES`, with three separated capsule cells and a small shield/check. The current completes the whole route, all six numbered nodes illuminate, and `6 LEVELS. ONE DORY.` lands as the secondary payoff. The board fills ~78% of the upper canvas; **item assemble** (`center-outward-expansion`) and bounded verification bloom (`ambient-glow-bloom`) settle into a still final read—no camera drift.

## Frame 3 — One Native App

- scene: The camera pulls back to reveal all six worlds feeding a social-readable Dory app shell, which magnetically resolves into the exact app icon.
- voiceover: "All in one native Mac app. Free and open source."
- duration: 2.82s
- poster: 2.20s
- transition_in: zoom-through 0.44s
- status: animated
- src: compositions/frames/03-one-native-app.html
- type: benefit_highlight
- persuasion: Friction reduction + value consolidation
- beat: clarity + control
- blueprint: zoom-out-workspace-reveal — adapt the continuous pullback to turn six worlds into one coherent product surface
- asset_candidates: assets/dory-logo.svg — exact canonical Dory fish; assets/dory-app-icon.png — exact Dory app icon
- focal: social-readable Dory app shell
- roles: dory app shell = cutout; dory-app-icon = supporting; dory-logo = supporting; six capability worlds = background
- sfx: bridge whoosh, three soft magnetic contacts, verification chime

narrativeRole: Translate the feature cascade into the user benefit: one coherent native workspace rather than disconnected infrastructure surfaces.

keyMessage: The breadth is delivered through one native, open-source Mac app.

Adapt: keep the blueprint's single outward camera reveal as the signature move, compress it for this fast clarity beat, and use only element-level motion after the camera locks.

Scene 1 (0.00–0.82s): open tight on the completed six-level board from Frame 2; one fast decelerating **zoom-out** (`viewport-change`) reveals that the board lives inside a simplified, faithful Dory native app shell with navy sidebar, warm-white workspace, and the exact fish in the title area. The whole app is authored from frame zero; no second set and no zoom-in.

Scene 2 (0.82–1.72s): camera fully locks. Three visible capability columns magnetically converge into one centered app surface while `ONE NATIVE MAC APP` reveals in two large lines beside it. Asymmetric 60/40 with three depth layers; **cluster→inward assembly** (`center-outward-expansion`, reversed) and **per-word staggered reveal** (`dynamic-content-sequencing`).

Scene 3 (1.72–2.82s): the app surface condenses at the same center into the exact Dory app icon while a green outlined proof capsule wipes on: `FREE + OPEN SOURCE`. The fish remains untouched as a small supporting mark. **Scale-swap** (`scale-swap-transition`) is element-level after the camera lock; the proof uses a left-to-right mask reveal and then holds still for the harness transition.

## Frame 4 — Your Whole Dev Machine

- scene: The exact Dory app icon and fish settle into a warm-white hero card with the final promise, proof line, and URL held long enough to read on a phone.
- voiceover: "Dory. More than containers. Your whole dev machine."
- duration: 3.90s
- poster: 2.40s
- transition_in: blur-crossfade 0.35s
- status: animated
- src: compositions/frames/04-your-whole-dev-machine.html
- type: cta
- persuasion: Value restatement + low-friction invitation
- beat: confidence + motivation
- blueprint: logo-assemble-lockup — adapt the held brand lockup into a social-readable end card
- asset_candidates: assets/dory-logo.svg — exact canonical Dory fish; assets/dory-app-icon.png — exact Dory app icon
- focal: assets/dory-app-icon.png
- roles: dory-app-icon = cutout; dory-logo = supporting; promise copy = supporting; URL capsule = supporting; capsule wallpaper = background
- sfx: logo resolve, tiny completion sparkle

narrativeRole: Convert the breadth proof into a memorable brand promise and a simple action: get Dory.

keyMessage: Dory is more than containers; it is your whole local dev machine.

Adapt: use the blueprint's parts-arrive end-card variant, but preserve both exact brand assets as whole units; the typography and URL assemble around them and the final ~1.2s is dead static.

Scene 1 (0.00–0.72s): the exact app icon arrives from above into a large navy-outlined hero tile while the exact Dory fish glides into its fixed supporting position. `DORY` reveals beside the icon in heavy display type; three cropped capsule shapes seat at the frame edges as quiet wallpaper. Centered lockup with edge anchors and three depth layers; **icon drop-in** and **sequential letter arrival** (`spring-pop-entrance`, `waterfall-entry`) use smooth long-tail settles.

Scene 2 (0.72–1.88s): `MORE THAN CONTAINERS.` wipes on as the first full-width promise line, then `YOUR WHOLE DEV MACHINE.` lands larger beneath it on the spoken cadence. A short Dory-blue underline sweeps left-to-right. Hero copy spans ~76% width in the upper/middle field; **per-word staggered reveal** (`dynamic-content-sequencing`) and **underline sweep** (`stat-bars-and-fills`).

Scene 3 (1.88–2.72s): an amber `GET DORY ↗` capsule and the navy URL `augani.github.io/dory` rise as one metadata row; a small `APPLE SILICON · MACOS 14+` chrome line seats above the row. **Bottom metadata row** (`spring-pop-entrance`) completes the end card without adding another claim.

Scene 4 (2.72–3.90s): everything is locked and dead still for the final phone-readable hold; only the blue underline finishes its last few percent by 2.80s. No breathing, drift, confetti, camera motion, or fade-out.
