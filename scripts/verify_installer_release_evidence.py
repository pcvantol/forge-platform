#!/usr/bin/env python3
"""Bind a signed-descriptor handoff to exact installer release evidence.

This is intentionally a structural evidence verifier, not a cryptographic
signer or trust-root implementation.  A protected signing/notarization stage
must verify descriptor signatures and Apple evidence before it supplies the
opaque qualification receipt retained by ``InstallerReleaseOperation``.  This
script then makes sure that the supplied descriptor, exact archive bytes,
candidate source, and durable operation describe the same release identity.
It never downloads, signs, notarizes, or publishes an artifact.
"""

from __future__ import annotations

import argparse
from datetime import datetime
from hashlib import sha256
import json
from pathlib import Path
import re
import sys
from typing import Mapping
from urllib.parse import urlparse


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from forge_platform.installer_release_operation import (  # noqa: E402
    InstallerReleaseOperation,
    InstallerReleaseOperationError,
)


_REVISION = re.compile(r"^[0-9a-f]{40,64}$")
_SEMVER = re.compile(r"^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)$")
_DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")
_CAPABILITY = re.compile(r"^[a-z0-9][a-z0-9./_-]{0,127}$")
_ARCHITECTURES = frozenset({"arm64", "x86_64"})
_CHANNELS = frozenset({"stable", "candidate"})


def _reject_constant(value: str) -> None:
    raise ValueError(f"non-finite JSON value is not permitted: {value}")


def _unique_pairs(pairs: list[tuple[object, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if not isinstance(key, str) or key in result:
            raise ValueError("JSON has duplicate or invalid object keys")
        result[key] = value
    return result


def _strict_object(raw_bytes: bytes, label: str) -> Mapping[str, object]:
    try:
        parsed = json.loads(
            raw_bytes.decode("utf-8"),
            object_pairs_hook=_unique_pairs,
            parse_constant=_reject_constant,
        )
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as error:
        raise ValueError(f"{label} is not strict JSON") from error
    if not isinstance(parsed, Mapping):
        raise ValueError(f"{label} root must be an object")
    return parsed


def _mapping(value: object, expected: frozenset[str], label: str) -> Mapping[str, object]:
    if not isinstance(value, Mapping) or set(value) != expected:
        raise ValueError(f"{label} fields are invalid")
    return value


def _string(value: object, label: str) -> str:
    if not isinstance(value, str) or not value:
        raise ValueError(f"{label} is required")
    return value


def _digest(value: object, label: str) -> str:
    result = _string(value, label)
    if _DIGEST.fullmatch(result) is None:
        raise ValueError(f"{label} must be a SHA-256 identity")
    return result


def _https_url(value: object, label: str) -> str:
    result = _string(value, label)
    parsed = urlparse(result)
    if parsed.scheme != "https" or not parsed.netloc or parsed.username or parsed.password:
        raise ValueError(f"{label} must be a credential-free HTTPS URL")
    return result


def _timestamp(value: object, label: str) -> datetime:
    result = _string(value, label)
    try:
        parsed = datetime.fromisoformat(result.replace("Z", "+00:00"))
    except ValueError as error:
        raise ValueError(f"{label} must be an RFC3339 timestamp") from error
    if parsed.tzinfo is None:
        raise ValueError(f"{label} must include a timezone")
    return parsed


def _archive_arguments(values: list[str]) -> dict[str, Path]:
    result: dict[str, Path] = {}
    for value in values:
        architecture, separator, raw_path = value.partition("=")
        if not separator or architecture not in _ARCHITECTURES or not raw_path:
            raise ValueError("archive must use a supported architecture=path identity")
        if architecture in result:
            raise ValueError("archive architecture was supplied more than once")
        candidate = Path(raw_path).expanduser().resolve(strict=True)
        if not candidate.is_file():
            raise ValueError("archive path must resolve to a regular file")
        result[architecture] = candidate
    if not result:
        raise ValueError("at least one archive is required")
    return dict(sorted(result.items()))


def _file_digest(path: Path) -> str:
    digest = sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return "sha256:" + digest.hexdigest()


def _descriptor_assets(
    descriptor: Mapping[str, object],
    operation: InstallerReleaseOperation,
) -> None:
    installer = _mapping(
        descriptor.get("installer"),
        frozenset({"version", "source_revision", "policy_revision", "capabilities", "assets"}),
        "installer descriptor",
    )
    if installer["version"] != operation.installer_version:
        raise ValueError("descriptor installer version does not bind the operation")
    if installer["source_revision"] != operation.source_revision:
        raise ValueError("descriptor source revision does not bind the operation")
    if installer["policy_revision"] != operation.policy_revision:
        raise ValueError("descriptor policy revision does not bind the operation")
    capabilities = installer["capabilities"]
    if not isinstance(capabilities, list) or not capabilities or any(
        not isinstance(item, str) or _CAPABILITY.fullmatch(item) is None for item in capabilities
    ):
        raise ValueError("descriptor capabilities are invalid")
    if len(capabilities) != len(set(capabilities)) or tuple(sorted(capabilities)) != operation.capabilities:
        raise ValueError("descriptor capabilities do not bind the operation")
    assets = installer["assets"]
    if not isinstance(assets, list) or not assets:
        raise ValueError("descriptor assets are required")
    observed: dict[str, str] = {}
    identity = operation.release_identity
    for asset in assets:
        value = _mapping(
            asset,
            frozenset({
                "operating_system", "architecture", "url", "digest", "bundle_identifier", "team_identifier",
                "notarization_evidence",
            }),
            "descriptor asset",
        )
        if value["operating_system"] != "macos":
            raise ValueError("descriptor asset operating system is invalid")
        architecture = _string(value["architecture"], "descriptor asset architecture")
        if architecture not in _ARCHITECTURES or architecture in observed:
            raise ValueError("descriptor asset architecture is invalid or duplicated")
        expected_url = (
            f"https://github.com/{identity.github_repository}/releases/download/"
            f"{operation.release_tag}/{identity.asset_name(architecture)}"
        )
        if _https_url(value["url"], "descriptor asset URL") != expected_url:
            raise ValueError("descriptor asset URL does not bind the canonical GitHub release identity")
        if _string(value["bundle_identifier"], "descriptor bundle identifier") != identity.bundle_identifier:
            raise ValueError("descriptor bundle identifier does not bind the release identity")
        if _string(value["team_identifier"], "descriptor team identifier") != identity.team_identifier:
            raise ValueError("descriptor Apple Team identifier does not bind the release identity")
        _string(value["notarization_evidence"], "descriptor notarization evidence")
        observed[architecture] = _digest(value["digest"], "descriptor asset digest")
    if set(observed) != set(operation.archives):
        raise ValueError("descriptor asset architectures do not exactly bind the operation archives")
    for architecture, digest in operation.archives.items():
        if observed[architecture] != digest:
            raise ValueError("descriptor asset digest does not bind the operation archive")


def verify(
    *,
    operation_raw: bytes,
    descriptor_raw: bytes,
    archive_paths: Mapping[str, Path],
    source_revision: str,
    expected_operation_id: str,
    expected_version: str,
    expected_channel: str,
    expected_policy_revision: str,
    expected_github_repository: str,
    expected_release_tag: str,
    expected_bundle_identifier: str,
    expected_team_identifier: str,
    expected_asset_prefix: str,
) -> InstallerReleaseOperation:
    if _REVISION.fullmatch(source_revision) is None:
        raise ValueError("candidate source revision is invalid")
    try:
        operation = InstallerReleaseOperation.parse(_strict_object(operation_raw, "installer operation"))
    except InstallerReleaseOperationError as error:
        raise ValueError("durable installer release operation is invalid") from error
    if operation.source_revision != source_revision:
        raise ValueError("durable operation source revision does not match the exact candidate")
    if (
        operation.operation_id != expected_operation_id
        or operation.installer_version != expected_version
        or operation.channel != expected_channel
        or operation.policy_revision != expected_policy_revision
    ):
        raise ValueError("durable operation does not bind the requested installer release context")
    identity = operation.release_identity
    if (
        identity.github_repository != expected_github_repository
        or operation.release_tag != expected_release_tag
        or identity.bundle_identifier != expected_bundle_identifier
        or identity.team_identifier != expected_team_identifier
        or identity.asset_prefix != expected_asset_prefix
    ):
        raise ValueError("durable operation does not bind the reviewed installer release identity")
    if operation.state not in {"QUALIFIED", "PUBLISHED", "CLEANUP_PENDING", "RELEASE_COMPLETE"}:
        raise ValueError("durable installer release operation state is unsupported")
    if set(archive_paths) != set(operation.archives):
        raise ValueError("supplied archives do not match the durable operation architectures")
    for architecture, path in archive_paths.items():
        if _file_digest(path) != operation.archives[architecture]:
            raise ValueError("archive digest does not bind the durable operation")

    descriptor = _strict_object(descriptor_raw, "installer release descriptor")
    descriptor = _mapping(
        descriptor,
        frozenset({
            "schema", "sequence", "channel", "published_at", "expires_at", "installer", "composition_catalog",
            "signatures",
        }),
        "installer release descriptor",
    )
    if descriptor["schema"] != "forge-platform.installer-release/v1":
        raise ValueError("installer release descriptor schema is invalid")
    if isinstance(descriptor["sequence"], bool) or not isinstance(descriptor["sequence"], int) or descriptor["sequence"] <= 0:
        raise ValueError("descriptor sequence is invalid")
    if descriptor["channel"] != operation.channel or descriptor["channel"] not in _CHANNELS:
        raise ValueError("descriptor channel does not bind the operation")
    published_at = _timestamp(descriptor["published_at"], "descriptor publication timestamp")
    expires_at = _timestamp(descriptor["expires_at"], "descriptor expiry timestamp")
    if expires_at <= published_at:
        raise ValueError("descriptor expiry does not follow publication")
    catalog = _mapping(descriptor["composition_catalog"], frozenset({"url"}), "descriptor catalog")
    _https_url(catalog["url"], "descriptor catalog URL")
    signatures = descriptor["signatures"]
    if not isinstance(signatures, list) or not signatures or any(
        not isinstance(signature, str) or not signature for signature in signatures
    ):
        raise ValueError("descriptor signatures are required for protected external verification")
    _descriptor_assets(descriptor, operation)
    if _file_digest_bytes(descriptor_raw) != operation.descriptor_digest:
        raise ValueError("descriptor digest does not bind the durable operation")
    if (
        operation.qualification.source_revision != source_revision
        or operation.qualification.policy_revision != operation.policy_revision
    ):
        raise ValueError("qualification evidence does not bind the candidate source revision and policy")
    return operation


def _file_digest_bytes(value: bytes) -> str:
    return "sha256:" + sha256(value).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--operation", required=True)
    parser.add_argument("--descriptor", required=True)
    parser.add_argument("--archive", action="append", default=[], metavar="ARCHITECTURE=PATH")
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--operation-id", required=True)
    parser.add_argument("--installer-version", required=True)
    parser.add_argument("--channel", required=True)
    parser.add_argument("--policy-revision", required=True)
    parser.add_argument("--github-repository", required=True)
    parser.add_argument("--release-tag", required=True)
    parser.add_argument("--bundle-identifier", required=True)
    parser.add_argument("--team-identifier", required=True)
    parser.add_argument("--asset-prefix", required=True)
    args = parser.parse_args()
    try:
        operation_path = Path(args.operation).expanduser().resolve(strict=True)
        descriptor_path = Path(args.descriptor).expanduser().resolve(strict=True)
        operation = verify(
            operation_raw=operation_path.read_bytes(),
            descriptor_raw=descriptor_path.read_bytes(),
            archive_paths=_archive_arguments(args.archive),
            source_revision=args.source_sha,
            expected_operation_id=args.operation_id,
            expected_version=args.installer_version,
            expected_channel=args.channel,
            expected_policy_revision=args.policy_revision,
            expected_github_repository=args.github_repository,
            expected_release_tag=args.release_tag,
            expected_bundle_identifier=args.bundle_identifier,
            expected_team_identifier=args.team_identifier,
            expected_asset_prefix=args.asset_prefix,
        )
        print(
            "INSTALLER_RELEASE_EVIDENCE_STRUCTURE=PASS"
            f" version={operation.installer_version}"
            f" tag={operation.release_tag}"
            f" state={operation.state}"
            " cryptographic_signature_verification=NOT_PERFORMED"
        )
    except (OSError, ValueError) as error:
        print(f"INSTALLER_RELEASE_EVIDENCE=FAIL reason={error}", file=sys.stderr)
        raise SystemExit(1) from error


if __name__ == "__main__":
    main()
