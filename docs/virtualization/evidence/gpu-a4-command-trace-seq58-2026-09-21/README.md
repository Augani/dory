# GPU A4 command trace — seq58 — 2026-09-21

## Result

This is a retained **failed** Ubuntu 24.04.5 ARM64 displayed-pixel attempt. It
does not satisfy A4. The signed candidate reached the stock Linux virtio-gpu
driver and advertised renderer capsets, but the guest did not complete a
renderer-backed presentation before the 300-second readiness deadline.

The host session was locked during the run. The Dory qualification app could
not obtain a visible window or write its window receipt, so this attempt is
useful only as a device-command diagnostic. It must not be cited as displayed-
pixel or physical-window evidence.

## Exact launch identity

- Source commit: `0ca1cd068bcf1e83fd9d501cd7ef8a4773714e4a`
- Campaign ID: `gpu-command-trace-seq58`
- Revocation sequence: `58`
- Machine: `gpu-a4-fw-fence0g-ubuntu-24045`
- Host: `Mac14,10`, macOS build `26B5086k`
- Resolved plan revision: `26`
- Resolved plan SHA-256: `f14cc4c5f3c638e9958de0417281df5ca88f3c8ab1ff931a072455504152df66`
- `dory-hv`: `ea1ba4fc2142e323f010d489f97b0fbcd83d37212856b2cc65d729d34847e2a9`
- Renderer worker: `39b4fb66eab6d53426816bac58aa3eaf8a0a9eeee16bc7d8a20e28ac83e6b9d1`
- Renderer inventory: `2c40fd332777654ab7d073c7b81cfb81d841ced5cb29136bb5faeaf63a7151c4`
- Renderer bootstrap qualification: `f7d2750d4d25010c22b891d9498b8dd9d99d5332d19abe607892ead76200d440`
- Guest Mesa: `mesa:79bc850d884a1307356ff61c017e58901b90c7e2`

The private launch service was stopped after the attempt. The normal daemon
and the user's running software-rendered VM remained alive throughout.

## Observed control commands

The bounded per-command diagnostics recorded these first observations across
firmware initialization and the post-reset Linux driver generation:

| Command | Count logged | Meaning |
|---|---:|---|
| `0x0100` | 2 | `GET_DISPLAY_INFO` |
| `0x0101` | 5 | `RESOURCE_CREATE_2D` |
| `0x0102` | 2 | `RESOURCE_UNREF` |
| `0x0103` | 5 | `SET_SCANOUT` |
| `0x0104` | 6 | `RESOURCE_FLUSH` |
| `0x0105` | 6 | `TRANSFER_TO_HOST_2D` |
| `0x0106` | 5 | `RESOURCE_ATTACH_BACKING` |
| `0x0107` | 1 | `RESOURCE_DETACH_BACKING` |
| `0x0108` | 2 | `GET_CAPSET_INFO` |
| `0x010A` | 3 | `GET_EDID` |
| `0x0203` | 2 | `CTX_DETACH_RESOURCE` |

No `GET_CAPSET`, `CTX_CREATE`, `RESOURCE_CREATE_3D`, `RESOURCE_CREATE_BLOB`,
`MAP_BLOB`, or `SUBMIT_3D` command was observed. The structured renderer trace
remained zero bytes.

The device did complete one guest-requested reset and installed renderer
generation 27 before Linux queried capset information. That narrows the next
live investigation: renderer feature negotiation survives reset, but no guest
3D userspace command reached the renderer before readiness expired.

## Terminal failure

The runner reported:

```text
dory-hv: guest stop reason: guest crash: desktop readiness failed: boot failure: generic Linux guest did not complete a graphics presentation within 300s
dory-hv: desktop failed: boot failure: generic Linux guest did not complete a graphics presentation within 300s
```

## Next valid run

Repeat the same signed campaign with the macOS session unlocked. Require all
of the following before retaining it as A4 evidence:

1. a Dory-owned visible-window receipt;
2. a non-empty structured renderer trace containing a 3D or blob submission;
3. a guest probe that rejects `llvmpipe` and `lavapipe`;
4. a Metal completion ID correlated with the displayed frame.
