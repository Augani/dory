# Phase 0A VZMac device API probe

`dory-vzmac-device-probe` is a fail-closed public-SDK inventory for the VZMac natural-device stop
gate. It constructs only documented Virtualization.framework types and never links, casts, or
invokes a runtime-only class.

The probe currently proves that the Xcode 26.6/macOS SDK 26.5 toolchain can construct:

- one `VZMacGraphicsDisplayConfiguration` on `VZMacGraphicsDeviceConfiguration`;
- `VZMacKeyboardConfiguration` and `VZMacTrackpadConfiguration`;
- VirtIO sound input/output streams backed by the host input source and output sink;
- an empty `VZXHCIControllerConfiguration`.

That is configuration/API evidence, not guest runtime qualification. A restore image, Mac platform
identity, auxiliary storage, running guest, TCC behavior, device data flow, detach/reconnect,
sleep/wake, and fault recovery are intentionally not implied.

The same public SDK has no declaration for camera injection or physical USB passthrough. The
macOS 27 runtime exposes class names for `VZUSBPassthroughDevice` and its configuration, but symbol
presence is neither a public header nor lawful API authority. Dory therefore records the runtime
observation for diagnostics and does not instantiate those classes.

The exact signed engineering result is recorded in
[`phase-0a-vzmac-device-api-engineering-evidence-2026-08-30.json`](phase-0a-vzmac-device-api-engineering-evidence-2026-08-30.json).
Its exit status is 3 and its release gate is false by design. The Phase 0A stop gate remains open
until a final public toolchain exposes every required path and the exact release-signed/notarized
candidate passes physical guest qualification on the frozen minimum-host matrix.
