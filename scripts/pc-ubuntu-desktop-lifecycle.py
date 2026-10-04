#!/usr/bin/env python3
"""Installed EFI Ubuntu x86 lifecycle through the isolated signed candidate's real APIs.

Cold/offline reopen, guest reboot, stock APT upgrades and cold snapshot byte recovery share
the ARM reducer, with exact PC ISA/backend/candidate checks. This does not prove installation,
GPU semantic pixels, injected storage failure or public release qualification.
"""
import importlib.util
from pathlib import Path
import sys

SPEC = importlib.util.spec_from_file_location("dory_pc_desktop_lifecycle", Path(__file__).with_name("arm-ubuntu-desktop-lifecycle.py"))
lifecycle = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = lifecycle
SPEC.loader.exec_module(lifecycle)

if __name__ == "__main__":
    sys.exit(lifecycle.main(architecture="x86_64"))
