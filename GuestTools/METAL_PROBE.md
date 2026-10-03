# macOS guest Metal probe

`DoryGuestTools` includes a retained Metal qualification probe for execution
inside a macOS VM launched by Dory. It is deliberately a guest-side probe: a
successful host run, a visible host Metal device, or a successful application
build does not qualify a Mac guest.

## Build and run

Build the `DoryGuestTools` target with the intended signed candidate, install
the resulting app in the macOS guest, and open **Dory Guest Tools**. In the
**Metal qualification probe** panel:

1. Prefer **Run & Send to Dory** while the qualification runner is waiting. The runner supplies
   the challenge over the selected VM's VirtIO socket and retains the raw JSON directly.
   Use the four manual fields only for the audited development fallback.
2. Confirm the challenged marker/checkerboard preview and successful result message.
3. For manual fallback only, enter the challenge fields, copy the raw JSON, and retain it
   unchanged with the corresponding host-side qualification receipt.

The version-2 JSON binds the nonce, visible frame marker, candidate identifier, Dory machine and
operation identity, guest-tools bundle identity,
observed guest OS version/build/resources and Metal device, shader digest,
verified compute output digest, and verified render-pattern digest. The probe rejects malformed identifiers,
unavailable Metal, shader/pipeline failures, incomplete command buffers,
compute mismatches, and a render target that differs from its full nonce-derived
marker/checkerboard pattern. The live preview and offscreen readback consume the same challenge.
The marker's red corner must appear at the preview's top left. An inverted render target or
product-window capture is rejected, even when its nonce and digest are otherwise consistent.
`python3 scripts/test-verify-macos-guest-metal-probe.py` also renders the retained shader on a
macOS host and compares its full BGRA8 digest with the independent oracle. That is a shader
control, not evidence that Metal ran inside the selected guest.

## Candidate bundle inventory

Before staging the guest app, create an inventory of the exact completed bundle:

```sh
python3 scripts/generate-macos-guest-tools-manifest.py \
  --app /path/to/DoryGuestTools.app \
  --candidate-id macos-candidate-123 \
  --source-commit <40-character-lowercase-git-sha> \
  --output guest-tools-manifest.json
```

The generator inventories the bundle and retained probe sources, binds both to
the candidate identifier and source commit, and requires the Dory Developer ID
identity plus hardened runtime. `--allow-unsigned-development` is only for
local development inventories; its output is explicitly marked
`unsigned-development` and is never release eligible.

## Machine-bound VirtIO socket collection

Issue the challenge with the Mac machine bundle's `machineIdentifierSHA256`. The qualification
runner rejects a challenge for any other bundle, installs a one-shot listener on that VM's own
`VZVirtioSocketDevice`, and consumes the nonce after the first connection:

```sh
python3 scripts/verify-macos-guest-metal-probe.py issue \
  --candidate-id macos-candidate-123 \
  --machine-id <machineIdentifierSHA256-from-machine-manifest.json> \
  --operation-id <qualification-operation-id> \
  --nonce <host-issued-nonce> \
  --guest-tools-manifest guest-tools-manifest.json \
  --output metal-probe-challenge.json

swift run --package-path dory-core-swift dory-vzmac-qualification run \
  --machine /path/to/machine.bundle \
  --guest-tools /path/to/staged/guest-tools \
  --metal-probe-challenge metal-probe-challenge.json \
  --metal-probe-result guest-metal-probe.json

# In the guest, open Dory Guest Tools and choose "Run & Send to Dory", then verify:
python3 scripts/verify-macos-guest-metal-probe.py verify \
  --challenge metal-probe-challenge.json \
  --result guest-metal-probe.json \
  --transport-receipt guest-metal-probe.json.transport.json \
  --guest-tools-manifest guest-tools-manifest.json \
  --source-root . \
  --output metal-probe-verification.json
```

The version-3 transport receipt binds the exact result bytes to the candidate, nonce, operation,
selected machine runtime, and host monotonic collection time. When a product-window PNG and its
capture receipt are supplied, the verifier requires that capture to follow collection on the
same host monotonic clock, then strictly decodes the PNG and samples every cell of the current
challenge inside the declared
preview viewport. The sub-result intentionally remains `releaseEligible: false`; the outer
campaign must still establish capture authority, lifecycle transitions, and sustained pacing.

For the product-window run, issue the challenge with the same canonical UUID that will be passed
to the daemon's one-shot start command. The challenge's machine ID must match the selected
bundle's `machineIdentifierSHA256`; both files must have distinct absolute paths in the same
directory, and neither result nor transport receipt may exist before the start. The daemon
revalidates the challenge immediately before spawning the helper, then passes it into the
selected product VM. Automatic startup helper retries are disabled for this one-shot collection,
so a crash cannot silently move the challenge to another process generation. Normal starts do
not open the probe port. A suspended Mac guest can use
the same command to collect a fresh result during a managed restore.

```sh
dorydctl machine start-metal-probe <Dory-machine-name> \
  --operation-id <same-canonical-UUID-used-when-issuing-the-challenge> \
  --challenge /absolute/path/metal-probe-challenge.json \
  --result /absolute/path/guest-metal-probe.json
```

Once the guest app shows the challenged preview in a running **dory-vmm** window, capture it with
the product-window tool. `--guest-preview` is the rectangle occupied by the guest's Metal pattern,
in pixels of the captured PNG, measured from the PNG's top-left corner; it is not the full Mac
window unless the pattern actually fills it. The capture tool selects an on-screen `dory-vmm`
process and window through ScreenCaptureKit, refuses ambiguous windows and existing output files,
requires the product window's challenge-bound title token, and records exact
challenge/result/PNG hashes. Screen Recording permission may be required.

```sh
swift run --package-path dory-core-swift dory-vzmac-window-capture \
  --pid <running-dory-vmm-pid> \
  --challenge /absolute/path/metal-probe-challenge.json \
  --result /absolute/path/guest-metal-probe.json \
  --capture /absolute/path/selected-vzmac-window.png \
  --receipt /absolute/path/selected-vzmac-window.json \
  --guest-preview <x,y,width,height>
```

If that process has more than one eligible window, pass its `--window-number <CGWindowID>` to
select exactly one. The independent verifier above must still accept the nonce-derived pixels;
neither the process check nor a matching file digest alone establishes a successful guest render.
The version-2 capture receipt records the completed snapshot's host monotonic timestamp.
The signed campaign verifier compares it with the selected VMM's lifecycle trace, so a
capture taken before the required transition, while the VM is suspended, while the
window is miniaturized, or while the host is asleep cannot satisfy a stage.
For a product-window run, verify with both the VM-local transport receipt and the capture:

```sh
python3 scripts/verify-macos-guest-metal-probe.py verify \
  --challenge /absolute/path/metal-probe-challenge.json \
  --result /absolute/path/guest-metal-probe.json \
  --transport-receipt /absolute/path/guest-metal-probe.json.transport.json \
  --guest-tools-manifest /absolute/path/guest-tools-manifest.json \
  --source-root . \
  --window-capture /absolute/path/selected-vzmac-window.png \
  --window-capture-receipt /absolute/path/selected-vzmac-window.json \
  --output /absolute/path/metal-probe-verification.json
```

## Audited manual fallback

For early development only, copy the raw JSON and verify it without `--transport-receipt`:

```sh
python3 scripts/verify-macos-guest-metal-probe.py issue \
  --candidate-id macos-candidate-123 \
  --machine-id <Dory-machine-id> \
  --operation-id <qualification-operation-id> \
  --nonce <host-issued-nonce> \
  --guest-tools-manifest guest-tools-manifest.json \
  --output metal-probe-challenge.json

python3 scripts/verify-macos-guest-metal-probe.py verify \
  --challenge metal-probe-challenge.json \
  --result guest-exported-metal-probe.json \
  --guest-tools-manifest guest-tools-manifest.json \
  --source-root . \
  --output metal-probe-verification.json
```

The verifier confirms the exact nonce/candidate/machine/bundle metadata, guest OS
version/build/resources, retained source inventory, command-buffer statuses,
deterministic compute digest, approved shader identity, nonce-derived render digest, and visible
challenge record.
Without a transport receipt it writes only `development-observed` evidence with
`releaseEligible: false`: manual copy does not authenticate the guest, prove the
selected Dory window, or prevent a copied result from another machine. The final
campaign still needs product-bound visible-window, lifecycle, and pacing evidence.

## Signed two-campaign Metal sub-gate

`scripts/verify-macos-vm-performance-bundle.py` replays two independent
VM-local transport and challenged product-window proofs from one signed,
exact-file inventory. The canonical inventory lists `evidence-manifest.json`
and seven proof files per required lifecycle stage under each of
`evidence/campaign-1/` and `evidence/campaign-2/`. The required stages are
cold boot, resize, minimize/restore, sleep/wake, and save/restore. Its detached signature is
`signatures/evidence-bundle.sig`. The manifest binds the exact candidate,
matrix cell, host/installed-guest/installer identities, and independent campaign
launch operations. Every observation has a fresh nonce and capture. The seventh
file is `lifecycle-trace.ndjson`, copied from the selected managed VMM's state
directory (`mac-lifecycle-<operationID>-<VMM PID>.ndjson`). It records the
actual window, host sleep/wake, and VM restore transitions for that launch.
Cold-boot observations must come from a `run` launch; save/restore
observations must come from a `resume` launch.
Issue each stage's challenge **after** the required transition and capture
the selected product window **after** that challenge. Invoke the verifier
with the trusted Ed25519 public key, source root, and
all seven expected candidate/cell digests printed by `--help`.

The result deliberately has `releaseQualified: false`. The verifier replays
the signed trace and rejects a stage label without its preceding transition,
a trace from another VMM process or operation, and a capture predating its
challenge or the required transition. It also rejects captures outside a
running, visible, awake interval. This still does not establish install/restore correctness,
sustained performance, devices, or final catalog publication. A release
receipt must remain unavailable until those outer campaign gates are added
and independently replayed.
