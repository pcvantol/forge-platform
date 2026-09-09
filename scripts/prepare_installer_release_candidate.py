#!/usr/bin/env python3
"""Persist exact unsigned installer candidate evidence before qualification.

This command is intentionally a release-preparation boundary, not a signer,
notarizer, publisher, downloader, or product installer.  It validates the
already-built candidate manifest and exact local archive bytes against a
reviewed public installer identity, then persists one immutable ``PREPARED``
record under the caller's operation ID.  A retry may reproduce precisely the
same candidate only; changed bytes or provenance fail closed.
"""

from __future__ import annotations

import argparse
from dataclasses import asdict
from hashlib import sha256
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
from typing import Mapping


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from forge_platform.installer_release_operation import (  # noqa: E402
    INSTALLER_RELEASE_POLICY_REVISION,
    InstallerPreparationEvidence,
    InstallerReleaseOperationError,
    InstallerReleaseOperationStore,
    InstallerReleasePreparation,
)
from validate_installer_release_identity import load_identity  # noqa: E402


_ARCHITECTURES = frozenset({"arm64", "x86_64"})
_CANDIDATE_SCHEMA = "forge-platform.installer-candidate/v1"
_CANDIDATE_PRODUCT = "forge-platform-installer"
_CANDIDATE_PACKAGING = "UNSIGNED_APP_CANDIDATE"
_MAXIMUM_MANIFEST_BYTES = 128 * 1024
_MAXIMUM_ARCHIVE_BYTES = 8 * 1024 * 1024 * 1024


def _pairs(pairs: list[tuple[object, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if not isinstance(key, str) or key in result:
            raise ValueError("candidate JSON contains duplicate or invalid keys")
        result[key] = value
    return result


def _reject_constant(value: str) -> None:
    raise ValueError(f"candidate JSON contains unsupported constant {value}")


def _read_regular_file(value: str, *, label: str, maximum_bytes: int) -> tuple[Path, bytes]:
    """Read a bounded immutable input without accepting a selected symlink."""

    supplied = Path(value).expanduser()
    if supplied.is_symlink():
        raise ValueError(f"{label} must not be selected through a symlink")
    try:
        resolved = supplied.resolve(strict=True)
    except FileNotFoundError as error:
        raise ValueError(f"{label} does not exist") from error
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(resolved, flags)
    except OSError as error:
        raise ValueError(f"{label} cannot be opened safely") from error
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode):
            raise ValueError(f"{label} must be a regular file")
        if before.st_size < 1 or before.st_size > maximum_bytes:
            raise ValueError(f"{label} has an unsupported size")
        with os.fdopen(descriptor, "rb", closefd=False) as stream:
            contents = stream.read(maximum_bytes + 1)
        after = os.fstat(descriptor)
        if (
            len(contents) > maximum_bytes
            or before.st_dev != after.st_dev
            or before.st_ino != after.st_ino
            or before.st_size != after.st_size
            or before.st_mtime_ns != after.st_mtime_ns
        ):
            raise ValueError(f"{label} changed while it was being read")
        return resolved, contents
    finally:
        os.close(descriptor)


def _digest(contents: bytes) -> str:
    return "sha256:" + sha256(contents).hexdigest()


def _candidate_manifest(value: str) -> tuple[Path, bytes, Mapping[str, object]]:
    path, raw = _read_regular_file(value, label="installer candidate manifest", maximum_bytes=_MAXIMUM_MANIFEST_BYTES)
    try:
        parsed = json.loads(
            raw.decode("utf-8"),
            object_pairs_hook=_pairs,
            parse_constant=_reject_constant,
        )
    except (UnicodeDecodeError, ValueError, json.JSONDecodeError) as error:
        raise ValueError("installer candidate manifest is not strict UTF-8 JSON") from error
    expected = {
        "schema", "product", "source_revision", "version", "channel", "release_sequence", "policy_revision",
        "provenance_sha256", "release_trust_configuration_sha256",
        "bundle_identifier", "capabilities", "archives",
    }
    if not isinstance(parsed, dict) or set(parsed) != expected:
        raise ValueError("installer candidate manifest has unsupported or missing fields")
    return path, raw, parsed


def _reviewed_identity_path(value: Path) -> Path:
    """Require an explicit regular policy file rather than a redirected path."""

    supplied = Path(value).expanduser()
    if supplied.is_symlink():
        raise ValueError("reviewed installer release identity must not be selected through a symlink")
    try:
        resolved = supplied.resolve(strict=True)
        metadata = resolved.stat()
    except OSError as error:
        raise ValueError("reviewed installer release identity is unavailable") from error
    if not stat.S_ISREG(metadata.st_mode):
        raise ValueError("reviewed installer release identity must be a regular file")
    return resolved


def _archive_digest(value: str, *, architecture: str) -> tuple[Path, str]:
    """Hash one immutable archive in bounded streaming reads."""

    supplied = Path(value).expanduser()
    label = f"{architecture} candidate archive"
    if supplied.is_symlink():
        raise ValueError(f"{label} must not be selected through a symlink")
    try:
        resolved = supplied.resolve(strict=True)
    except FileNotFoundError as error:
        raise ValueError(f"{label} does not exist") from error
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(resolved, flags)
    except OSError as error:
        raise ValueError(f"{label} cannot be opened safely") from error
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_size < 1 or before.st_size > _MAXIMUM_ARCHIVE_BYTES:
            raise ValueError(f"{label} has an unsupported size")
        digest = sha256()
        with os.fdopen(descriptor, "rb", closefd=False) as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(block)
        after = os.fstat(descriptor)
        if (
            before.st_dev != after.st_dev
            or before.st_ino != after.st_ino
            or before.st_size != after.st_size
            or before.st_mtime_ns != after.st_mtime_ns
        ):
            raise ValueError(f"{label} changed while it was being read")
        return resolved, "sha256:" + digest.hexdigest()
    finally:
        os.close(descriptor)


def _archive_arguments(values: list[str]) -> dict[str, tuple[Path, str]]:
    result: dict[str, tuple[Path, str]] = {}
    for value in values:
        architecture, separator, raw_path = value.partition("=")
        if not separator or architecture not in _ARCHITECTURES or not raw_path:
            raise ValueError("archive must use a supported architecture=path value")
        if architecture in result:
            raise ValueError("archive architecture was supplied more than once")
        result[architecture] = _archive_digest(raw_path, architecture=architecture)
    if not result:
        raise ValueError("at least one candidate archive is required")
    return dict(sorted(result.items()))


def _require_string(value: object, label: str) -> str:
    if not isinstance(value, str) or not value:
        raise ValueError(f"installer candidate {label} is invalid")
    return value


def _validate_candidate(
    *,
    manifest: Mapping[str, object],
    archive_inputs: Mapping[str, tuple[Path, str]],
    source_revision: str,
    installer_version: str,
    channel: str,
    release_sequence: int,
    policy_revision: str,
    provenance_sha256: str,
    release_trust_configuration_sha256: str,
    bundle_identifier: str,
    asset_names: Mapping[str, str],
) -> tuple[tuple[str, ...], dict[str, str]]:
    expected_fields = {
        "schema": _CANDIDATE_SCHEMA,
        "product": _CANDIDATE_PRODUCT,
        "source_revision": source_revision,
        "version": installer_version,
        "channel": channel,
        "release_sequence": release_sequence,
        "policy_revision": policy_revision,
        "provenance_sha256": provenance_sha256,
        "release_trust_configuration_sha256": release_trust_configuration_sha256,
        "bundle_identifier": bundle_identifier,
    }
    for field, expected in expected_fields.items():
        if manifest[field] != expected:
            raise ValueError(f"installer candidate manifest {field} does not bind the requested release context")
    capabilities = manifest["capabilities"]
    if not isinstance(capabilities, list) or not capabilities or any(not isinstance(item, str) for item in capabilities):
        raise ValueError("installer candidate manifest capabilities are invalid")
    if len(set(capabilities)) != len(capabilities):
        raise ValueError("installer candidate manifest capabilities must be unique")
    if capabilities != sorted(capabilities):
        raise ValueError("installer candidate manifest capabilities must be strictly sorted")
    archive_manifest = manifest["archives"]
    if not isinstance(archive_manifest, dict) or set(archive_manifest) != set(archive_inputs):
        raise ValueError("installer candidate manifest archives do not exactly match supplied archives")
    archive_digests: dict[str, str] = {}
    for architecture, (path, actual_digest) in archive_inputs.items():
        entry = archive_manifest[architecture]
        if not isinstance(entry, dict) or set(entry) != {"name", "digest", "packaging"}:
            raise ValueError("installer candidate archive entry has unsupported or missing fields")
        expected_name = asset_names[architecture]
        if entry["name"] != expected_name or path.name != expected_name:
            raise ValueError("installer candidate archive name does not bind the reviewed asset identity")
        if entry["packaging"] != _CANDIDATE_PACKAGING:
            raise ValueError("installer candidate archive packaging is unsupported")
        if entry["digest"] != actual_digest:
            raise ValueError("installer candidate archive digest does not bind the exact archive bytes")
        archive_digests[architecture] = actual_digest
    return tuple(capabilities), dict(sorted(archive_digests.items()))


def _atomic_output(path: Path, preparation: InstallerReleasePreparation) -> None:
    """Write a resumable public evidence copy without replacing other bytes."""

    supplied = Path(path).expanduser()
    if supplied.is_symlink():
        raise ValueError("preparation output must not be selected through a symlink")
    output = supplied.resolve(strict=False)
    if output.suffix != ".json":
        raise ValueError("preparation output must have a .json filename")
    encoded = (json.dumps(asdict(preparation), sort_keys=True, separators=(",", ":"), allow_nan=False) + "\n").encode("utf-8")
    if output.exists():
        _, existing = _read_regular_file(str(output), label="preparation output", maximum_bytes=_MAXIMUM_MANIFEST_BYTES)
        try:
            parsed = json.loads(existing.decode("utf-8"), object_pairs_hook=_pairs, parse_constant=_reject_constant)
            restored = InstallerReleasePreparation.parse(parsed)
        except (UnicodeDecodeError, ValueError, json.JSONDecodeError, InstallerReleaseOperationError) as error:
            raise ValueError("preparation output is not an exact existing preparation record") from error
        if restored != preparation:
            raise ValueError("preparation output already binds different candidate bytes or provenance")
        return
    output.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{output.name}.", dir=output.parent)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(encoded)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, 0o600)
        try:
            os.link(temporary, output, follow_symlinks=False)
        except FileExistsError:
            # A concurrent exact retry must re-read rather than overwrite.
            Path(temporary).unlink(missing_ok=True)
            _atomic_output(output, preparation)
            return
        Path(temporary).unlink(missing_ok=True)
        directory = os.open(output.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    except BaseException:
        Path(temporary).unlink(missing_ok=True)
        raise


def prepare(
    *,
    candidate_manifest_path: str,
    archive_values: list[str],
    source_revision: str,
    operation_id: str,
    installer_version: str,
    channel: str,
    release_sequence: int,
    policy_revision: str,
    provenance_sha256: str,
    release_identity_path: Path,
    journal_root: Path,
    output: Path,
    preparation_receipt_reference: str,
) -> InstallerReleasePreparation:
    if policy_revision != INSTALLER_RELEASE_POLICY_REVISION:
        raise ValueError("requested policy revision is not the active installer release policy")
    identity = load_identity(require_ready=True, path=_reviewed_identity_path(release_identity_path))
    if identity is None:
        raise ValueError("reviewed installer release identity is required")
    _, manifest_raw, manifest = _candidate_manifest(candidate_manifest_path)
    archive_inputs = _archive_arguments(archive_values)
    capabilities, archive_digests = _validate_candidate(
        manifest=manifest,
        archive_inputs=archive_inputs,
        source_revision=source_revision,
        installer_version=installer_version,
        channel=channel,
        release_sequence=release_sequence,
        policy_revision=policy_revision,
        provenance_sha256=provenance_sha256,
        release_trust_configuration_sha256=identity.release_trust_configuration_sha256,
        bundle_identifier=identity.bundle_identifier,
        asset_names={architecture: identity.asset_name(architecture) for architecture in archive_inputs},
    )
    preparation = InstallerReleasePreparation(
        operation_id=operation_id,
        installer_version=installer_version,
        channel=channel,
        release_sequence=release_sequence,
        source_revision=source_revision,
        policy_revision=policy_revision,
        provenance_sha256=provenance_sha256,
        release_identity=identity,
        capabilities=capabilities,
        preparation=InstallerPreparationEvidence(
            candidate_manifest_digest=_digest(manifest_raw),
            candidate_archives=archive_digests,
            preparation_receipt_reference=preparation_receipt_reference,
        ),
    )
    store = InstallerReleaseOperationStore(journal_root)
    store.acquire(operation_id)
    try:
        prepared = store.prepare_candidate(preparation)
    finally:
        store.release(operation_id)
    _atomic_output(output, prepared)
    return prepared


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate-manifest", required=True)
    parser.add_argument("--archive", action="append", default=[])
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--operation-id", required=True)
    parser.add_argument("--installer-version", required=True)
    parser.add_argument("--channel", required=True)
    parser.add_argument("--release-sequence", required=True, type=int)
    parser.add_argument("--policy-revision", required=True)
    parser.add_argument("--provenance-sha256", required=True)
    parser.add_argument("--release-identity", required=True)
    parser.add_argument("--journal-root", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--preparation-receipt-reference", required=True)
    args = parser.parse_args(argv)
    try:
        prepared = prepare(
            candidate_manifest_path=args.candidate_manifest,
            archive_values=args.archive,
            source_revision=args.source_sha,
            operation_id=args.operation_id,
            installer_version=args.installer_version,
            channel=args.channel,
            release_sequence=args.release_sequence,
            policy_revision=args.policy_revision,
            provenance_sha256=args.provenance_sha256,
            release_identity_path=Path(args.release_identity),
            journal_root=Path(args.journal_root),
            output=Path(args.output),
            preparation_receipt_reference=args.preparation_receipt_reference,
        )
    except (OSError, RuntimeError, ValueError, InstallerReleaseOperationError) as error:
        print(f"INSTALLER_RELEASE_PREPARATION=FAIL reason={error}", file=sys.stderr)
        return 1
    print(
        "INSTALLER_RELEASE_PREPARATION=PREPARED"
        f" operation_id={prepared.operation_id}"
        f" version={prepared.installer_version}"
        f" candidate_manifest_digest={prepared.preparation.candidate_manifest_digest}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
