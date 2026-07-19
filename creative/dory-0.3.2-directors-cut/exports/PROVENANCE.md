# Dory 0.3.2 Director’s Cut — provenance

Created on 2026-07-17 as a 65-second, 16:9 launch film for X and LinkedIn.

## Creative construction

- White engineering-canvas visual system with Manrope and JetBrains Mono.
- Exact Dory mark from `website/public/logo.svg`; it appears only in the opening and closing scenes.
- Exact Debian, Ubuntu, and Kali artwork from the app asset catalog.
- Nine deterministic scenes choreographed in one HyperFrames/GSAP timeline.
- Original programmatic music bed and interaction effects generated locally by `scripts/generate_audio.py`.
- Fourteen locally synthesized narration clips, paced at 0.96× and placed as independent cues so each line starts with its corresponding visual proof.

## Product-claim sources and guardrails

- Smaller Core and about 112 MB of removed duplicate compatibility payload: `CHANGELOG.md`.
- Signed, independently removable optional components: `CHANGELOG.md` and `README.md`.
- Component removal preserves workload data on the selected `.dorydrive`: `README.md` and `COMPATIBILITY.md`.
- Graphical Debian, Ubuntu, and Kali Xfce environments with Retina 2× display, persistent disks, scoped sharing, and snapshots: `README.md` and `COMPATIBILITY.md`.
- Agent sandbox is explicitly labeled Preview. It uses a dedicated VM, shares no host files by default, supports explicit read-only/read-write mounts, rollback, TTL cleanup, and default VM deletion: `README.md` and `website/public/agent-guide.json`.
- Only `network none` is presented as isolated/enforced. The film does not claim that explicit read-write mounts are protected from the sandbox.
- Exact and leftmost-wildcard local domains through built-in HTTP and trusted HTTPS proxies: `CHANGELOG.md`.
- “Run and test graphical applications” describes the environment capability; the film does not claim a built-in automated GUI-testing framework.

## Finishing and QA

- Native render: 3840×2160, 60 fps, 3,900 frames, H.264 High, BT.709, yuv420p.
- Social derivative: Lanczos downsample to 1920×1080 at 60 fps, H.264 High, CRF 16.
- Audio: AAC-LC stereo, 48 kHz, approximately 246 kb/s.
- Two-pass EBU R128 normalization: −14.1 LUFS integrated, −1.0 dBTP, 4.0 LU loudness range.
- HyperFrames preflight: 0 runtime errors, 0 layout issues across nine samples, 0 motion errors, and 72/72 WCAG AA contrast checks passed.
- Transition audit: all eight transitions passed; no black frames, tears, or accidental clipping.
- Final source-frame inspection covered the opening, every hero scene, the sandbox action, the deletion handoff, and the resolved logo outro.

See `manifest.json` for exact media metadata, file sizes, and SHA-256 digests.
