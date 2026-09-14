# Dory macOS Guest Tools package

The Guest Tools app is built and signed first; the installer is then produced
with the retained package producer. The producer rejects an unsigned app,
indirect inputs/outputs, and an installer package not signed by Dory's
Developer ID Installer team. It writes a package manifest binding the package
bytes to the staged app manifest, candidate ID, and source commit.

```sh
python3 scripts/package-macos-guest-tools.py \
  --app /path/to/DoryGuestTools.app \
  --candidate-id macos-candidate-1 \
  --source-commit "$(git rev-parse HEAD)" \
  --installer-signing-identity 'Developer ID Installer: Dory (864H636QW4)' \
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
