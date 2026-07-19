# Dory 0.3.2 — social copy

## X

Dory 0.3.2 is here 🐟

Run Linux GUI apps beside containers on Apple Silicon. ~112 MB of duplicate Core payload: gone. Add signed components only when needed.

Preview agent VMs: no host files by default, network none, rollback + auto-delete.

https://augani.github.io/dory/

## LinkedIn

Dory 0.3.2 is out—and this release changes the shape of the product.

Start with one smaller Docker Core. By reusing its signed engine kernel and rootfs for the macOS 14 fallback, we removed about 112 MB of duplicate compatibility payload from the installed Core app.

Then build the workspace you need. Kubernetes, headless Linux Machines, the Linux Desktop Runtime, Debian, Ubuntu, and Kali are signed optional components. Install, verify, update, or remove them independently; removing a component preserves workload data on the selected `.dorydrive`.

Dory also gives you full graphical Linux environments beside your containers: Retina-sharp Xfce desktops, persistent disks, scoped Mac folders, and snapshots—ready for running and testing Linux GUI applications.

For agent-heavy workflows, the Preview sandbox runs each command in a dedicated Linux VM. No host files are visible by default. Mounts are explicit and can be read-only or read-write. Choose enforced `network none`, roll back the environment, use TTL cleanup, or let the temporary VM delete itself by default.

One important boundary: an explicitly mounted read-write folder remains writable by the sandbox. The protection comes from a default-deny host-file boundary and controls you can see and choose.

0.3.2 also adds exact and wildcard local domains through Dory’s built-in HTTP and trusted HTTPS proxies.

Build the world. Contain the chaos.

Dory is open source and built for Apple Silicon Macs.

https://augani.github.io/dory/

#Linux #AIAgents #OpenSource

## Suggested video alt text

A 65-second landscape animation on a bright white engineering canvas. Dory’s fish logo assembles, becomes a smaller Docker Core, attracts optional Linux components, opens a graphical Linux desktop, contains an AI agent inside a disposable sandbox VM, preserves workload data as components leave, routes local domains through trusted HTTPS, and reassembles into the Dory logo.

## Posting asset

Use `exports/Dory-0.3.2-Directors-Cut-1080p-60fps.mp4` for both social posts. Keep the 4K file as the archive/master. A timed English caption sidecar is included at `exports/Dory-0.3.2-Directors-Cut-en.srt`.
