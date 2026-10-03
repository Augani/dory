# Dory macOS Guest Tools package

The Guest Tools app is built and signed first; the installer is then produced
with the retained package producer. The producer rejects an unsigned app,
indirect inputs/outputs, and an installer package not signed by Dory's
Developer ID Installer team. It submits the package to Apple's notary service,
requires acceptance, staples and validates its ticket, and checks Gatekeeper
before publication. It writes a package manifest binding the final stapled
package bytes to the staged app manifest, candidate ID, source commit and
notarization submission.
The package installs the app in `/Applications` and a per-user Aqua LaunchAgent
in `/Library/LaunchAgents`. It starts the health service without a window at the
next guest login; installing during a live session does not force-start it in
another user's session. A normal app launch keeps the Metal and camera UI.
The VM-local integration protocol is version 2. The current manifest schema is
`dory.macos-guest-tools-manifest@2`; the release verifier accepts this schema
only. The current signed manifest declares
health, guest time, host-initiated HTTP(S) URL opening, and one-shot text reads
from the guest pasteboard, plus the separate Metal probe. It does not declare
file transfer, automatic clipboard synchronization, shutdown, or camera grants.
The Guest menu's “Copy Text from Guest” action is available only when the VM's
clipboard policy is enabled and Guest Tools is connected. It reads at most
16 KiB of text into the host pasteboard. This does not implement selective
direction/format clipboard policy; the existing all-or-nothing SPICE clipboard
policy remains in force. URL opening requires a live Guest Tools connection;
neither action grants host filesystem access.
The older package/manifest format requires a separate verified rollback route;
it is not accepted or claimed as a supported rollback by this producer.

The Desktop release embeds the same notarized `.pkg` and `.pkg.json` in
`Dory.app/Contents/Resources/DoryMacGuestTools` before signing the host app.
When a Mac VM starts, Dory validates the package against that manifest and
exposes this folder as a separate **read-only** “Dory Guest Tools” shared
directory. In the Mac guest, open that shared directory and run the package
installer; then log out and back in to start the per-user health agent. This
share is not a user-selected host folder and does not give the guest write
access to Dory.app. Development builds without the signed package do not
expose the installer share.

```sh
python3 scripts/package-macos-guest-tools.py \
  --app /path/to/DoryGuestTools.app \
  --candidate-id macos-candidate-1 \
  --source-commit "$(git rev-parse HEAD)" \
  --installer-signing-identity 'Developer ID Installer: Dory (864H636QW4)' \
  --notary-profile Dory-Notary \
  --output DoryGuestTools.pkg \
  --manifest-output DoryGuestTools.pkg.json
```

The resulting package is an installable distribution artifact, not a guest
qualification result. Release eligibility still requires the separately signed
candidate-bound campaign and in-guest evidence.

Verify a copied or downloaded package before installing it:

```sh
python3 scripts/verify-macos-guest-tools-package.py \
  --package DoryGuestTools.pkg \
  --manifest DoryGuestTools.pkg.json \
  --candidate-id macos-candidate-1 \
  --source-commit "$(git rev-parse HEAD)"
```

The verifier requires the copied bytes, Developer ID Installer signature,
stapled ticket and Gatekeeper assessment to agree. A signing-only package is
not accepted as a production Guest Tools installer.
