# Dory — Bring the Work

A 30.2-second, light-mode HyperFrames ad that uses recoverable runtime migration as the focused story and closes on Dory's broader category: a complete local Linux workspace.

## Production commands

```bash
npm run lint
npm run validate
npm run inspect
npm run render -- --output renders/dory-migration-ad-4k-30fps-raw.mp4 --fps 30 --quality high
zsh scripts/build_exports.sh
npm run render:60 -- --output renders/dory-migration-ad-4k-60fps-raw.mp4
zsh scripts/build_exports_60.sh
```

The 3840×2160 composition is time-based and rendered natively at 60 fps for high-refresh delivery. The existing 30 fps render remains the X-safe version. `scripts/build_exports.sh` builds the 30 fps package; `scripts/build_exports_60.sh` builds the native 60 fps archive and LinkedIn/high-refresh master.

## Deliverables

- `exports/Dory-Bring-the-Work-1080p-60fps.mp4` — LinkedIn/high-refresh social master.
- `exports/Dory-Bring-the-Work-4K-60fps.mp4` — high-refresh archive master.
- `exports/Dory-Bring-the-Work-1080p-30fps.mp4` — X-safe and universal 30 fps master.
- `exports/Dory-Bring-the-Work-4K-30fps.mp4` — compatibility archive.
- `exports/Dory-Bring-the-Work-poster.png` — post thumbnail.
- `exports/Dory-Bring-the-Work-contact-sheet.png` — review sheet.
- `exports/Dory-Bring-the-Work-en.srt` — English captions.
- `exports/Dory-Bring-the-Work-voice-proof.m4a` — narration-only review file.
- `exports/manifest.json` — verified stream metadata, loudness results, file sizes, and SHA-256 checksums.

See `SCRIPT.md`, `DESIGN.md`, `SOCIAL_COPY.md`, and `exports/PROVENANCE.md` for the approved story, visual system, post copy, claim boundaries, and final QA record.
