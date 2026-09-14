# macOS guest Metal probe

`DoryGuestTools` includes a retained Metal qualification probe for execution
inside a macOS VM launched by Dory. It is deliberately a guest-side probe: a
successful host run, a visible host Metal device, or a successful application
build does not qualify a Mac guest.

## Build and run

Build the `DoryGuestTools` target with the intended signed candidate, install
the resulting app in the macOS guest, and open **Dory Guest Tools**. In the
**Metal qualification probe** panel:

1. Enter the host-issued nonce and the exact staged candidate identifier.
2. Run the probe while the Dory VM window is visible.
3. Confirm the checkerboard preview and successful result message.
4. Copy the raw JSON and retain it unchanged with the corresponding host-side
   qualification receipt.

The JSON binds the nonce, candidate identifier, guest-tools bundle identity,
observed guest Metal device, shader digest, verified compute output digest, and
verified render-pattern digest. The probe rejects malformed identifiers,
unavailable Metal, shader/pipeline failures, incomplete command buffers,
compute mismatches, and a render target that differs from its full expected
checkerboard pattern.

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

The current export path is explicit manual collection for development. It does
not claim authenticated guest-to-host transport or release qualification. Audit
a manually copied result against a host-issued challenge, the staged-bundle
manifest, and the retained probe sources with:

```sh
python3 scripts/verify-macos-guest-metal-probe.py issue \
  --candidate-id macos-candidate-123 \
  --machine-id <Dory-machine-id> \
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

The verifier confirms the exact nonce/candidate/bundle metadata, the retained
source inventory, command-buffer statuses, and deterministic compute digest.
It writes only `development-observed` evidence with `releaseEligible: false`:
manual copy does not authenticate the guest, prove the selected Dory window,
or prevent a copied result from another machine. The issuing workflow is
responsible for nonce uniqueness and replay control. The final campaign still
needs authenticated candidate-bound result transport plus product-bound visible
window, lifecycle, and pacing evidence.
