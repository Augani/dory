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
   Use the three manual fields only for the audited development fallback.
2. Confirm the checkerboard preview and successful result message.
3. For manual fallback only, enter the challenge fields, copy the raw JSON, and retain it
   unchanged with the corresponding host-side qualification receipt.

The JSON binds the nonce, candidate identifier, Dory machine identity, guest-tools bundle identity,
observed guest OS version/build/resources and Metal device, shader digest,
verified compute output digest, and verified render-pattern digest. The probe rejects malformed identifiers,
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

## Machine-bound VirtIO socket collection

Issue the challenge with the Mac machine bundle's `machineIdentifierSHA256`. The qualification
runner rejects a challenge for any other bundle, installs a one-shot listener on that VM's own
`VZVirtioSocketDevice`, and consumes the nonce after the first connection:

```sh
python3 scripts/verify-macos-guest-metal-probe.py issue \
  --candidate-id macos-candidate-123 \
  --machine-id <machineIdentifierSHA256-from-machine-manifest.json> \
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

The transport receipt binds the exact result bytes to the candidate, nonce, and selected machine
runtime. It intentionally remains `releaseEligible: false` until the campaign correlates that
result with a capture of the actual Dory VM window and lifecycle/pacing evidence.

## Audited manual fallback

For early development only, copy the raw JSON and verify it without `--transport-receipt`:

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

The verifier confirms the exact nonce/candidate/machine/bundle metadata, guest OS
version/build/resources, retained source inventory, command-buffer statuses,
and deterministic compute digest.
Without a transport receipt it writes only `development-observed` evidence with
`releaseEligible: false`: manual copy does not authenticate the guest, prove the
selected Dory window, or prevent a copied result from another machine. The final
campaign still needs product-bound visible-window, lifecycle, and pacing evidence.
