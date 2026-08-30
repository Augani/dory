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

The macOS 26.5 public SDK has no declaration for camera injection or physical USB passthrough. The
macOS 27.0 public SDK declares AccessoryAccess and `VZUSBPassthroughDeviceConfiguration`, and the
probe compiles its typed constructor. It still has no direct VZ camera-injection declaration. Dory
therefore runtime-gates physical USB to macOS 27 and uses the versioned VirtIO-socket/CoreMediaIO
guest bridge for camera support on the supported macOS guest range.

The exact signed engineering result is recorded in
[`phase-0a-vzmac-device-api-engineering-evidence-2026-08-30.json`](phase-0a-vzmac-device-api-engineering-evidence-2026-08-30.json).
Its exit status is 3 and its release gate is false by design. The Phase 0A stop gate remains open
because configuration construction is not physical runtime qualification. The separate macOS 27
Developer ID receipt is recorded in
[`phase-0a-vzmac-device-api-sdk27-engineering-evidence-2026-08-30.json`](phase-0a-vzmac-device-api-sdk27-engineering-evidence-2026-08-30.json).
The gate closes only after the exact notarized candidates pass physical USB and in-guest camera
qualification on the frozen minimum-host matrix.

The implemented host relay, guest client, Camera Extension bundle, installer lifecycle, and
in-guest qualification executable are recorded separately in
[`phase-0a-vzmac-camera-bridge-engineering-evidence-2026-08-30.json`](phase-0a-vzmac-camera-bridge-engineering-evidence-2026-08-30.json).
