# Dory 0.3.2 Director's Cut — Visual Identity

## Style Prompt

An exuberant, precision-built product film on a warm white engineering canvas. Dory's modules behave like buoyant magnetic objects caught in a controlled current: they arc, bank, snap together, compress, eject, and rebound with physical weight. The recurring blue current line guides the eye through the whole film, while amber pulses mark decisions, connections, and successful handoffs. The result should feel unusually alive for infrastructure software—playful enough to stop a social feed, exact enough to earn a developer's trust. The exact Dory fish is a bookend only; the product story owns every middle frame.

## Colors

- `#F6F9FE` — warm white canvas
- `#071525` — primary ink
- `#0D2A4D` — Linux and sandbox depth
- `#147FE8` — Dory action blue
- `#3D7BF4` — logo blue
- `#FFAD1F` — current pulse and magnetic energy
- `#E7F1FC` — cool surface
- `#52677D` — secondary copy
- `#20B783` — verified and protected state
- `#EF5A4C` — destructive action, used only inside the sandbox

## Typography

- `Manrope` — primary display and explanatory voice; 800 for declarations, 400 for calm support.
- `JetBrains Mono` — commands, release metadata, component names, sizes, policies, and proof states.

## Recurring Motifs

1. **The current** — a blue or amber SVG path that travels through scenes and carries modules forward.
2. **Magnetic cartridges** — rounded components with one distinct connector, varied sizes, and a 2–4% overshoot when they dock.
3. **Protected boundaries** — clear nested frames that make the Mac, disposable VM, and persistent data visually unambiguous.

## Motion Language

- Entrances combine arcs, banked rotation, perspective, and elastic settling; nothing simply fades upward.
- Primary scene changes are fast current-driven pushes or zoom-throughs. Topic changes use a circular iris or a split-panel handoff. The outro returns to a gentle focus pull.
- Staggers stay between 40 and 75 ms. Major objects land first; proof labels chase them.
- One purposeful ambient action per scene: a traveling pulse, slow orbit, scan, caret, or current drift.
- Destructive motion is allowed only inside the sandbox boundary. Rollback visibly reverses the debris before the disposable VM collapses.
- All motion is deterministic and uses transform, opacity, clip-path, and filter only.

## Resolution and Delivery

- Logical design canvas: `1920 × 1080`.
- Archive render: native vector/CSS rasterization at `3840 × 2160`, 60 fps.
- Social master: high-bitrate `1920 × 1080`, 60 fps downsampled from the 4K archive.
- Important copy remains inside a logical `1720 × 900` safe area.

## What NOT to Do

- No generic card-grid presentation, repeated push transition, or everything-at-once entrance.
- No unsupported “first,” “only,” or absolute safety claims.
- No persistent logo, logo watermark, or reinterpretation of the Dory mark.
- No destructive command aimed at a host path; the demo command is visibly confined to generated sandbox data.
- No dense dashboard UI, tiny labels, purple cyberpunk gradients, random motion, or infinite repeats.
- No transition that leaves a blank frame before the next scene is established.
