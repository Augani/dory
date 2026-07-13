#!/usr/bin/env python3
"""Semantically verify exact-candidate physical sleep/wake release evidence."""

import argparse
import csv
import hashlib
import json
import pathlib
import re


def digest(path: pathlib.Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def text_digest(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


def properties(path: pathlib.Path) -> dict[str, str]:
    values: dict[str, str] = {}
    with path.open(encoding="utf-8") as handle:
        for raw in handle:
            key, separator, value = raw.rstrip("\n").partition("=")
            if not separator or key in values:
                raise ValueError(f"malformed manifest row: {raw!r}")
            values[key] = value
    return values


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True, type=pathlib.Path)
    parser.add_argument("--results", required=True, type=pathlib.Path)
    parser.add_argument("--evidence-root", required=True, type=pathlib.Path)
    parser.add_argument("--app", required=True, type=pathlib.Path)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--run-attempt", required=True)
    parser.add_argument("--cycles", type=int, default=5)
    parser.add_argument("--auto-wake-seconds", type=int, default=30)
    parser.add_argument("--custom-dns", required=True)
    parser.add_argument("--probe-host", required=True)
    parser.add_argument("--probe-url", required=True)
    parser.add_argument("--tailscale-exit-node", required=True)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if not re.fullmatch(r"[0-9a-f]{40}", args.source_commit):
        raise ValueError("source commit must be a full lowercase Git SHA")
    if args.cycles <= 0 or args.auto_wake_seconds <= 0:
        raise ValueError("cycles and auto-wake seconds must be positive")
    if not args.app.is_dir():
        raise ValueError(f"candidate app is missing: {args.app}")

    manifest = properties(args.manifest)
    expected_keys = {
        "run_id",
        "cycles",
        "auto_wake_seconds",
        "physical_sleep",
        "wifi_required",
        "vpn_required",
        "custom_dns_required",
        "route_churn",
        "route_churn_rounds",
        "release_qualifying",
        "source_commit",
        "github_run_id",
        "github_run_attempt",
        "app_executable_sha256",
        "docker_sha256",
        "doryd_sha256",
        "dory_hv_sha256",
        "dorydctl_sha256",
        "machine_kernel_sha256",
        "machine_rootfs_sha256",
        "machine_id",
        "machine_session_reconnect",
        "custom_dns_sha256",
        "probe_host_sha256",
        "probe_url_sha256",
        "tailscale_exit_node_sha256",
    }
    if set(manifest) != expected_keys:
        raise ValueError(f"sleep/wake manifest keys differ: {sorted(set(manifest) ^ expected_keys)}")
    if not re.fullmatch(r"[0-9]{8}T[0-9]{6}Z-[0-9]+", manifest["run_id"]):
        raise ValueError("sleep/wake run ID is malformed")
    expected = {
        "cycles": str(args.cycles),
        "auto_wake_seconds": str(args.auto_wake_seconds),
        "physical_sleep": "true",
        "wifi_required": "true",
        "vpn_required": "true",
        "custom_dns_required": "true",
        "route_churn": "PASS",
        "route_churn_rounds": "3",
        "release_qualifying": "true",
        "source_commit": args.source_commit,
        "github_run_id": args.run_id,
        "github_run_attempt": args.run_attempt,
        "machine_session_reconnect": "PASS",
    }
    for key, value in expected.items():
        if manifest.get(key) != value:
            raise ValueError(f"sleep/wake {key} mismatch: {manifest.get(key)!r} != {value!r}")

    binaries = {
        "app_executable_sha256": args.app / "Contents/MacOS/Dory",
        "docker_sha256": args.app / "Contents/Helpers/docker",
        "doryd_sha256": args.app / "Contents/Helpers/doryd",
        "dory_hv_sha256": args.app / "Contents/Helpers/dory-hv",
        "dorydctl_sha256": args.app / "Contents/Helpers/dorydctl",
        "machine_kernel_sha256": args.app / "Contents/Resources/dory-hv-kernel-arm64",
        "machine_rootfs_sha256": args.app / "Contents/Resources/dory-machine-rootfs-arm64.ext4",
    }
    for key, path in binaries.items():
        if not path.is_file() or manifest.get(key) != digest(path):
            raise ValueError(f"sleep/wake binary mismatch: {key}")
    if manifest["machine_id"] != f"dory-sleep-session-{manifest['run_id']}":
        raise ValueError("sleep/wake machine ID is not bound to the evidence run")

    private_contract = {
        "custom_dns_sha256": text_digest(args.custom_dns),
        "probe_host_sha256": text_digest(args.probe_host),
        "probe_url_sha256": text_digest(args.probe_url),
        "tailscale_exit_node_sha256": text_digest(args.tailscale_exit_node),
    }
    for key, value in private_contract.items():
        if manifest.get(key) != value:
            raise ValueError(f"sleep/wake private network contract mismatch: {key}")

    route_results_path = args.evidence_root / "route-churn-results.tsv"
    with route_results_path.open(encoding="utf-8", newline="") as handle:
        route_rows = list(csv.DictReader(handle, delimiter="\t"))
    expected_route_rows = {
        (str(round_number), phase)
        for round_number in range(1, 4)
        for phase in ("exit-node-active", "baseline-restored")
    }
    route_by_key = {(row.get("round"), row.get("phase")): row for row in route_rows}
    if len(route_by_key) != len(route_rows) or set(route_by_key) != expected_route_rows:
        raise ValueError("exit-node route-churn evidence is incomplete or duplicated")
    if any(row.get("status") != "PASS" for row in route_rows):
        raise ValueError("exit-node route-churn evidence contains a failure")
    enabled_status = sorted(args.evidence_root.glob("route-churn-*-enabled/tailscale-status.json"))
    restored_status = sorted(args.evidence_root.glob("route-churn-*-restored/tailscale-status.json"))
    restored_diffs = sorted(args.evidence_root.glob("route-churn-*-restored/*.contract.diff"))
    if len(enabled_status) != 3 or len(restored_status) != 3 or len(restored_diffs) != 15:
        raise ValueError("exit-node route-churn artifacts are incomplete")
    if any(path.stat().st_size == 0 for path in enabled_status + restored_status):
        raise ValueError("exit-node route-churn Tailscale status evidence is empty")
    if any(path.stat().st_size != 0 for path in restored_diffs):
        raise ValueError("host network contract did not restore after exit-node churn")

    with args.results.open(encoding="utf-8", newline="") as handle:
        rows = list(csv.DictReader(handle, delimiter="\t"))
    expected_fields = ["cycle", "phase", "status", "detail"]
    if not rows or list(rows[0]) != expected_fields:
        raise ValueError("sleep/wake results schema mismatch")
    expected_rows = {
        (str(cycle), phase)
        for cycle in range(1, args.cycles + 1)
        for phase in (
            "machine-session-pre-sleep",
            "pre-sleep",
            "sleep-resume",
            "machine-session-reconnect",
            "post-wake",
        )
    }
    by_key = {(row["cycle"], row["phase"]): row for row in rows}
    if len(by_key) != len(rows) or set(by_key) != expected_rows:
        raise ValueError("sleep/wake evidence rows are incomplete or duplicated")
    if any(row["status"] != "PASS" for row in rows):
        raise ValueError("sleep/wake evidence contains a failure")
    minimum_sleep = max(5, args.auto_wake_seconds // 2)
    detail_pattern = re.compile(
        rf"elapsed_seconds=([0-9]+) scheduled_wake_seconds={args.auto_wake_seconds}"
    )
    for cycle in range(1, args.cycles + 1):
        detail = by_key[(str(cycle), "sleep-resume")]["detail"]
        match = detail_pattern.fullmatch(detail)
        if match is None or int(match.group(1)) < minimum_sleep:
            raise ValueError(f"cycle {cycle} did not prove physical sleep")
        if by_key[(str(cycle), "machine-session-pre-sleep")]["detail"] != \
                "interactive shell ready token observed":
            raise ValueError(f"cycle {cycle} did not prove a live pre-sleep machine shell")
        if by_key[(str(cycle), "machine-session-reconnect")]["detail"] != \
                "fresh exec, stop/start, and disk marker verified":
            raise ValueError(f"cycle {cycle} did not prove machine reconnect and restart")

        shell_output = args.evidence_root / f"cycle-{cycle}-machine-shell.out"
        token = f"DORY_SESSION_READY_{cycle}_{manifest['run_id']}"
        if not shell_output.is_file() or token not in shell_output.read_text(errors="replace"):
            raise ValueError(f"cycle {cycle} interactive machine shell evidence is missing")

        status_files = {
            "machine-status-after-wake": "running",
            "machine-status-stopped": "stopped",
            "machine-status-restarted": "running",
        }
        for suffix, state in status_files.items():
            path = args.evidence_root / f"cycle-{cycle}-{suffix}.json"
            try:
                payload = json.loads(path.read_text())
            except (FileNotFoundError, json.JSONDecodeError) as error:
                raise ValueError(f"cycle {cycle} machine status evidence is invalid: {suffix}") from error
            if payload.get("id") != manifest["machine_id"] or payload.get("state") != state:
                raise ValueError(f"cycle {cycle} machine status evidence mismatch: {suffix}")

        exec_files = {
            "machine-reconnect": f"dory-machine-reconnect-{cycle}",
            "machine-restart-persistence": f"dory-machine-restart-{cycle}",
        }
        for suffix, expected_stdout in exec_files.items():
            path = args.evidence_root / f"cycle-{cycle}-{suffix}.json"
            try:
                payload = json.loads(path.read_text())
            except (FileNotFoundError, json.JSONDecodeError) as error:
                raise ValueError(f"cycle {cycle} machine exec evidence is invalid: {suffix}") from error
            expected_exec = {
                "schema": "dev.dory.machine.exec",
                "version": 1,
                "machine": manifest["machine_id"],
                "exitCode": 0,
                "timedOut": False,
                "stdout": expected_stdout,
                "stdoutTruncated": False,
                "stderrTruncated": False,
            }
            if any(payload.get(key) != value for key, value in expected_exec.items()):
                raise ValueError(f"cycle {cycle} machine exec evidence mismatch: {suffix}")

    scheduled = sorted(args.evidence_root.glob("cycle-*-scheduled-wake.txt"))
    power_logs = sorted(args.evidence_root.glob("cycle-*-pmset-log.txt"))
    if len(scheduled) != args.cycles or len(power_logs) != args.cycles:
        raise ValueError("sleep/wake power evidence is incomplete")
    for path in scheduled:
        if "wake" not in path.read_text(errors="replace").lower():
            raise ValueError(f"scheduled hardware wake evidence is missing: {path}")
    for path in power_logs:
        content = path.read_text(errors="replace").lower()
        if "sleep" not in content or "wake" not in content:
            raise ValueError(f"pmset log does not contain sleep and wake events: {path}")

    after_contracts = sorted(args.evidence_root.glob("cycle-*-after/contract.sha256"))
    contract_diffs = sorted(args.evidence_root.glob("cycle-*-after/*.contract.diff"))
    if len(after_contracts) != args.cycles or len(contract_diffs) != args.cycles * 5:
        raise ValueError("post-wake host network-contract evidence is incomplete")
    if any(path.stat().st_size != 0 for path in contract_diffs):
        raise ValueError("host network contract changed after wake")

    print("physical sleep/wake evidence: PASS")


if __name__ == "__main__":
    main()
