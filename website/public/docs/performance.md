# Dory performance evidence

Dory does not publish “faster than” screenshots. A comparative claim is qualified only when the
matching GitHub Release contains `Dory-<version>-performance-evidence.zip` and that asset identifies
the same source commit, notarized app, release manifest, SBOM tree, helpers, kernel, rootfs, guest
agent, components, host, engine settings, immutable images, and raw samples.

The current v0.4 result remains **unqualified until that physical campaign runs**. Missing evidence
is visible; it is never converted into a marketing win.

## Required campaign

The dedicated clean Apple-silicon benchmark account runs:

1. isolated matched and fresh-default Dory, OrbStack, and Colima campaigns, one installed engine at
   a time;
2. at least nine position-balanced matched rounds for npm, pnpm, Rails/Bundler, Composer, BuildKit,
   host edits/watchers, Compose readiness, lifecycle, cold start/wake, registry traffic, and
   controlled external DNS/TCP/TLS/fixed-byte HTTPS;
3. the exact candidate's eight-hour resource/file/API endurance and greater-than-24-hour unchanged
   TCP-connection evidence, published separately as `Dory-<version>-reliability-evidence.zip`.

Correctness failure invalidates a timing. Publication fails on a mutable image, unequal
architecture/CPU, more than 5% guest-memory spread, wrong RootFS layers, a silent skip, thermal or
power confound, missing raw sample, linear unbounded resource growth, or incomplete cleanup.

Every table keeps raw samples and reports distributions. Median within 10% with overlapping
distributions is parity, not a win. A win requires at least nine same-session valid samples, more
than 10% median improvement, and non-overlapping bootstrap 95% confidence intervals. Helper RSS,
one `vm_stat` delta, container-to-container throughput, and synthetic file storms cannot stand in
for full product footprint, external networking, or real framework/package workflows.

Use the matching [GitHub Release](https://github.com/Augani/dory/releases/latest) for the stable raw
performance and reliability assets, reproducibility metadata, and generated summaries. Temporary
Actions artifacts are not the publication record.
