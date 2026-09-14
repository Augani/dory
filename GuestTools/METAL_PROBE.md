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

The current export path is explicit manual collection for development. It does
not claim authenticated guest-to-host transport or release qualification; the
final campaign still needs a candidate-bound collection and verification path.
