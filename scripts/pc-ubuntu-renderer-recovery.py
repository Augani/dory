#!/usr/bin/env python3
"""Recover an installed x86_64 Ubuntu desktop's VirGL2/Venus worker without rebooting it.

Uses the common reviewed renderer-survival/pixel reducer, with an explicit PC-only endpoint,
signed renderer-only fault policy, native x86 probe receipt and ISA-bound replay. The default
is abrupt worker self-kill; it never accepts an external PID or grants public qualification.
"""
import importlib.util
from pathlib import Path
import sys

SOURCE = Path(__file__).with_name("arm-ubuntu-renderer-recovery.py")
SPEC = importlib.util.spec_from_file_location("dory_pc_renderer_recovery", SOURCE)
recovery = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = recovery
SPEC.loader.exec_module(recovery)

if __name__ == "__main__":
    sys.exit(recovery.main(architecture="x86_64"))
