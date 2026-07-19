# Dory — Bring the Work: Provenance and Publication Record

Status: production-ready export record. This document describes the creative, repository basis for its claims, final media checks, and publication handoff. Posting remains a separate release decision.

## Concept and scope

- **Single product aspect:** moving an existing local Docker world into Dory.
- **Developer frustration:** changing runtimes can feel like rebuilding images, volume data, networks, ports, Compose metadata, and container state by hand.
- **Creative idea:** **Bring the work. Leave the lock behind.** A persistent local-world capsule is discovered, preflighted, copied, verified, and committed to Dory while the source remains visibly anchored.
- **Claim posture:** proof-led and specific. The ad demonstrates Dory's migration contract; it does not promise universal portability, zero downtime, a one-click transfer, or a lossless copy of everything.
- **Source storyboard and narration:** `creative/dory-migration-ad/SCRIPT.md`.

## Claim ledger

Line references identify the current repository text used during production. Re-check them against the release being advertised before publication.

| Ad claim or visual | Repository basis | Required boundary |
| --- | --- | --- |
| Dory discovers Docker Desktop, OrbStack, Colima, and other compatible sources. | `README.md:315-319`; `website/src/App.tsx:876-885`; source selection and detection UI in `Dory/Features/Settings/SettingsView.swift:110-139`. | Detection applies to running Docker-compatible local engines/sockets that Dory can read. The named products are factual text labels, not logos or endorsements. The list in the ad is deliberately non-exhaustive. |
| Images, volume data, networks/IPAM, ports/Compose labels, and container state can move. | The preservation contract is enumerated in `README.md:321-329` and `website/src/App.tsx:322-330`; the app qualifies preservation by what the source exposes in `Dory/Features/Settings/SettingsView.swift:229-234`. | Say **can preserve**, or name the supported object categories. Do not say "everything," "lossless," or imply that every source workload is portable. Bind mounts remain references to host paths rather than copied data (`README.md:331-334`). |
| Dory reads first, then checks capacity and collisions before writing. | `README.md:317-319` and `README.md:331-332`; Discover and Preflight copy in `website/src/App.tsx:887-897`; the live preflight presents inventory, capacity, warnings, and target conflicts in `Dory/Features/Settings/SettingsView.swift:206-229`. | Preflight can warn or block. It must not be portrayed as always passing. The UI explicitly distinguishes read-only preflight from starting the import (`Dory/Features/Settings/SettingsView.swift:214-217`). |
| The import is transactional and Dory verifies the import. | Transactional migration is stated in `README.md:49-56`; the campaign flow is "Import and verify" with transactional copy and recovery state in `website/src/App.tsx:887-898`; the repository tells users to retain the old runtime through post-import checks in `README.md:336`. | "Import verified" means Dory's import/verification flow, not a guarantee that an arbitrary application behaves identically. Keep the old runtime until preflight and post-import validation pass. |
| Dory never deletes the source. | `README.md:331-336`; source-volume copy and non-deletion language in `Dory/Features/Settings/SettingsView.swift:231-235`. | Use the exact non-deletion claim. Do not broaden it to "the source is untouched during every phase." Source volume mounts are read-only, but the operational contract still requires validation and can require workload coordination. |
| Live data, portability, collisions, and fixed ports may require intervention. | Blocking and warning conditions are implemented in `Dory/Runtime/MigrationAssistant.swift:159-202`; matching user-facing blocked states appear in `Dory/Models/AppStore.swift:4338-4357`. | Running volume-backed or writable-layer workloads may need to stop or pause for a consistent import. Same-name target objects or non-portable contracts can block before writes. Containers with fixed host ports can arrive stopped until the source releases those ports. |
| Built for Apple Silicon, macOS 14+, and open source. | Native Apple Silicon positioning and GPL-3.0 status in `README.md:39-47`; platform requirements in `README.md:156-160`. | Keep the requirement phrasing precise: Apple Silicon Mac and macOS 14 Sonoma or later. Do not imply Intel support. |

## Voice and audio provenance

- **Narrator:** Kokoro voice `bm_george`, British English (`en-gb`), speed `1.02`.
- **Reason for selection:** a different voice identity from the `af_sky` voice documented for Sendara and earlier Dory films, so the campaigns do not sound interchangeable.
- **Generation source:** `creative/dory-migration-ad/scripts/generate_audio.py` declares the model integration, voice, language, speed, cue placement, and deterministic sound design.
- **Cue source:** `creative/dory-migration-ad/narration-cues.json`.
- **Measured cue record:** `creative/dory-migration-ad/audio-cue-report.json`.
- **Narration assets:** six cue WAV files plus `assets/narration-master.wav`. Music and sound effects are separate stems in `assets/music-bed.wav` and `assets/sfx-master.wav` for mix control.
- **Subtitle sidecar:** `exports/Dory-Bring-the-Work-en.srt` uses the measured start and end of each generated narration cue. Burned-caption phrase timing is recorded in `exports/CAPTION_TIMING.md` and implemented with deterministic end-time kills.

## Light visual identity

The authoritative identity is `creative/dory-migration-ad/DESIGN.md`.

- Warm-white canvas `#F6F9FE` with white product surfaces `#FFFFFF`.
- Primary ink `#071525`, structural navy `#0D2A4D`, Dory action blue `#147FE8`, exact logo blue `#3D7BF4`, amber current `#FFAD1F`, and verified green `#20B783`.
- Manrope is the primary display/explanatory family; system monospace is reserved for runtimes, object names, and proof states.
- The exact supplied Dory mark is `assets/dory-logo.svg` and must not be recolored, reshaped, or approximated.
- Explicit exclusions: dark canvas, purple gradient, glassmorphism, neon/cyberpunk styling, generic particles, competitor logos, and tiny literal app screenshots.

## Media and publication plan

| Deliverable | Planned specification | Status |
| --- | --- | --- |
| High-refresh archive | 3840×2160, 16:9, native 60 fps, H.264 High with AAC-LC audio | Complete: 1,812 frames, 30.208 seconds, 33,608,657 bytes |
| LinkedIn/high-refresh master | 1920×1080, 16:9, native 60 fps, H.264 High with AAC-LC audio | Complete: 1,812 frames, 30.208 seconds, 8,952,592 bytes |
| Compatibility archive | 3840×2160, 16:9, 30 fps, H.264 High with AAC-LC audio | Complete: 30.208 seconds, 29,302,788 bytes |
| X-safe master | 1920×1080, 16:9, 30 fps, H.264 High with AAC-LC audio | Complete: 30.208 seconds, 7,993,630 bytes |
| Burned captions | English, one phrase group at a time, inside the lower safe zone | Complete; deterministic visibility and transition frames checked |
| Subtitle sidecar | UTF-8 SRT, six cue-level entries | Complete; final cue ends at 29.893 seconds |
| Social copy and alt text | Platform copy and descriptive alt text from `creative/dory-migration-ad/SOCIAL_COPY.md` | Complete; X copy is 270 characters |

Important text should remain inside the 3440×1800 4K safe area defined in `DESIGN.md`. Preview the social encode both muted and with audio to check silent-viewing readability as well as the final mix.

## Final export QA

- [x] HyperFrames lint: 0 errors; one non-blocking maintainability warning for the single-file composition length.
- [x] HyperFrames runtime: 0 errors and 0 warnings.
- [x] HyperFrames layout: 0 issues across 9 sampled frames.
- [x] HyperFrames motion: 0 errors and 0 warnings.
- [x] Contrast: 76/76 text checks pass WCAG AA.
- [x] Frame-accurate hero, transition, caption, and final-hold review completed; no blank or black frames detected.
- [x] Burned captions use single-group visibility with deterministic hard kills; cue gaps remain empty.
- [x] SRT timing fits each delivery master; the final subtitle ends 0.315 seconds before the 30.208-second file end.
- [x] Audio encode fully decodes as stereo AAC-LC at 48 kHz; source master is stereo 48 kHz PCM24.
- [x] Both 30 fps and 60 fps social masters measure -13.97 LUFS, -0.98 dBTP, 1.7 LU LRA; no clipping observed.
- [x] All four MP4 deliveries fully decode with no media errors.
- [x] The native 60 fps render contains exactly 1,812 frames; four adjacent frames sampled during active scan motion produced four unique frame hashes.
- [x] Final resolution, frame rate, duration, H.264 profile, pixel format, and AAC settings verified with `ffprobe`.
- [x] Muted-autoplay readability reviewed through the social-resolution contact sheet and 76/76 contrast pass.
- [x] Final claims reviewed against the repository sources listed above.
- [x] Accessibility alt text reviewed for source accuracy and broader Dory positioning.
- [ ] Recommended publication step: watch the social master once at full speed on speakers and preview it inside the current X and LinkedIn post composers.

## Release record

- Primary high-refresh archive: `Dory-Bring-the-Work-4K-60fps.mp4`
- Primary LinkedIn/high-refresh social master: `Dory-Bring-the-Work-1080p-60fps.mp4`
- X-safe archive: `Dory-Bring-the-Work-4K-30fps.mp4`
- X-safe social master: `Dory-Bring-the-Work-1080p-30fps.mp4`
- Repository revision used during production: `a711b8e74f3a068340108de78c8d9dcad83196e3` plus the uncommitted `creative/dory-migration-ad/` production tree.
- 60 fps archive SHA-256: `2c61da9090c783693db7d7a4843963df0c8a20bd96cab5b5fc08f75e1bb8f4ea`
- 60 fps social SHA-256: `78dd04ffcb2d2604918bcae1310f9519b8c859e6845137b93100b87a945bf11a`
- 30 fps archive SHA-256: `e45e497f8f84ebed8d78fbf407f20d7c68bbef772f305f0f75e5651c9565842a`
- 30 fps social SHA-256: `4a237721dcde10d749e103a28afa54f8a81efb7f3b3a33fce63e164222c75d73`
- Complete media metadata and hashes: `exports/manifest.json`
- Publication date and URLs: **PENDING**
