#!/usr/bin/env python3
"""Copy an explicitly scoped ARM campaign keyboard/navigation template to its exact machine."""
import argparse
import importlib.util
import json
from pathlib import Path
import sys

spec = importlib.util.spec_from_file_location("input_navigation", Path(__file__).with_name("arm-ubuntu-installer-navigation.py"))
navigation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(navigation)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--destination", required=True, type=Path)
    parser.add_argument("--machine", required=True)
    parser.add_argument("--mach-service", required=True)
    parser.add_argument("--role", required=True, choices=["installer", "login", "navigation"])
    args = parser.parse_args()
    try:
        print(json.dumps(navigation.bind_input(args.source, args.destination, args.machine, args.mach_service, args.role), sort_keys=True))
        return 0
    except (navigation.lifecycle.LifecycleError, OSError, ValueError, TypeError, KeyError) as error:
        print(f"bind-arm-ubuntu-campaign-input: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
