# macOS Guest Tools package lifecycle

The signed, notarized `DoryGuestTools-*.pkg` is the initial installation route in
an ordinary Mac guest. Open the package from Dory's read-only Guest Tools share,
or install it with macOS Installer. It installs the signed app, an Aqua login
agent, and `/Library/Application Support/Dory/GuestTools/dory-guest-tools-maintenance`.
Log out and back in after the first install to start the login agent.

Subsequent lifecycle commands run **inside the guest** with `sudo`. Keep each
package beside its `.pkg.json` manifest; the helper checks the exact package
digest, Developer ID Installer team, stapled ticket, Gatekeeper decision, and
expected payload before invoking macOS Installer.

```sh
sudo '/Library/Application Support/Dory/GuestTools/dory-guest-tools-maintenance' \
  update /Volumes/DoryGuestTools/NEW.pkg /Volumes/DoryGuestTools/NEW.pkg.json \
  /path/to/retained/PREVIOUS.pkg /path/to/retained/PREVIOUS.pkg.json
```

`update` attempts to reinstall the previous verified package if the new
installation or installed-app verification fails. Keep both packages until the
new tools have connected and passed a guest login. To select an older verified
package deliberately, use `rollback OLD.pkg OLD.pkg.json CURRENT.pkg CURRENT.pkg.json`;
it uses the same recovery path. The `install` subcommand is
available only when no Guest Tools package receipt exists.
These commands cannot promise crash-atomicity across a guest power loss; normal
VM backup and package retention still matter.

For removal, deactivate the camera system extension in Dory Guest Tools first
and log out of sessions running the app. Then run:

```sh
sudo '/Library/Application Support/Dory/GuestTools/dory-guest-tools-maintenance' uninstall
```

Uninstall refuses an unrecognized/tampered app or login agent. It moves the
exact package-owned app, agent, and helper into a root-only recovery directory
under `/var/db/DoryGuestTools/`, then forgets the package receipt. The command
prints the recovery path; no VM disk or guest data is removed. The command
restores those files if forgetting the receipt fails. A failed update or
rollback should be treated as a guest-maintenance error, not as evidence that
the host VM is unhealthy.
