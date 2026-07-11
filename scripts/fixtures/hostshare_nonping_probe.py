#!/usr/bin/env python3
"""Run one independently bounded non-ping Docker request after a fail-stop gate opens."""

import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time


def write_result(path, payload):
    destination = Path(path)
    temporary = destination.with_name(destination.name + f".tmp-{os.getpid()}")
    temporary.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temporary, destination)


def stop_process_group(process):
    if process is None or process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=1)
        return
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait()


def main():
    if sys.flags.optimize != 0:
        print(
            "host-share non-ping probe refuses optimized Python because assertions would be disabled",
            file=sys.stderr,
        )
        return 2
    if len(sys.argv) != 7:
        raise SystemExit(
            "usage: hostshare_nonping_probe.py GATE DOCKER SOCKET REQUEST_TIMEOUT "
            "GATE_TIMEOUT EVIDENCE"
        )

    gate, docker_bin, socket_path, request_timeout_text, gate_timeout_text, evidence = sys.argv[1:]
    request_timeout = int(request_timeout_text)
    gate_timeout = int(gate_timeout_text)
    if request_timeout <= 0 or gate_timeout <= 0:
        raise SystemExit("timeouts must be positive integers")

    # Keep evidence timestamps in the POSIX CLOCK_MONOTONIC domain used by the shell harness.
    # On macOS, time.monotonic() is backed by a different clock with a different epoch.
    monitor_started_ms = time.clock_gettime_ns(time.CLOCK_MONOTONIC) // 1_000_000
    Path(evidence + ".ready").write_text(str(monitor_started_ms) + "\n", encoding="utf-8")
    gate_deadline = time.monotonic() + gate_timeout
    while not os.path.exists(gate):
        if time.monotonic() >= gate_deadline:
            write_result(
                evidence,
                {
                    "command": "docker version --format {{.Server.Version}}",
                    "gate_observed": False,
                    "monitor_started_monotonic_ms": monitor_started_ms,
                    "request_timeout_seconds": request_timeout,
                    "timed_out": False,
                },
            )
            return 125
        time.sleep(0.005)

    command = [
        docker_bin,
        "-H",
        f"unix://{socket_path}",
        "version",
        "--format",
        "{{.Server.Version}}",
    ]
    environment = os.environ.copy()
    # The outer watchdog is authoritative. These deliberately exceed the historical 210-second
    # backend retry so a passing result cannot come from Docker's own shorter client timeout.
    environment["DOCKER_CLIENT_TIMEOUT"] = "300"
    environment["DOCKER_HTTP_TIMEOUT"] = "300"
    process = None

    def interrupted(_signal_number, _frame):
        stop_process_group(process)
        raise SystemExit(128 + _signal_number)

    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    signal.signal(signal.SIGHUP, interrupted)

    process = subprocess.Popen(
        command,
        env=environment,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        start_new_session=True,
    )
    # This is a second handshake, distinct from monitor readiness. Publish it only after Popen has
    # returned, so its timestamp is an upper bound on the actual child launch. Proving this marker
    # precedes recovery therefore also proves the Docker request itself began before recovery.
    request_started_ms = time.clock_gettime_ns(time.CLOCK_MONOTONIC) // 1_000_000
    Path(evidence + ".started").write_text(str(request_started_ms) + "\n", encoding="utf-8")
    timed_out = False
    try:
        stdout, stderr = process.communicate(timeout=request_timeout)
    except subprocess.TimeoutExpired:
        timed_out = True
        stop_process_group(process)
        stdout, stderr = process.communicate()

    request_finished_ms = time.clock_gettime_ns(time.CLOCK_MONOTONIC) // 1_000_000
    write_result(
        evidence,
        {
            "command": "docker version --format {{.Server.Version}}",
            "elapsed_ms": request_finished_ms - request_started_ms,
            "gate_observed": True,
            "monitor_started_monotonic_ms": monitor_started_ms,
            "request_finished_monotonic_ms": request_finished_ms,
            "request_started_monotonic_ms": request_started_ms,
            "request_timeout_seconds": request_timeout,
            "returncode": process.returncode,
            "stderr": stderr[-4096:],
            "stdout": stdout[-4096:],
            "timed_out": timed_out,
        },
    )
    return 124 if timed_out else 0


if __name__ == "__main__":
    raise SystemExit(main())
