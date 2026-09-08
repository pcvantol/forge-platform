#!/usr/bin/env python3
"""Plan, apply, or inspect Forge Platform's canonical product version.

This is a product-local preparation helper. It deliberately does not commit,
push, publish, or decide release compatibility.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import tempfile
import subprocess
import hashlib
from typing import Any

PRODUCT = "forge-platform"
POLICY_REVISION = "FORGE_FAMILY_REPOSITORY_SEMVER_V1"
VERSION = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
OPERATION_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{7,127}$")
MANIFEST_PATH = "product-version.json"
OPERATIONS_DIRECTORY = ".product-version-operations"


def version_file(root: Path) -> Path:
    return root.resolve() / MANIFEST_PATH

def _pairs(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result: raise ValueError(f"duplicate manifest key: {key}")
        result[key] = value
    return result

def current(root: Path) -> tuple[Path, dict[str, Any], tuple[int, int, int]]:
    target = version_file(root)
    try:
        payload = json.loads(target.read_text(encoding="utf-8"), object_pairs_hook=_pairs)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        raise RuntimeError("canonical product version manifest is unreadable") from error
    if not isinstance(payload, dict): raise RuntimeError("canonical product version manifest must be an object")
    if payload.get("schema_version") != 1 or isinstance(payload.get("schema_version"), bool):
        raise RuntimeError("canonical product version manifest has an unsupported schema")
    if payload.get("product") != PRODUCT: raise RuntimeError(f"canonical product version manifest must identify {PRODUCT}")
    value = payload.get("version")
    if not isinstance(value, str) or VERSION.fullmatch(value) is None:
        raise RuntimeError("canonical product version must be stable X.Y.Z")
    return target, payload, tuple(int(part) for part in value.split("."))

def _atomic_write(path: Path, text: str) -> None:
    mode = path.stat().st_mode if path.exists() else 0o644
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text); handle.flush(); os.fsync(handle.fileno())
        os.chmod(temporary, mode); os.replace(temporary, path)
    except BaseException:
        try: os.unlink(temporary)
        except FileNotFoundError: pass
        raise

def _head(root: Path) -> str:
    try:
        return subprocess.run(["git", "-C", str(root), "rev-parse", "HEAD"], check=True, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout.strip()
    except (OSError, subprocess.CalledProcessError) as error:
        raise RuntimeError("version apply requires a Git checkout with HEAD") from error


def _target(actual: str, bump: str | None, exact: str | None) -> str:
    major, minor, patch = (int(part) for part in actual.split("."))
    if (bump is None) == (exact is None):
        raise RuntimeError("provide exactly one requested bump or exact target version")
    if exact is not None:
        if VERSION.fullmatch(exact) is None: raise RuntimeError("the requested release version must be stable X.Y.Z")
        return exact
    if bump == "patch": return f"{major}.{minor}.{patch + 1}"
    if bump == "minor": return f"{major}.{minor + 1}.0"
    raise RuntimeError("major requires explicit release authority")


def _operation_path(root: Path, operation_id: str) -> Path:
    if OPERATION_ID.fullmatch(operation_id) is None:
        raise RuntimeError("operation ID must be 8-128 safe identifier characters")
    return root / OPERATIONS_DIRECTORY / f"{operation_id}.json"


def _operation(operation_id: str, lineage: str, expected_head: str, baseline: str,
               bump: str | None, exact: str | None, target: str) -> dict[str, Any]:
    if not lineage.strip(): raise RuntimeError("event lineage is required")
    return {"schema_version": 1, "operation_id": operation_id, "product": PRODUCT,
            "component": PRODUCT, "policy_revision": POLICY_REVISION, "event_lineage": lineage,
            "expected_source_revision": expected_head, "baseline_version": baseline,
            "requested_bump": bump, "requested_exact_version": exact, "target_version": target,
            "allowed_projection_paths": [MANIFEST_PATH]}


def _same(existing: dict[str, Any], requested: dict[str, Any]) -> bool:
    return all(existing.get(key) == value for key, value in requested.items())


def plan(root: Path, operation_id: str, lineage: str, expected_head: str,
         bump: str | None, exact: str | None) -> dict[str, Any]:
    _, payload, _ = current(root)
    requested = _operation(operation_id, lineage, expected_head, payload["version"], bump, exact,
                           _target(payload["version"], bump, exact))
    path = _operation_path(root, operation_id)
    if not path.exists(): return requested
    existing = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=_pairs)
    if not isinstance(existing, dict) or not _same(existing, requested):
        raise RuntimeError("operation ID conflict: existing operation has different input")
    return existing


def apply(root: Path, operation_id: str, lineage: str, expected_head: str,
          bump: str | None, exact: str | None) -> dict[str, Any]:
    target_file, payload, _ = current(root)
    actual = payload["version"]
    path = _operation_path(root, operation_id)
    if path.exists():
        operation = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=_pairs)
        if not isinstance(operation, dict): raise RuntimeError("version operation must be an object")
        # A retry recognizes durable provenance before evaluating a newer checkout HEAD.
        requested = _operation(operation_id, lineage, expected_head, operation.get("baseline_version"), bump,
                               exact, operation.get("target_version"))
        if not _same(operation, requested):
            raise RuntimeError("operation ID conflict: existing operation has different input")
        target = operation["target_version"]
        if actual not in (operation["baseline_version"], target):
            raise RuntimeError("operation recovery conflict: canonical version is neither baseline nor target")
    else:
        if _head(root) != expected_head:
            raise RuntimeError("stale source head: refresh and requalify the candidate")
        target = _target(actual, bump, exact)
        operation = _operation(operation_id, lineage, expected_head, actual, bump, exact, target)
        operation["state"] = "prepared"
        operation["manifest_sha256_before"] = hashlib.sha256(target_file.read_bytes()).hexdigest()
        path.parent.mkdir(mode=0o755, exist_ok=True)
        # Persist allocation first: a crash is recoverable with this operation ID, never a new bump.
        _atomic_write(path, json.dumps(operation, indent=2, sort_keys=True) + "\n")
    if actual != target:
        payload["version"] = target
        _atomic_write(target_file, json.dumps(payload, indent=2, sort_keys=True) + "\n")
    operation["state"] = "applied"
    operation["manifest_sha256_after"] = hashlib.sha256(target_file.read_bytes()).hexdigest()
    _atomic_write(path, json.dumps(operation, indent=2, sort_keys=True) + "\n")
    return operation


def verify_operation(root: Path, candidate_head: str) -> None:
    """Verify an already-committed, isolated preparation candidate read-only.

    Qualification is deliberately tied to the exact candidate SHA, not a prior
    green source SHA or a merge ref synthesized by GitHub Actions.
    """
    actual_head = _head(root)
    if actual_head != candidate_head:
        raise RuntimeError("candidate head mismatch: qualification must inspect the exact candidate SHA")
    operation_root = root / OPERATIONS_DIRECTORY
    if not operation_root.exists():
        print("PRODUCT_VERSION_OPERATION=NOT_APPLICABLE no version-preparation receipt")
        return
    operations = sorted(operation_root.glob("*.json"))
    if len(operations) != 1:
        raise RuntimeError("version-preparation candidate must contain exactly one operation receipt")
    operation = json.loads(operations[0].read_text(encoding="utf-8"), object_pairs_hook=_pairs)
    if not isinstance(operation, dict) or operation.get("state") != "applied":
        raise RuntimeError("version operation receipt is not an applied object")
    required = ("operation_id", "product", "component", "policy_revision", "event_lineage",
                "expected_source_revision", "baseline_version", "target_version",
                "allowed_projection_paths", "manifest_sha256_before", "manifest_sha256_after")
    if any(key not in operation for key in required):
        raise RuntimeError("version operation receipt is incomplete")
    if operation["product"] != PRODUCT or operation["component"] != PRODUCT:
        raise RuntimeError("version operation receipt has the wrong product identity")
    if operation["policy_revision"] != POLICY_REVISION or operation["allowed_projection_paths"] != [MANIFEST_PATH]:
        raise RuntimeError("version operation receipt has unsupported policy or projection paths")
    _operation_path(root, operation["operation_id"])
    _, payload, _ = current(root)
    if payload["version"] != operation["target_version"]:
        raise RuntimeError("version operation target does not match the canonical projection")
    if hashlib.sha256(version_file(root).read_bytes()).hexdigest() != operation["manifest_sha256_after"]:
        raise RuntimeError("version operation result digest does not match the canonical projection")
    try:
        parent = subprocess.run(["git", "-C", str(root), "rev-parse", f"{candidate_head}^"], check=True,
                                text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout.strip()
        changed = subprocess.run(["git", "-C", str(root), "diff", "--name-only", parent, candidate_head],
                                 check=True, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout.splitlines()
    except (OSError, subprocess.CalledProcessError) as error:
        raise RuntimeError("candidate must have an inspectable single parent") from error
    if parent != operation["expected_source_revision"]:
        raise RuntimeError("candidate parent does not equal the operation's expected source revision")
    expected_paths = {MANIFEST_PATH, f"{OPERATIONS_DIRECTORY}/{operation['operation_id']}.json"}
    if set(changed) != expected_paths:
        raise RuntimeError("version-preparation candidate changes paths outside its declared operation")
    print(f"PRODUCT_VERSION_OPERATION=PASS operation_id={operation['operation_id']} candidate={candidate_head}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", type=Path, default=Path.cwd())
    parser.add_argument("--operation-id")
    parser.add_argument("--event-lineage")
    parser.add_argument("--expected-head")
    parser.add_argument("--bump", choices=("patch", "minor"))
    parser.add_argument("--set-version")
    parser.add_argument("--expected-version")
    parser.add_argument("--plan", action="store_true")
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--verify-operation", action="store_true")
    parser.add_argument("--candidate-head")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args(argv)
    if sum((args.check, args.plan, args.apply, args.verify_operation)) != 1: parser.error("provide exactly one operation mode")
    if args.check:
        if args.bump or args.set_version or args.operation_id or args.event_lineage or args.expected_head: parser.error("--check only reads the version source")
        _, payload, _ = current(args.source_root)
        print(f"PRODUCT_VERSION=PASS version={payload['version']}")
    elif args.verify_operation:
        if not args.candidate_head: parser.error("--verify-operation requires --candidate-head")
        if any((args.operation_id, args.event_lineage, args.expected_head, args.bump, args.set_version, args.expected_version)):
            parser.error("--verify-operation only inspects a committed candidate")
        verify_operation(args.source_root, args.candidate_head)
    else:
        if args.expected_version is not None: parser.error("use expected source head, not --expected-version")
        if not all((args.operation_id, args.event_lineage, args.expected_head)):
            parser.error("--plan/--apply require --operation-id, --event-lineage, and --expected-head")
        operation = (plan if args.plan else apply)(args.source_root, args.operation_id, args.event_lineage,
                                                   args.expected_head, args.bump, args.set_version)
        print(json.dumps(operation, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
