#!/usr/bin/env python3
"""Audit PLAN.md's historical evidence without promoting old results to qualification."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
from typing import Any


EVIDENCE_SECTION = re.compile(
    r"^## Where we actually are\s*$\n(?P<body>.*?)(?=^## |\Z)", re.MULTILINE | re.DOTALL
)
BASELINE_START = "<!-- baseline-evidence:start -->"
BASELINE_END = "<!-- baseline-evidence:end -->"
EVIDENCE_REFERENCE = re.compile(
    r"docs/virtualization/evidence/[A-Za-z0-9._/-]+"
)
REACQUISITION_ONLY = {
    "docs/virtualization/evidence/p05-arm-2026-09-05/actual-manager-desktop-installer-detach-cold-reopen.json",
    "docs/virtualization/evidence/p06-pc-2026-09-06/clock-stall-rescope.json",
    "docs/virtualization/evidence/p06-pc-2026-09-06/tier-comparison-rpcdiag.json",
    "docs/virtualization/evidence/p07-macos-2026-09-05/actual-managed-suspend-restore.json",
}
HOST_ONLY = {
    "docs/virtualization/evidence/p07-macos-2026-09-05/host-metal-compute.json",
}
SHA256 = re.compile(r"^[0-9a-f]{64}$")


class AuditError(RuntimeError):
    pass


def fail(message: str) -> None:
    raise AuditError(f"plan evidence audit: {message}")


def evidence_section(plan: str) -> tuple[str, str]:
    """Prefer an explicit region so changing plan headings cannot omit evidence."""
    starts, ends = plan.count(BASELINE_START), plan.count(BASELINE_END)
    if starts or ends:
        if starts != 1 or ends != 1:
            fail("PLAN.md must contain exactly one matching baseline evidence marker pair")
        start = plan.index(BASELINE_START) + len(BASELINE_START)
        end = plan.index(BASELINE_END)
        if end < start:
            fail("PLAN.md baseline evidence markers are out of order")
        return "baseline-evidence", plan[start:end]
    sections = list(EVIDENCE_SECTION.finditer(plan))
    if len(sections) != 1:
        fail("PLAN.md must contain one baseline evidence region or one 'Where we actually are' section")
    return "Where we actually are", sections[0].group("body")


def direct_regular(path: Path) -> bool:
    return path.is_file() and not path.is_symlink()


def within(root: Path, candidate: Path) -> Path | None:
    root = root.resolve()
    candidate = candidate.resolve(strict=False)
    try:
        candidate.relative_to(root)
    except ValueError:
        return None
    return candidate


def local_attachment(document: Path, name: str) -> tuple[str, Path | None]:
    relative = Path(name)
    if relative.is_absolute():
        return "external-unavailable", None
    if any(part == ".." for part in relative.parts):
        return "unsafe-relative-path", None
    raw = document.parent
    for part in relative.parts:
        raw /= part
        if raw.is_symlink():
            return "unsafe-symbolic-link", None
    resolved = within(document.parent, raw)
    if resolved is None:
        return "unsafe-relative-path", None
    if not direct_regular(raw):
        return "unavailable", None
    return "available", raw


def digest(path: Path) -> str:
    result = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def read_json(document: Path) -> dict[str, Any]:
    try:
        value = json.loads(document.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"could not read JSON document {document}: {error}")
    if not isinstance(value, dict):
        fail(f"JSON document {document} must contain an object")
    return value


def parse_jsonl(document: Path) -> int:
    try:
        lines = document.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        fail(f"could not read JSONL document {document}: {error}")
    count = 0
    for line_number, line in enumerate(lines, start=1):
        if not line.strip():
            continue
        try:
            json.loads(line)
        except json.JSONDecodeError as error:
            fail(f"invalid JSONL in {document}:{line_number}: {error.msg}")
        count += 1
    if count == 0:
        fail(f"JSONL document {document} contains no JSON values")
    return count


def attachment_status(document: Path, name: str, expected: object, label: str) -> dict[str, str]:
    result = {"label": label, "name": name}
    if not isinstance(expected, str) or SHA256.fullmatch(expected) is None:
        return {**result, "status": "invalid-digest-declaration"}
    status, local = local_attachment(document, name)
    if status != "available" or local is None:
        return {**result, "status": status, "expectedSHA256": expected}
    actual = digest(local)
    return {
        **result,
        "status": "match" if actual == expected else "mismatch",
        "expectedSHA256": expected,
        "actualSHA256": actual,
    }


def declared_attachments(document: Path, receipt: dict[str, Any]) -> list[dict[str, str]]:
    result: list[dict[str, str]] = []
    for label in ("artifactSHA256", "logs"):
        values = receipt.get(label)
        if isinstance(values, dict):
            for name, expected in sorted(values.items()):
                if isinstance(name, str):
                    result.append(attachment_status(document, name, expected, label))

    artifacts = receipt.get("artifacts")
    if isinstance(artifacts, list):
        for index, artifact in enumerate(artifacts):
            if isinstance(artifact, dict) and isinstance(artifact.get("file"), str):
                result.append(
                    attachment_status(
                        document, artifact["file"], artifact.get("sha256"), f"artifacts[{index}]"
                    )
                )
    elif isinstance(artifacts, dict):
        for name, artifact in sorted(artifacts.items()):
            if not isinstance(artifact, dict):
                continue
            expected = artifact.get("sha256")
            filename = artifact.get("file", artifact.get("path"))
            if isinstance(filename, str):
                result.append(attachment_status(document, filename, expected, f"artifacts.{name}"))
            elif isinstance(expected, str):
                result.append(
                    {
                        "label": f"artifacts.{name}",
                        "name": name,
                        "expectedSHA256": expected,
                        "status": "external-unavailable",
                    }
                )
    return result


def receipt_references(document: Path, receipt: dict[str, Any]) -> list[dict[str, str]]:
    result: list[dict[str, str]] = []

    def visit(value: Any) -> None:
        if isinstance(value, dict):
            for key, child in value.items():
                if key == "receiptRef" and isinstance(child, str):
                    status, local = local_attachment(document, child)
                    result.append({"name": child, "status": status if local is None else "available"})
                visit(child)
        elif isinstance(value, list):
            for child in value:
                visit(child)

    visit(receipt)
    return result


def commit_status(root: Path, commit: str) -> str:
    if not re.fullmatch(r"[0-9a-f]{7,64}", commit):
        return "invalid-commit-declaration"
    result = subprocess.run(
        ["git", "-C", str(root), "cat-file", "-e", f"{commit}^{{commit}}"],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    return "reachable" if result.returncode == 0 else "unavailable"


def commit_bindings(root: Path, receipt: dict[str, Any]) -> list[dict[str, str]]:
    result: list[dict[str, str]] = []
    for key in ("baseCommit", "sourceCommit"):
        value = receipt.get(key)
        if isinstance(value, str):
            result.append({"label": key, "value": value, "status": commit_status(root, value)})
    values = receipt.get("implementationCommits")
    if isinstance(values, list):
        for index, value in enumerate(values):
            if isinstance(value, str):
                result.append(
                    {"label": f"implementationCommits[{index}]", "value": value, "status": commit_status(root, value)}
                )
    return result


def evidence_admission(relative: str) -> str:
    if relative in REACQUISITION_ONLY:
        return "reacquisition-only"
    if relative in HOST_ONLY:
        return "host-only-not-guest"
    return "historical-only"


def audit_document(root: Path, relative: str) -> dict[str, Any]:
    admission = evidence_admission(relative)
    status, document = local_attachment(root / "PLAN.md", relative)
    if status != "available" or document is None:
        return {"path": relative, "status": "unavailable", "admission": admission}
    if document.suffix == ".jsonl":
        try:
            count = parse_jsonl(document)
        except AuditError as error:
            return {"path": relative, "status": "invalid-jsonl", "error": str(error), "admission": admission}
        return {
            "path": relative,
            "status": "preserved-jsonl",
            "jsonValues": count,
            "admission": admission,
        }
    try:
        receipt = read_json(document)
    except AuditError as error:
        return {"path": relative, "status": "invalid-json", "error": str(error), "admission": admission}
    attachments = declared_attachments(document, receipt)
    commits = commit_bindings(root, receipt)
    references = receipt_references(document, receipt)
    attachments_match = bool(attachments) and all(item["status"] == "match" for item in attachments)
    auxiliary_match = all(item["status"] == "reachable" for item in commits) and all(
        item["status"] == "available" for item in references
    )
    if attachments_match and auxiliary_match:
        status = "preserved"
    elif not attachments and auxiliary_match:
        # A standalone JSON receipt is itself a portable historical artifact.  This
        # classification does not promote it to candidate or qualification evidence.
        status = "preserved-document"
    elif not attachments:
        status = "insufficient-portable-bindings"
    else:
        status = "incomplete-local-payload"
    return {
        "path": relative,
        "status": status,
        "admission": admission,
        "attachments": attachments,
        "commitBindings": commits,
        "receiptReferences": references,
    }


def citation_status(root: Path, relative: str) -> dict[str, str]:
    raw = root / relative
    current = root
    for part in Path(relative).parts:
        if part == "..":
            return {"path": relative, "status": "unsafe-relative-path"}
        current /= part
        if current.is_symlink():
            return {"path": relative, "status": "unsafe-symbolic-link"}
    if within(root, raw) is None:
        return {"path": relative, "status": "unsafe-relative-path"}
    if direct_regular(raw):
        return {"path": relative, "status": "available-file"}
    if raw.is_dir():
        return {"path": relative, "status": "available-directory"}
    return {"path": relative, "status": "unavailable"}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--plan", type=Path, default=Path("PLAN.md"))
    parser.add_argument("--output", type=Path)
    parser.add_argument(
        "--require-complete",
        action="store_true",
        help="fail when a cited historical receipt lacks locally verified payloads",
    )
    arguments = parser.parse_args()
    root = arguments.root.resolve()
    plan = arguments.plan if arguments.plan.is_absolute() else root / arguments.plan
    if not direct_regular(plan):
        fail(f"plan must be a direct regular file: {plan}")
    plan_bytes = plan.read_bytes()
    section_name, section_body = evidence_section(plan_bytes.decode("utf-8"))
    citations = sorted({item.group(0).rstrip(".") for item in EVIDENCE_REFERENCE.finditer(section_body)})
    if not citations:
        fail(f"{section_name} cites no evidence paths")
    citation_bindings = [citation_status(root, relative) for relative in citations]
    supplemental = sorted(
        relative for relative in REACQUISITION_ONLY | HOST_ONLY if (root / relative).exists()
    )
    references = sorted(
        {relative for relative in citations if Path(relative).suffix in {".json", ".jsonl"}}
        | set(supplemental)
    )
    documents = [audit_document(root, relative) for relative in references]
    preserved_statuses = {"preserved", "preserved-document", "preserved-jsonl"}
    incomplete = [item["path"] for item in documents if item["status"] not in preserved_statuses]
    reacquisition = [item["path"] for item in documents if item["admission"] == "reacquisition-only"]
    qualification_blocking = [
        item["path"] for item in documents
        if item["status"] not in preserved_statuses
        and item["admission"] not in {"reacquisition-only", "host-only-not-guest"}
    ]
    unresolved_citations = [
        item["path"] for item in citation_bindings
        if item["status"] not in {"available-file", "available-directory"}
    ]
    output = {
        "schemaVersion": 1,
        "kind": "dory.plan-evidence-audit",
        "auditorSHA256": digest(Path(__file__).resolve()),
        "planSHA256": hashlib.sha256(plan_bytes).hexdigest(),
        "historicalEvidenceOnly": True,
        "evidenceSection": section_name,
        "citationBindings": citation_bindings,
        "documents": documents,
        "incompleteDocuments": incomplete,
        "reacquisitionOnlyDocuments": reacquisition,
        "qualificationBlockingDocuments": qualification_blocking,
        "unresolvedCitations": unresolved_citations,
    }
    encoded = (json.dumps(output, sort_keys=True, indent=2) + "\n").encode("utf-8")
    if arguments.output is None:
        sys.stdout.buffer.write(encoded)
    else:
        destination = arguments.output if arguments.output.is_absolute() else root / arguments.output
        if destination.is_symlink():
            fail(f"output must not be a symbolic link: {destination}")
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(encoded)
    return 1 if arguments.require_complete and (qualification_blocking or unresolved_citations) else 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AuditError as error:
        raise SystemExit(str(error))
