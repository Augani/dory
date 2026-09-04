#!/usr/bin/env python3
"""Separate the frozen public release-testing host from experimental hosts.

An eligible host is not a qualified product. Minimum-runtime coverage, physical
machine checks, signatures and the candidate campaigns are independent gates.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path


POLICY_ID = "dory.three-cell.apple-silicon.macos15.sdk26-5-v1"
# Exact public tuple verified from Apple's release listing on 2026-09-04. A
# suffix-free build number alone does not prove that an OS build is public.
RELEASE_TESTING_HOSTS = {("26.6.2", "25G83")}
PUBLIC_RELEASE_SOURCE = "https://developer.apple.com/news/releases/"


class HostPolicyFailure(RuntimeError):
    pass


def inspect_host(version: str, build: str, *, experimental: bool = False) -> dict[str, object]:
    if re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,2}", version) is None:
        raise HostPolicyFailure(f"invalid observed macOS version: {version!r}")
    if re.fullmatch(r"[0-9]+[A-Z][0-9]+[a-z]?", build) is None:
        raise HostPolicyFailure(f"invalid observed macOS build: {build!r}")
    approved = (version, build) in RELEASE_TESTING_HOSTS
    if not experimental and not approved:
        raise HostPolicyFailure(
            f"macOS {version} ({build}) is outside the frozen public release-testing host policy; "
            "record experimental engineering evidence separately or review a policy revision"
        )
    return {
        "schemaVersion": 1,
        "kind": "dev.dory.release-host-policy",
        "policyID": POLICY_ID,
        "hostVersion": version,
        "hostBuild": build,
        "status": "EXPERIMENTAL" if experimental else "ELIGIBLE_FOR_RELEASE_TESTING",
        "releaseTestingEligible": approved and not experimental,
        "releaseQualified": False,
        "minimumRuntimeMacOS": "15.0",
        "publicReleaseSource": PUBLIC_RELEASE_SOURCE if approved else None,
        "scope": "host-channel-only; physical identity and candidate qualification are separate",
    }


def observed_version(argument: str) -> str:
    result = subprocess.run(
        ["sw_vers", argument], text=True, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, check=False,
    )
    if result.returncode != 0:
        raise HostPolicyFailure(f"cannot inspect host {argument}: {result.stderr.strip()}")
    return result.stdout.strip()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path)
    parser.add_argument(
        "--experimental", action="store_true",
        help="record engineering-only host facts; returns exit 3 and cannot pass a release gate",
    )
    arguments = parser.parse_args()
    try:
        receipt = inspect_host(
            observed_version("-productVersion"), observed_version("-buildVersion"),
            experimental=arguments.experimental,
        )
        encoded = json.dumps(receipt, sort_keys=True, separators=(",", ":")) + "\n"
        if arguments.output is None:
            sys.stdout.write(encoded)
        else:
            arguments.output.write_text(encoded, encoding="utf-8")
        # Experimental capture is intentionally a non-success exit status so
        # accidentally passing this option cannot open a shell release gate.
        return 3 if arguments.experimental else 0
    except (OSError, HostPolicyFailure) as error:
        print(f"release host policy: FAIL: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
