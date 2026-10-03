Dory Guest Tools
================

Open a terminal in this mounted disc and run:

    sudo ./install.sh install

To return to an older tools version, mount that older signed ISO and run:

    sudo ./install.sh rollback

To remove the guest services and package:

    sudo ./install.sh uninstall

The installer enrolls the public key carried by this read-only image, configures the matching
offline apt or dnf repository, verifies its signed metadata and package signatures, and installs
dory-guest-tools. The temporary repository configuration is removed afterward, so ejecting this
disc does not leave a broken package source. System package dependencies must already be installed
or be available from the guest distribution's normal repositories.
