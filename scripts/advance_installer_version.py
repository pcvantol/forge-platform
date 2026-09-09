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
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import stat
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
        directory_descriptor = os.open(path.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            os.fsync(directory_descriptor)
        finally:
            os.close(directory_descriptor)
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


def _require_clean_worktree(root: Path) -> None:
    try:
        status = subprocess.run(
            ["git", "-C", str(root), "status", "--porcelain", "--untracked-files=all"],
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        ).stdout
    except (OSError, subprocess.CalledProcessError) as error:
        raise RuntimeError("installer version qualification requires an inspectable Git worktree") from error
    if status:
        raise RuntimeError("installer version qualification requires a clean worktree")


def _git_common_directory(root: Path) -> Path:
    try:
        value = subprocess.run(
            ["git", "-C", str(root), "rev-parse", "--git-common-dir"],
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        ).stdout.strip()
    except (OSError, subprocess.CalledProcessError) as error:
        raise RuntimeError("installer version preparation requires a Git common directory") from error
    if not value:
        raise RuntimeError("installer version preparation Git common directory is invalid")
    directory = Path(value)
    if not directory.is_absolute():
        directory = root / directory
    try:
        return directory.resolve(strict=True)
    except OSError as error:
        raise RuntimeError("installer version preparation Git common directory is unavailable") from error


@contextmanager
def _preparation_lock(root: Path):
    """Serialize version preparation across worktrees of the same checkout.

    The persistent lock inode lives in Git's common directory, never in the
    candidate tree. ``flock`` releases it if a preparer crashes, so a later
    invocation can resume the same operation without deleting a stale marker.
    """

    lock_path = _git_common_directory(root) / "forge-platform-installer-version-preparation.lock"
    flags = os.O_RDWR | os.O_CREAT | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(lock_path, flags, 0o600)
    except OSError as error:
        raise RuntimeError("installer version preparation lock is unavailable") from error
    try:
        details = os.fstat(descriptor)
        if (
            not stat.S_ISREG(details.st_mode)
            or details.st_uid != os.geteuid()
            or details.st_nlink != 1
            or details.st_mode & 0o077
        ):
            raise RuntimeError("installer version preparation lock is unsafe")
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise RuntimeError("another installer version preparation owns the lock") from error
        yield
    finally:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
        finally:
            os.close(descriptor)


def _blob_bytes(root: Path, revision: str, relative_path: str) -> bytes:
    try:
        return subprocess.run(
            ["git", "-C", str(root), "show", f"{revision}:{relative_path}"],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        ).stdout
    except (OSError, subprocess.CalledProcessError) as error:
        raise RuntimeError(f"installer version candidate parent lacks {relative_path}") from error


def _blob_sha256(root: Path, revision: str, relative_path: str) -> str:
    return hashlib.sha256(_blob_bytes(root, revision, relative_path)).hexdigest()


def _reject_constant(value: str) -> None:
    raise ValueError(f"non-finite JSON value is not permitted: {value}")


def _validate_manifest(value: object, label: str) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != {"schema", "product", "version", "channel", "capabilities"}:
        raise RuntimeError(f"{label} fields are invalid")
    if value["schema"] != "forge-platform.installer-version/v1" or value["product"] != PRODUCT:
        raise RuntimeError(f"{label} identity is invalid")
    if not isinstance(value["version"], str) or VERSION.fullmatch(value["version"]) is None:
        raise RuntimeError("installer version must be stable X.Y.Z")
    if not isinstance(value["channel"], str) or value["channel"] not in {"stable", "candidate"}:
        raise RuntimeError(f"{label} channel is unsupported")
    capabilities = value["capabilities"]
    if not isinstance(capabilities, list) or not capabilities:
        raise RuntimeError(f"{label} capabilities must be a non-empty list")
    if any(not isinstance(capability, str) or CAPABILITY.fullmatch(capability) is None for capability in capabilities):
        raise RuntimeError(f"{label} capability identity is invalid")
    if len(capabilities) != len(set(capabilities)):
        raise RuntimeError(f"{label} capabilities must be unique")
    return value


def _manifest_from_bytes(raw: bytes, label: str) -> dict[str, Any]:
    try:
        value = json.loads(
            raw.decode("utf-8"),
            object_pairs_hook=_pairs,
            parse_constant=_reject_constant,
        )
    except (UnicodeDecodeError, ValueError, json.JSONDecodeError) as error:
        raise RuntimeError(f"{label} is unreadable") from error
    return _validate_manifest(value, label)


def _load_manifest(root: Path) -> dict[str, Any]:
    try:
        return _manifest_from_bytes(_manifest_path(root).read_bytes(), "installer version manifest")
    except OSError as error:
        raise RuntimeError("installer version manifest is unreadable") from error


def _swift_version_match(content: str, label: str) -> re.Match[str]:
    matches = list(SWIFT_VERSION.finditer(content))
    if len(matches) != 1:
        raise RuntimeError(f"{label} must contain exactly one currentVersion projection")
    return matches[0]


def _swift_version(root: Path) -> tuple[Path, str, re.Match[str]]:
    path = _swift_path(root)
    try:
        content = path.read_text(encoding="utf-8")
    except OSError as error:
        raise RuntimeError("native installer version projection is unreadable") from error
    return path, content, _swift_version_match(content, "native installer")


def _target(actual: str, bump: str | None, exact: str | None) -> str:
    if (bump is None) == (exact is None):
        raise RuntimeError("provide exactly one requested bump or exact target version")
    if exact is not None:
        if VERSION.fullmatch(exact) is None:
            raise RuntimeError("the requested installer version must be stable X.Y.Z")
        if _version_parts(exact) <= _version_parts(actual):
            raise RuntimeError("an exact installer release version must advance the canonical version")
        return exact
    major, minor, patch = (int(part) for part in actual.split("."))
    if bump == "none":
        return actual
    if bump == "patch":
        return f"{major}.{minor}.{patch + 1}"
    if bump == "minor":
        return f"{major}.{minor + 1}.0"
    raise RuntimeError("major requires explicit installer release authority")


def _version_parts(value: str) -> tuple[int, int, int]:
    if VERSION.fullmatch(value) is None:
        raise RuntimeError("installer version must be stable X.Y.Z")
    major, minor, patch = value.split(".")
    return int(major), int(minor), int(patch)


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
    with _preparation_lock(root):
        return _apply_locked(root, operation_id, lineage, expected_head, bump, exact)


def _apply_locked(
    root: Path,
    operation_id: str,
    lineage: str,
    expected_head: str,
    bump: str | None,
    exact: str | None,
) -> dict[str, Any]:
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


def verify_operation(
    root: Path,
    candidate_head: str,
    *,
    require_operation: bool = False,
    require_version_advance: bool = False,
) -> None:
    if require_version_advance:
        require_operation = True
    root = root.resolve()
    if _head(root) != candidate_head:
        raise RuntimeError("candidate head mismatch: installer version qualification needs the exact candidate SHA")
    _require_clean_worktree(root)
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
    operation_prefix = f"{OPERATIONS_DIRECTORY}/"
    operation_changes = [
        path for path in changed
        if path.startswith(operation_prefix) and path.endswith(".json")
    ]
    if not operation_changes:
        if require_operation:
            raise RuntimeError("installer release qualification requires a version-preparation receipt in the candidate")
        print("INSTALLER_VERSION_OPERATION=NOT_APPLICABLE no installer version-preparation receipt changed by candidate")
        return
    if len(operation_changes) != 1:
        raise RuntimeError("installer version candidate must change exactly one version-preparation receipt")
    operation_relative_path = operation_changes[0]
    try:
        operation = json.loads(
            _blob_bytes(root, candidate_head, operation_relative_path).decode("utf-8"),
            object_pairs_hook=_pairs,
            parse_constant=_reject_constant,
        )
    except (UnicodeDecodeError, ValueError, json.JSONDecodeError, RuntimeError) as error:
        raise RuntimeError("installer version operation is unreadable") from error
    if not isinstance(operation, dict) or operation.get("state") != "APPLIED":
        raise RuntimeError("installer version operation is not applied")
    required = {
        "schema", "operation_id", "product", "policy_revision", "event_lineage", "expected_source_revision",
        "baseline_version", "requested_bump", "requested_exact_version", "target_version", "release_class",
        "allowed_projection_paths", "state", "manifest_sha256_before",
        "manifest_sha256_after", "swift_sha256_before", "swift_sha256_after",
    }
    if set(operation) != required:
        raise RuntimeError("installer version operation has unknown or missing fields")
    if (
        operation["schema"] != SCHEMA
        or operation["product"] != PRODUCT
        or operation["policy_revision"] != "forge-platform-installer-version-v1"
        or operation["allowed_projection_paths"] != [MANIFEST_PATH, SWIFT_PROJECTION_PATH]
    ):
        raise RuntimeError("installer version operation has invalid identity or projections")
    if (
        not isinstance(operation["operation_id"], str)
        or OPERATION_ID.fullmatch(operation["operation_id"]) is None
        or not isinstance(operation["event_lineage"], str)
        or not operation["event_lineage"].strip()
        or not isinstance(operation["expected_source_revision"], str)
        or GIT_REVISION.fullmatch(operation["expected_source_revision"]) is None
        or not isinstance(operation["baseline_version"], str)
        or VERSION.fullmatch(operation["baseline_version"]) is None
        or not isinstance(operation["target_version"], str)
        or VERSION.fullmatch(operation["target_version"]) is None
        or (operation["requested_bump"] is not None and (
            not isinstance(operation["requested_bump"], str)
            or operation["requested_bump"] not in {"none", "patch", "minor"}
        ))
        or (operation["requested_exact_version"] is not None and (
            not isinstance(operation["requested_exact_version"], str)
            or VERSION.fullmatch(operation["requested_exact_version"]) is None
        ))
    ):
        raise RuntimeError("installer version operation has invalid requested release semantics")
    try:
        expected_target = _target(
            operation["baseline_version"],
            operation["requested_bump"],
            operation["requested_exact_version"],
        )
    except RuntimeError as error:
        raise RuntimeError("installer version operation has invalid requested release semantics") from error
    expected_release_class = (
        "EXACT"
        if operation["requested_exact_version"] is not None
        else {"none": "NO_BUMP", "patch": "PATCH", "minor": "MINOR"}[operation["requested_bump"]]
    )
    if operation["target_version"] != expected_target or operation["release_class"] != expected_release_class:
        raise RuntimeError("installer version operation target or release class is inconsistent")
    expected_operation_path = f"{OPERATIONS_DIRECTORY}/{operation['operation_id']}.json"
    if operation_relative_path != expected_operation_path:
        raise RuntimeError("installer version operation receipt path does not bind its operation ID")
    if parent != operation["expected_source_revision"]:
        raise RuntimeError("installer version candidate parent differs from its expected source revision")
    if _blob_sha256(root, parent, MANIFEST_PATH) != operation["manifest_sha256_before"]:
        raise RuntimeError("installer version manifest before-digest does not match the candidate parent")
    if _blob_sha256(root, parent, SWIFT_PROJECTION_PATH) != operation["swift_sha256_before"]:
        raise RuntimeError("installer version Swift projection before-digest does not match the candidate parent")
    parent_manifest = _manifest_from_bytes(
        _blob_bytes(root, parent, MANIFEST_PATH),
        "installer version candidate parent manifest",
    )
    try:
        parent_swift = _blob_bytes(root, parent, SWIFT_PROJECTION_PATH).decode("utf-8")
    except UnicodeDecodeError as error:
        raise RuntimeError("installer version candidate parent Swift projection is unreadable") from error
    parent_match = _swift_version_match(parent_swift, "installer version candidate parent")
    if (
        parent_manifest["version"] != operation["baseline_version"]
        or parent_match.group(2) != operation["baseline_version"]
    ):
        raise RuntimeError("installer version operation baseline does not match every candidate-parent projection")
    manifest = _manifest_from_bytes(
        _blob_bytes(root, candidate_head, MANIFEST_PATH),
        "installer version candidate manifest",
    )
    try:
        candidate_swift = _blob_bytes(root, candidate_head, SWIFT_PROJECTION_PATH).decode("utf-8")
    except UnicodeDecodeError as error:
        raise RuntimeError("installer version candidate Swift projection is unreadable") from error
    match = _swift_version_match(candidate_swift, "installer version candidate")
    if manifest["version"] != operation["target_version"] or match.group(2) != operation["target_version"]:
        raise RuntimeError("installer version operation target does not match every projection")
    if hashlib.sha256(_blob_bytes(root, candidate_head, MANIFEST_PATH)).hexdigest() != operation["manifest_sha256_after"]:
        raise RuntimeError("installer version manifest digest does not match the operation")
    if hashlib.sha256(_blob_bytes(root, candidate_head, SWIFT_PROJECTION_PATH)).hexdigest() != operation["swift_sha256_after"]:
        raise RuntimeError("installer version Swift projection digest does not match the operation")
    expected = {f"{OPERATIONS_DIRECTORY}/{operation['operation_id']}.json"}
    if operation["baseline_version"] != operation["target_version"]:
        expected.update({MANIFEST_PATH, SWIFT_PROJECTION_PATH})
    if set(changed) != expected:
        raise RuntimeError("installer version candidate changes paths outside its declared projections")
    if require_version_advance and _version_parts(operation["target_version"]) <= _version_parts(operation["baseline_version"]):
        raise RuntimeError("installer release qualification requires an advancing version-preparation receipt")
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
    parser.add_argument("--require-operation", action="store_true")
    parser.add_argument("--require-version-advance", action="store_true")
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
            verify_operation(
                args.source_root,
                args.candidate_head,
                require_operation=args.require_operation,
                require_version_advance=args.require_version_advance,
            )
            return 0
        if args.require_operation or args.require_version_advance:
            parser.error("--require-operation/--require-version-advance are valid only with --verify-operation")
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
