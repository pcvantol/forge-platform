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
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import stat
import tempfile
from typing import Any


SCHEMA = "forge-platform.installer-version-operation/v2"
PRODUCT = "forge-platform-installer"
POLICY_REVISION = "forge-platform-installer-version-v2"
MANIFEST_PATH = "installer-version.json"
PACKAGER_PATH = "scripts/package_macos_installer_app.py"
VALIDATOR_PATH = "scripts/validate_installer_version.py"
INFO_PLIST_PATH = "Contents/Info.plist"
INFO_PLIST_PROJECTION_SCHEMA = "forge-platform-installer-info-plist-version-projection/v1"
OPERATIONS_DIRECTORY = ".installer-version-operations"
VERSION = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
OPERATION_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{7,127}$")
GIT_REVISION = re.compile(r"^[0-9a-f]{40}(?:[0-9a-f]{24})?$")
CAPABILITY = re.compile(r"^[a-z0-9][a-z0-9./_-]{0,127}$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
MAXIMUM_NATIVE_SIGNED_INTEGER = (1 << 63) - 1


def _pairs(pairs: list[tuple[object, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if not isinstance(key, str) or key in result:
            raise ValueError("installer version JSON has duplicate or invalid keys")
        result[key] = value
    return result


def _manifest_path(root: Path) -> Path:
    return root.resolve() / MANIFEST_PATH


def _packager_path(root: Path) -> Path:
    return root.resolve() / PACKAGER_PATH


def _validator_path(root: Path) -> Path:
    return root.resolve() / VALIDATOR_PATH


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
    if (
        not isinstance(value["version"], str)
        or VERSION.fullmatch(value["version"]) is None
        or any(int(component) > MAXIMUM_NATIVE_SIGNED_INTEGER for component in value["version"].split("."))
    ):
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


def _regular_source_file(path: Path, label: str) -> Path:
    if path.is_symlink() or not path.is_file():
        raise RuntimeError(f"{label} is unreadable")
    return path


def _source_sha256(root: Path, relative_path: str, label: str) -> str:
    path = _regular_source_file(root.resolve() / relative_path, label)
    try:
        return hashlib.sha256(path.read_bytes()).hexdigest()
    except OSError as error:
        raise RuntimeError(f"{label} is unreadable") from error


def _packager_sha256(root: Path) -> str:
    return _source_sha256(root, PACKAGER_PATH, "installer app packager")


def _load_version_validator(root: Path) -> object:
    """Load the candidate checkout's behavioural projection verifier.

    Version preparation binds the exact packager bytes separately. Loading the
    validation entrypoint from the candidate rather than this tool's own
    checkout proves the candidate's package-time `Info.plist` behaviour and
    keeps the sole source of truth in ``installer-version.json``.
    """

    validator_path = _regular_source_file(_validator_path(root), "installer version validator")
    module_name = "_forge_platform_installer_version_validator"
    specification = importlib.util.spec_from_file_location(module_name, validator_path)
    if specification is None or specification.loader is None:
        raise RuntimeError("installer version validator is unreadable")
    module = importlib.util.module_from_spec(specification)
    previous = sys.modules.get(module_name)
    previous_dont_write_bytecode = sys.dont_write_bytecode
    sys.modules[module_name] = module
    sys.dont_write_bytecode = True
    try:
        specification.loader.exec_module(module)
    except (ImportError, OSError, RuntimeError, SyntaxError) as error:
        raise RuntimeError("installer version validator is unreadable") from error
    finally:
        sys.dont_write_bytecode = previous_dont_write_bytecode
        if previous is None:
            sys.modules.pop(module_name, None)
        else:
            sys.modules[module_name] = previous
    return module


def _runtime_projection(root: Path, expected_version: str) -> dict[str, str]:
    validator = _load_version_validator(root)
    validate = getattr(validator, "validate", None)
    if not callable(validate):
        raise RuntimeError("installer version validator is unreadable")
    try:
        projection = validate(root, expected_version=expected_version)
    except RuntimeError as error:
        raise RuntimeError("installer runtime Info.plist projection is invalid") from error
    if (
        not isinstance(projection, dict)
        or set(projection) != {"schema", "info_plist_path", "short_version", "build_version", "sha256"}
        or projection["schema"] != INFO_PLIST_PROJECTION_SCHEMA
        or projection["info_plist_path"] != INFO_PLIST_PATH
        or projection["short_version"] != expected_version
        or projection["build_version"] != expected_version
        or not isinstance(projection["sha256"], str)
        or SHA256.fullmatch(projection["sha256"]) is None
    ):
        raise RuntimeError("installer runtime Info.plist projection is invalid")
    return projection


def _target(actual: str, bump: str | None, exact: str | None) -> str:
    if (bump is None) == (exact is None):
        raise RuntimeError("provide exactly one requested bump or exact target version")
    if exact is not None:
        try:
            requested_parts = _version_parts(exact)
        except RuntimeError as error:
            raise RuntimeError("the requested installer version must be stable X.Y.Z") from error
        if requested_parts <= _version_parts(actual):
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
    if (
        VERSION.fullmatch(value) is None
        or any(int(component) > MAXIMUM_NATIVE_SIGNED_INTEGER for component in value.split("."))
    ):
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
        "policy_revision": POLICY_REVISION,
        "event_lineage": lineage,
        "expected_source_revision": expected_head,
        "baseline_version": baseline,
        "requested_bump": bump,
        "requested_exact_version": exact,
        "target_version": target,
        "release_class": release_class,
        # The manifest remains the one and only mutable source projection. A
        # candidate binds the exact packager bytes and the resulting semantic
        # Info.plist projection as evidence, but must not version-source a
        # Swift literal or generated app bundle.
        "allowed_projection_paths": [MANIFEST_PATH],
        "runtime_projection_schema": INFO_PLIST_PROJECTION_SCHEMA,
        "runtime_info_plist_path": INFO_PLIST_PATH,
    }


def _same(existing: dict[str, Any], requested: dict[str, Any]) -> bool:
    return all(existing.get(key) == value for key, value in requested.items())


def _load_operation(root: Path, operation_id: str) -> dict[str, Any] | None:
    path = _operation_path(root, operation_id)
    if not path.exists():
        return None
    try:
        existing = json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=_pairs,
            parse_constant=_reject_constant,
        )
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
    _validate_recoverable_operation(existing, requested)
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
        _validate_recoverable_operation(operation, requested)
        target = operation["target_version"]
        if manifest["version"] not in {operation["baseline_version"], target}:
            raise RuntimeError("installer version recovery conflict: source is neither baseline nor target")
    else:
        if _head(root) != expected_head:
            raise RuntimeError("stale source head: refresh and requalify the installer version candidate")
        target = _target(manifest["version"], bump, exact)
        projection = _runtime_projection(root, manifest["version"])
        operation = _operation(operation_id, lineage, expected_head, manifest["version"], bump, exact, target)
        operation["state"] = "PREPARED"
        operation["manifest_sha256_before"] = hashlib.sha256(manifest_path.read_bytes()).hexdigest()
        operation["packager_sha256_before"] = _packager_sha256(root)
        operation["runtime_projection_sha256_before"] = projection["sha256"]
        path.parent.mkdir(mode=0o755, exist_ok=True)
        _atomic_write(path, json.dumps(operation, indent=2, sort_keys=True) + "\n")
    if _packager_sha256(root) != operation["packager_sha256_before"]:
        raise RuntimeError("installer version recovery conflict: app packager changed after preparation")
    if operation["state"] == "APPLIED":
        if (
            manifest["version"] != target
            or hashlib.sha256(manifest_path.read_bytes()).hexdigest() != operation["manifest_sha256_after"]
            or _packager_sha256(root) != operation["packager_sha256_after"]
            or _runtime_projection(root, target)["sha256"] != operation["runtime_projection_sha256_after"]
        ):
            raise RuntimeError("installer version recovery conflict: applied source no longer matches its exact evidence")
        return operation
    if manifest["version"] != target:
        manifest["version"] = target
        _atomic_write(manifest_path, json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    projection = _runtime_projection(root, target)
    operation["state"] = "APPLIED"
    operation["manifest_sha256_after"] = hashlib.sha256(manifest_path.read_bytes()).hexdigest()
    operation["packager_sha256_after"] = _packager_sha256(root)
    operation["runtime_projection_sha256_after"] = projection["sha256"]
    _atomic_write(path, json.dumps(operation, indent=2, sort_keys=True) + "\n")
    return operation


def _validate_recoverable_operation(operation: dict[str, Any], requested: dict[str, Any]) -> None:
    """Reject a partial/forged receipt before a retry mutates source again."""

    state = operation.get("state")
    prepared = set(requested) | {
        "state",
        "manifest_sha256_before",
        "packager_sha256_before",
        "runtime_projection_sha256_before",
    }
    applied = prepared | {
        "manifest_sha256_after",
        "packager_sha256_after",
        "runtime_projection_sha256_after",
    }
    required = prepared if state == "PREPARED" else applied if state == "APPLIED" else None
    if required is None or set(operation) != required:
        raise RuntimeError("installer version operation is invalid")
    if (
        operation["runtime_projection_schema"] != INFO_PLIST_PROJECTION_SCHEMA
        or operation["runtime_info_plist_path"] != INFO_PLIST_PATH
        or operation["allowed_projection_paths"] != [MANIFEST_PATH]
    ):
        raise RuntimeError("installer version operation has invalid runtime projection contract")
    evidence_fields = [
        "manifest_sha256_before",
        "packager_sha256_before",
        "runtime_projection_sha256_before",
    ]
    if state == "APPLIED":
        evidence_fields.extend(
            [
                "manifest_sha256_after",
                "packager_sha256_after",
                "runtime_projection_sha256_after",
            ]
        )
    if any(not isinstance(operation[field], str) or SHA256.fullmatch(operation[field]) is None for field in evidence_fields):
        raise RuntimeError("installer version operation has invalid exact projection evidence")


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
    try:
        requested = _operation(
            operation["operation_id"],
            operation["event_lineage"],
            operation["expected_source_revision"],
            operation["baseline_version"],
            operation["requested_bump"],
            operation["requested_exact_version"],
            operation["target_version"],
        )
    except (KeyError, TypeError, AttributeError, RuntimeError) as error:
        raise RuntimeError("installer version operation has invalid requested release semantics") from error
    if not _same(operation, requested):
        raise RuntimeError("installer version operation has invalid identity or requested release semantics")
    try:
        _validate_recoverable_operation(operation, requested)
    except RuntimeError as error:
        raise RuntimeError("installer version operation has invalid exact projection evidence") from error
    try:
        expected_target = _target(
            operation["baseline_version"],
            operation["requested_bump"],
            operation["requested_exact_version"],
        )
    except RuntimeError as error:
        raise RuntimeError("installer version operation has invalid requested release semantics") from error
    if operation["target_version"] != expected_target:
        raise RuntimeError("installer version operation target or release class is inconsistent")
    expected_operation_path = f"{OPERATIONS_DIRECTORY}/{operation['operation_id']}.json"
    if operation_relative_path != expected_operation_path:
        raise RuntimeError("installer version operation receipt path does not bind its operation ID")
    if parent != operation["expected_source_revision"]:
        raise RuntimeError("installer version candidate parent differs from its expected source revision")
    if _blob_sha256(root, parent, MANIFEST_PATH) != operation["manifest_sha256_before"]:
        raise RuntimeError("installer version manifest before-digest does not match the candidate parent")
    if _blob_sha256(root, parent, PACKAGER_PATH) != operation["packager_sha256_before"]:
        raise RuntimeError("installer app packager before-digest does not match the candidate parent")
    parent_manifest = _manifest_from_bytes(
        _blob_bytes(root, parent, MANIFEST_PATH),
        "installer version candidate parent manifest",
    )
    if parent_manifest["version"] != operation["baseline_version"]:
        raise RuntimeError("installer version operation baseline does not match the candidate-parent version authority")
    manifest = _manifest_from_bytes(
        _blob_bytes(root, candidate_head, MANIFEST_PATH),
        "installer version candidate manifest",
    )
    if manifest["version"] != operation["target_version"]:
        raise RuntimeError("installer version operation target does not match the version authority")
    if hashlib.sha256(_blob_bytes(root, candidate_head, MANIFEST_PATH)).hexdigest() != operation["manifest_sha256_after"]:
        raise RuntimeError("installer version manifest digest does not match the operation")
    if _blob_sha256(root, candidate_head, PACKAGER_PATH) != operation["packager_sha256_after"]:
        raise RuntimeError("installer app packager digest does not match the operation")
    if operation["packager_sha256_before"] != operation["packager_sha256_after"]:
        raise RuntimeError("installer version preparation must not change the app packager")
    if _runtime_projection(root, operation["target_version"])["sha256"] != operation["runtime_projection_sha256_after"]:
        raise RuntimeError("installer runtime Info.plist projection does not match the operation")
    expected = {f"{OPERATIONS_DIRECTORY}/{operation['operation_id']}.json"}
    if operation["baseline_version"] != operation["target_version"]:
        expected.add(MANIFEST_PATH)
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
            projection = _runtime_projection(args.source_root, manifest["version"])
            print(
                "INSTALLER_VERSION=PASS"
                f" version={manifest['version']}"
                f" channel={manifest['channel']}"
                f" info_plist_projection={projection['schema']}"
                f" info_plist_projection_sha256={projection['sha256']}"
            )
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
