# Dory 0.3.2 launch film — export provenance

The final master was rendered from `../index.html` on 2026-07-17 using HyperFrames 0.7.60 at 1920×1080 and 60 fps with the high-quality profile.

## Creative direction

- White, lightly gridded landscape canvas with Dory blue and amber accents.
- Dory logo appears as a constructed opening mark and a closing bookend only.
- The middle uses an assembly-system analogy: one Docker Core, signed optional components, graphical Linux applications, an isolated agent VM, persistent data, and trusted local domains join into one workspace.
- Motion is deterministic, timeline-driven, and uses composed pushes, scale-throughs, and dissolves rather than cuts.

## Product-claim sources

- Version 0.3.2 release claims and the approximately 112 MB duplicate-payload reduction come from the repository `CHANGELOG.md`.
- Graphical Linux desktop/application, persistent disk, snapshot, scoped mount, and trusted-domain language comes from the repository `README.md`.
- The agent sandbox sequence is based on the repository compatibility and agent documentation: a dedicated Linux VM per run, no host files visible by default, explicit mounts, `--network none`, rollback, TTL cleanup, and deletion by default. The feature is labelled **Preview** in the film. Explicitly mounted writable paths remain writable by the sandbox.

## Audio

The narration script is stored in `../narration.txt`. Speech was generated locally with Kokoro ONNX using the `af_sky` voice at speed 1.18. The rendered master contains stereo AAC-LC audio at 48 kHz; measured peak is −7.9 dBFS.

## Verification

- HyperFrames check: passed.
- Runtime: 0 errors, 0 warnings.
- Layout: 0 issues across 9 sampled scenes.
- Motion: 0 errors, 0 warnings.
- Contrast: 57/57 text checks pass WCAG AA.
- Final codec inspection: H.264 High Profile, yuv420p, BT.709, 1920×1080, 60/1 fps; AAC-LC stereo, 48 kHz.
- Final SHA-256: `292136f3d2176017e5414e425c8ded4401210572021035ff82da7fda1762f17b`.

The remaining lint notices are non-blocking and intentional: repeated use of exact original logo/distribution images, a single tightly choreographed composition file, and non-interactive decorative layers.
