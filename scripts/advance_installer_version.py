#!/usr/bin/env python3
"""Prepare the independently versioned Forge Platform Installer source.

This is deliberately separate from ``advance_product_version.py``.  The
Forge Platform composition product and the native updater use different
release identities, tags, capabilities, and publication evidence.  The helper
only prepares an isolated source candidate; it never builds, signs, pushes,
tags, or publishes an installer.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from typing import Any


SCHEMA = "forge-platform.installer-version-operation/v1"
PRODUCT = "forge-platform-installer"
MANIFEST_PATH = "installer-version.json"
SWIFT_PROJECTION_PATH = "macos/ForgePlatformInstaller/Sources/ForgePlatformInstaller/ForgePlatformInstallerApp.swift"
OPERATIONS_DIRECTORY = ".installer-version-operations"
VERSION = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
OPERATION_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{7,127}$")
GIT_REVISION = re.compile(r"^[0-9a-f]{40}(?:[0-9a-f]{24})?$")
CAPABILITY = re.compile(r"^[a-z0-9][a-z0-9./_-]{0,127}$")
SWIFT_VERSION = re.compile(r'(static let currentVersion = try! InstallerVersion\(")([^"]+)("\))')


def _pairs(pairs: list[tuple[object, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if not isinstance(key, str) or key in result:
            raise ValueError("installer version JSON has duplicate or invalid keys")
        result[key] = value
    return result


def _manifest_path(root: Path) -> Path:
    return root.resolve() / MANIFEST_PATH


def _swift_path(root: Path) -> Path:
    return root.resolve() / SWIFT_PROJECTION_PATH


def _operation_path(root: Path, operation_id: str) -> Path:
    if OPERATION_ID.fullmatch(operation_id) is None:
        raise RuntimeError("operation ID must be 8-128 safe identifier characters")
    return root.resolve() / OPERATIONS_DIRECTORY / f"{operation_id}.json"


def _atomic_write(path: Path, content: str) -> None:
    mode = path.stat().st_mode if path.exists() else 0o644
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary_name, mode)
        os.replace(temporary_name, path)
    except BaseException:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass
        raise


def _head(root: Path) -> str:
    try:
        return subprocess.run(
            ["git", "-C", str(root), "rev-parse", "HEAD"],
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        ).stdout.strip()
    except (OSError, subprocess.CalledProcessError) as error:
        raise RuntimeError("installer version preparation requires a Git checkout with HEAD") from error


def _load_manifest(root: Path) -> dict[str, Any]:
    try:
        value = json.loads(_manifest_path(root).read_text(encoding="utf-8"), object_pairs_hook=_pairs)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        raise RuntimeError("installer version manifest is unreadable") from error
    if not isinstance(value, dict) or set(value) != {"schema", "product", "version", "channel", "capabilities"}:
        raise RuntimeError("installer version manifest fields are invalid")
    if value["schema"] != "forge-platform.installer-version/v1" or value["product"] != PRODUCT:
        raise RuntimeError("installer version manifest identity is invalid")
    if not isinstance(value["version"], str) or VERSION.fullmatch(value["version"]) is None:
        raise RuntimeError("installer version must be stable X.Y.Z")
    if not isinstance(value["channel"], str) or value["channel"] not in {"stable", "candidate"}:
        raise RuntimeError("installer version channel is unsupported")
    capabilities = value["capabilities"]
    if not isinstance(capabilities, list) or not capabilities:
        raise RuntimeError("installer version capabilities must be a non-empty list")
    if any(not isinstance(capability, str) or CAPABILITY.fullmatch(capability) is None for capability in capabilities):
        raise RuntimeError("installer version capability identity is invalid")
    if len(capabilities) != len(set(capabilities)):
        raise RuntimeError("installer version capabilities must be unique")
    return value


def _swift_version(root: Path) -> tuple[Path, str, re.Match[str]]:
    path = _swift_path(root)
    try:
        content = path.read_text(encoding="utf-8")
    except OSError as error:
        raise RuntimeError("native installer version projection is unreadable") from error
    matches = list(SWIFT_VERSION.finditer(content))
    if len(matches) != 1:
        raise RuntimeError("native installer must contain exactly one currentVersion projection")
    return path, content, matches[0]


def _target(actual: str, bump: str | None, exact: str | None) -> str:
    if (bump is None) == (exact is None):
        raise RuntimeError("provide exactly one requested bump or exact target version")
    if exact is not None:
        if VERSION.fullmatch(exact) is None:
            raise RuntimeError("the requested installer version must be stable X.Y.Z")
        return exact
    major, minor, patch = (int(part) for part in actual.split("."))
    if bump == "none":
        return actual
    if bump == "patch":
        return f"{major}.{minor}.{patch + 1}"
    if bump == "minor":
        return f"{major}.{minor + 1}.0"
    raise RuntimeError("major requires explicit installer release authority")


def _operation(
    operation_id: str,
    lineage: str,
    expected_head: str,
    baseline: str,
    bump: str | None,
    exact: str | None,
    target: str,
) -> dict[str, Any]:
    if not lineage.strip():
        raise RuntimeError("event lineage is required")
    if GIT_REVISION.fullmatch(expected_head) is None:
        raise RuntimeError("expected source revision must be a full lowercase Git revision")
    if not isinstance(baseline, str) or VERSION.fullmatch(baseline) is None:
        raise RuntimeError("installer version operation baseline is invalid")
    if not isinstance(target, str) or VERSION.fullmatch(target) is None:
        raise RuntimeError("installer version operation target is invalid")
    release_class = "EXACT" if exact is not None else {"none": "NO_BUMP", "patch": "PATCH", "minor": "MINOR"}.get(bump)
    if release_class is None:
        raise RuntimeError("installer version release classification is unsupported")
    return {
        "schema": SCHEMA,
        "operation_id": operation_id,
        "product": PRODUCT,
        "policy_revision": "forge-platform-installer-version-v1",
        "event_lineage": lineage,
        "expected_source_revision": expected_head,
        "baseline_version": baseline,
        "requested_bump": bump,
        "requested_exact_version": exact,
        "target_version": target,
        "release_class": release_class,
        "allowed_projection_paths": [MANIFEST_PATH, SWIFT_PROJECTION_PATH],
    }


def _same(existing: dict[str, Any], requested: dict[str, Any]) -> bool:
    return all(existing.get(key) == value for key, value in requested.items())


def _load_operation(root: Path, operation_id: str) -> dict[str, Any] | None:
    path = _operation_path(root, operation_id)
    if not path.exists():
        return None
    try:
        existing = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=_pairs)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        raise RuntimeError("installer version operation is unreadable") from error
    if not isinstance(existing, dict):
        raise RuntimeError("installer version operation is invalid")
    return existing


def plan(
    root: Path,
    operation_id: str,
    lineage: str,
    expected_head: str,
    bump: str | None,
    exact: str | None,
) -> dict[str, Any]:
    manifest = _load_manifest(root)
    existing = _load_operation(root, operation_id)
    if existing is None:
        requested = _operation(
            operation_id,
            lineage,
            expected_head,
            manifest["version"],
            bump,
            exact,
            _target(manifest["version"], bump, exact),
        )
        return requested
    requested = _operation(
        operation_id,
        lineage,
        expected_head,
        existing.get("baseline_version"),
        bump,
        exact,
        existing.get("target_version"),
    )
    if not _same(existing, requested):
        raise RuntimeError("operation ID conflict: existing installer version operation has different input")
    return existing


def apply(
    root: Path,
    operation_id: str,
    lineage: str,
    expected_head: str,
    bump: str | None,
    exact: str | None,
) -> dict[str, Any]:
    root = root.resolve()
    manifest_path = _manifest_path(root)
    manifest = _load_manifest(root)
    swift_path, swift, match = _swift_version(root)
    path = _operation_path(root, operation_id)
    operation = _load_operation(root, operation_id)
    if operation is not None:
        requested = _operation(
            operation_id,
            lineage,
            expected_head,
            operation.get("baseline_version"),
            bump,
            exact,
            operation.get("target_version"),
        )
        if not _same(operation, requested):
            raise RuntimeError("operation ID conflict: existing installer version operation has different input")
        target = operation["target_version"]
        if manifest["version"] not in {operation["baseline_version"], target}:
            raise RuntimeError("installer version recovery conflict: source is neither baseline nor target")
    else:
        if match.group(2) != manifest["version"]:
            raise RuntimeError("installer source version and native projection differ before preparation")
        if _head(root) != expected_head:
            raise RuntimeError("stale source head: refresh and requalify the installer version candidate")
        target = _target(manifest["version"], bump, exact)
        operation = _operation(operation_id, lineage, expected_head, manifest["version"], bump, exact, target)
        operation["state"] = "PREPARED"
        operation["manifest_sha256_before"] = hashlib.sha256(manifest_path.read_bytes()).hexdigest()
        operation["swift_sha256_before"] = hashlib.sha256(swift_path.read_bytes()).hexdigest()
        path.parent.mkdir(mode=0o755, exist_ok=True)
        _atomic_write(path, json.dumps(operation, indent=2, sort_keys=True) + "\n")
    if manifest["version"] != target:
        manifest["version"] = target
        _atomic_write(manifest_path, json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    if match.group(2) != target:
        updated_swift, replacements = SWIFT_VERSION.subn(rf"\g<1>{target}\g<3>", swift)
        if replacements != 1:
            raise RuntimeError("native installer version projection could not be updated safely")
        _atomic_write(swift_path, updated_swift)
    operation["state"] = "APPLIED"
    operation["manifest_sha256_after"] = hashlib.sha256(manifest_path.read_bytes()).hexdigest()
    operation["swift_sha256_after"] = hashlib.sha256(swift_path.read_bytes()).hexdigest()
    _atomic_write(path, json.dumps(operation, indent=2, sort_keys=True) + "\n")
    return operation


def verify_operation(root: Path, candidate_head: str) -> None:
    root = root.resolve()
    if _head(root) != candidate_head:
        raise RuntimeError("candidate head mismatch: installer version qualification needs the exact candidate SHA")
    operation_paths = sorted((root / OPERATIONS_DIRECTORY).glob("*.json")) if (root / OPERATIONS_DIRECTORY).exists() else []
    if not operation_paths:
        print("INSTALLER_VERSION_OPERATION=NOT_APPLICABLE no installer version-preparation receipt")
        return
    if len(operation_paths) != 1:
        raise RuntimeError("installer version candidate must contain exactly one operation receipt")
    try:
        operation = json.loads(operation_paths[0].read_text(encoding="utf-8"), object_pairs_hook=_pairs)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        raise RuntimeError("installer version operation is unreadable") from error
    if not isinstance(operation, dict) or operation.get("state") != "APPLIED":
        raise RuntimeError("installer version operation is not applied")
    required = {
        "schema", "operation_id", "product", "policy_revision", "event_lineage", "expected_source_revision",
        "baseline_version", "target_version", "allowed_projection_paths", "manifest_sha256_before",
        "manifest_sha256_after", "swift_sha256_before", "swift_sha256_after",
    }
    if not required <= set(operation):
        raise RuntimeError("installer version operation is incomplete")
    if (
        operation["schema"] != SCHEMA
        or operation["product"] != PRODUCT
        or operation["policy_revision"] != "forge-platform-installer-version-v1"
        or operation["allowed_projection_paths"] != [MANIFEST_PATH, SWIFT_PROJECTION_PATH]
    ):
        raise RuntimeError("installer version operation has invalid identity or projections")
    manifest = _load_manifest(root)
    _, _, match = _swift_version(root)
    if manifest["version"] != operation["target_version"] or match.group(2) != operation["target_version"]:
        raise RuntimeError("installer version operation target does not match every projection")
    if hashlib.sha256(_manifest_path(root).read_bytes()).hexdigest() != operation["manifest_sha256_after"]:
        raise RuntimeError("installer version manifest digest does not match the operation")
    if hashlib.sha256(_swift_path(root).read_bytes()).hexdigest() != operation["swift_sha256_after"]:
        raise RuntimeError("installer version Swift projection digest does not match the operation")
    try:
        parent = subprocess.run(
            ["git", "-C", str(root), "rev-parse", f"{candidate_head}^"],
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        ).stdout.strip()
        changed = subprocess.run(
            ["git", "-C", str(root), "diff", "--name-only", parent, candidate_head],
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        ).stdout.splitlines()
    except (OSError, subprocess.CalledProcessError) as error:
        raise RuntimeError("installer version candidate must have an inspectable single parent") from error
    if parent != operation["expected_source_revision"]:
        raise RuntimeError("installer version candidate parent differs from its expected source revision")
    expected = {f"{OPERATIONS_DIRECTORY}/{operation['operation_id']}.json"}
    if operation["baseline_version"] != operation["target_version"]:
        expected.update({MANIFEST_PATH, SWIFT_PROJECTION_PATH})
    if set(changed) != expected:
        raise RuntimeError("installer version candidate changes paths outside its declared projections")
    print(f"INSTALLER_VERSION_OPERATION=PASS operation_id={operation['operation_id']} candidate={candidate_head}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", type=Path, default=Path.cwd())
    parser.add_argument("--operation-id")
    parser.add_argument("--event-lineage")
    parser.add_argument("--expected-head")
    parser.add_argument("--bump", choices=("none", "patch", "minor"))
    parser.add_argument("--set-version")
    parser.add_argument("--candidate-head")
    parser.add_argument("--plan", action="store_true")
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--verify-operation", action="store_true")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args(argv)
    if sum((args.plan, args.apply, args.verify_operation, args.check)) != 1:
        parser.error("provide exactly one mode")
    try:
        if args.check:
            manifest = _load_manifest(args.source_root)
            _, _, match = _swift_version(args.source_root)
            if match.group(2) != manifest["version"]:
                raise RuntimeError("native installer version projection does not match installer-version.json")
            print(f"INSTALLER_VERSION=PASS version={manifest['version']} channel={manifest['channel']}")
            return 0
        if args.verify_operation:
            if not args.candidate_head:
                parser.error("--verify-operation requires --candidate-head")
            verify_operation(args.source_root, args.candidate_head)
            return 0
        required = (args.operation_id, args.event_lineage, args.expected_head)
        if any(not isinstance(value, str) or not value for value in required):
            parser.error("--plan/--apply require --operation-id, --event-lineage, and --expected-head")
        if args.plan:
            print(json.dumps(plan(args.source_root, args.operation_id, args.event_lineage, args.expected_head, args.bump, args.set_version), indent=2, sort_keys=True))
            return 0
        print(json.dumps(apply(args.source_root, args.operation_id, args.event_lineage, args.expected_head, args.bump, args.set_version), indent=2, sort_keys=True))
        return 0
    except RuntimeError as error:
        print(f"INSTALLER_VERSION=FAIL reason={error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
