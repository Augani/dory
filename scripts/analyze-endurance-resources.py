#!/usr/bin/env python3
"""Fail closed when cleaned Dory resource samples do not form a bounded plateau."""

from __future__ import annotations

import argparse
import csv
import statistics
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("resources", type=Path)
    parser.add_argument("--fd-growth", type=int, required=True)
    parser.add_argument("--rss-growth-mb", type=int, required=True)
    parser.add_argument("--disk-growth-mb", type=int, required=True)
    parser.add_argument("--idle-cpu", type=float, required=True)
    parser.add_argument("--fseventsd-rss-growth-mb", type=int, required=True)
    parser.add_argument("--fseventsd-cpu", type=float, required=True)
    return parser.parse_args()


def numeric(row: dict[str, str], key: str) -> float:
    try:
        return float(row[key])
    except (KeyError, TypeError, ValueError) as error:
        raise SystemExit(f"invalid resource sample field {key!r}: {row.get(key)!r}") from error


def median(rows: list[dict[str, str]], key: str) -> float:
    return statistics.median(numeric(row, key) for row in rows)


def format_growth(value: float) -> str:
    return str(int(value)) if value.is_integer() else f"{value:.1f}"


def main() -> None:
    args = parse_args()
    if min(args.fd_growth, args.rss_growth_mb, args.disk_growth_mb, args.fseventsd_rss_growth_mb) < 0:
        raise SystemExit("resource growth budgets must be non-negative")
    if min(args.idle_cpu, args.fseventsd_cpu) < 0:
        raise SystemExit("CPU ceilings must be non-negative")

    with args.resources.open(encoding="utf-8", newline="") as handle:
        rows = list(csv.DictReader(handle, delimiter="\t"))
    cleaned = [row for row in rows if row.get("phase") in {"cleaned", "final"}]
    if len(cleaned) < 2:
        raise SystemExit("at least two cleaned/final resource samples are required")

    # At eight-hour scale, 200 samples remove cold-start and one-off allocator noise while still
    # comparing disjoint early/late periods. Short preflights use one quarter of their samples.
    window_size = min(200, max(1, len(cleaned) // 4))
    first = cleaned[:window_size]
    last = cleaned[-window_size:]
    failures: list[str] = []

    process_growth = median(last, "pid_count") - median(first, "pid_count")
    fd_growth = median(last, "fd_total") - median(first, "fd_total")
    rss_growth = median(last, "rss_kb") - median(first, "rss_kb")
    disk_growth = median(last, "state_kb") - median(first, "state_kb")
    fseventsd_rss_growth = median(last, "fseventsd_rss_kb") - median(first, "fseventsd_rss_kb")
    if process_growth > 0:
        failures.append(f"median Dory process count grew by {format_growth(process_growth)}")
    if fd_growth > args.fd_growth:
        failures.append(f"median FD growth {format_growth(fd_growth)} > {args.fd_growth}")
    if rss_growth > args.rss_growth_mb * 1024:
        failures.append(
            f"median RSS growth {format_growth(rss_growth)} KiB > {args.rss_growth_mb} MiB"
        )
    if disk_growth > args.disk_growth_mb * 1024:
        failures.append(
            f"median state growth {format_growth(disk_growth)} KiB > {args.disk_growth_mb} MiB"
        )
    if fseventsd_rss_growth > args.fseventsd_rss_growth_mb * 1024:
        failures.append(
            f"median fseventsd RSS growth {format_growth(fseventsd_rss_growth)} KiB > "
            f"{args.fseventsd_rss_growth_mb} MiB"
        )

    idle_rows = cleaned[-min(5, len(cleaned)) :]
    idle_cpu = median(idle_rows, "cpu_percent")
    fseventsd_cpu = median(idle_rows, "fseventsd_cpu_percent")
    if idle_cpu > args.idle_cpu:
        failures.append(f"median cleaned CPU {idle_cpu:.2f}% > {args.idle_cpu:g}%")
    if fseventsd_cpu > args.fseventsd_cpu:
        failures.append(
            f"median cleaned fseventsd CPU {fseventsd_cpu:.2f}% > {args.fseventsd_cpu:g}%"
        )
    if failures:
        raise SystemExit("; ".join(failures))

    print(
        "resource plateau PASS: "
        f"window={window_size} "
        f"process_growth={format_growth(process_growth)} "
        f"fd_growth={format_growth(fd_growth)} "
        f"rss_growth_kib={format_growth(rss_growth)} "
        f"disk_growth_kib={format_growth(disk_growth)} "
        f"cleaned_cpu_median={idle_cpu:.2f}% "
        f"fseventsd_rss_growth_kib={format_growth(fseventsd_rss_growth)} "
        f"fseventsd_cpu_median={fseventsd_cpu:.2f}%"
    )


if __name__ == "__main__":
    main()
