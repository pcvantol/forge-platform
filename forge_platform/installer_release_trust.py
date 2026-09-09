"""Strict public V2 trust configuration embedded in a released installer.

The bundle packager and protected archive-evidence verifier consume this same
non-secret contract.  It holds only public release transport and signing-policy
facts; it never accepts a URL, private key, credential, notarization material,
or product-runtime authority.
"""

from __future__ import annotations

import base64
from dataclasses import dataclass
import hashlib
import json
import re
from typing import Mapping


INSTALLER_RELEASE_TRUST_SCHEMA_VERSION = 2
INSTALLER_RELEASE_TRUST_MAXIMUM_BYTES = 32 * 1024
INSTALLER_RELEASE_TRUST_RESOURCE_NAME = "ForgePlatformInstallerReleaseTrust.json"
GITHUB_RELEASE_ASSET_LOCATOR = "github-release-asset-v1"
MAXIMUM_ED25519_PUBLIC_KEYS = 16

_BUNDLE_IDENTIFIER = re.compile(r"^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$")
_GITHUB_REPOSITORY = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,99}/[A-Za-z0-9][A-Za-z0-9._-]{0,99}$")
_TRUST_KEY_ID = re.compile(r"^[a-z0-9][a-z0-9._-]{0,127}$")
_DESCRIPTOR_ASSET_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,122}\.json$")
_TEAM_IDENTIFIER = re.compile(r"^[A-Z0-9]{10}$")
_SHA256 = re.compile(r"^[0-9a-f]{64}$")


def _strict_json_object(pairs: list[tuple[object, object]]) -> dict[str, object]:
    value: dict[str, object] = {}
    for key, member in pairs:
        if not isinstance(key, str) or key in value:
            raise ValueError("duplicate or invalid JSON object key")
        value[key] = member
    return value


def _reject_json_constant(value: str) -> None:
    raise ValueError(f"unsupported JSON constant {value}")


def canonical_release_trust_configuration_sha256(
    *,
    repository: str,
    release_descriptor_locator: str,
    release_descriptor_asset_name: str,
    expected_bundle_identifier: str,
    expected_team_identifier: str,
    signature_threshold: int,
    ed25519_public_keys: tuple[tuple[str, str], ...] | list[tuple[str, str]],
) -> str:
    """Return the public V2 NUL-delimited trust-configuration digest."""

    canonical_fields = [
        "forge-platform-installer-release-trust-v2",
        "schema_version=2",
        f"repository={repository}",
        f"release_descriptor_locator={release_descriptor_locator}",
        f"release_descriptor_asset_name={release_descriptor_asset_name}",
        f"expected_bundle_identifier={expected_bundle_identifier}",
        f"expected_team_identifier={expected_team_identifier}",
        f"signature_threshold={signature_threshold}",
        f"ed25519_public_key_count={len(ed25519_public_keys)}",
    ]
    for key_id, public_key_base64 in ed25519_public_keys:
        canonical_fields.append(f"ed25519_public_key_id={key_id}")
        canonical_fields.append(f"ed25519_public_key_base64={public_key_base64}")
    return hashlib.sha256("\0".join(canonical_fields).encode("utf-8")).hexdigest()


@dataclass(frozen=True)
class InstallerReleaseTrust:
    """Validated semantic V2 trust configuration, separate from source paths."""

    configuration_sha256: str
    repository: str
    release_descriptor_locator: str
    release_descriptor_asset_name: str
    expected_bundle_identifier: str
    expected_team_identifier: str
    signature_threshold: int
    ed25519_public_keys: tuple[tuple[str, str], ...]

    @property
    def signature_key_ids(self) -> tuple[str, ...]:
        return tuple(key_id for key_id, _ in self.ed25519_public_keys)


def _validated_ed25519_public_key(value: object, *, label: str) -> tuple[str, str]:
    if not isinstance(value, Mapping) or set(value) != {"key_id", "public_key_base64"}:
        raise ValueError(f"{label} public key fields are invalid")
    key_id = value["key_id"]
    public_key_base64 = value["public_key_base64"]
    if not isinstance(key_id, str) or _TRUST_KEY_ID.fullmatch(key_id) is None:
        raise ValueError(f"{label} public key ID is invalid")
    if not isinstance(public_key_base64, str):
        raise ValueError(f"{label} public key is invalid")
    try:
        raw_public_key = base64.b64decode(public_key_base64, validate=True)
    except (ValueError, UnicodeEncodeError) as error:
        raise ValueError(f"{label} public key is invalid") from error
    if len(raw_public_key) != 32 or base64.b64encode(raw_public_key).decode("ascii") != public_key_base64:
        raise ValueError(f"{label} public key is invalid")
    return key_id, public_key_base64


def parse_installer_release_trust_bytes(
    contents: bytes,
    *,
    label: str = "installer release trust resource",
) -> InstallerReleaseTrust:
    """Parse only the bounded strict-JSON V2 public trust resource."""

    if not isinstance(contents, bytes) or len(contents) > INSTALLER_RELEASE_TRUST_MAXIMUM_BYTES:
        raise ValueError(f"{label} contents are invalid")
    try:
        parsed = json.loads(
            contents.decode("utf-8"),
            object_pairs_hook=_strict_json_object,
            parse_constant=_reject_json_constant,
        )
    except (UnicodeDecodeError, ValueError, json.JSONDecodeError) as error:
        raise ValueError(f"{label} is not strict UTF-8 JSON") from error

    expected_fields = {
        "schema_version",
        "configuration_sha256",
        "repository",
        "release_descriptor_locator",
        "release_descriptor_asset_name",
        "expected_bundle_identifier",
        "expected_team_identifier",
        "signature_threshold",
        "ed25519_public_keys",
    }
    if not isinstance(parsed, Mapping) or set(parsed) != expected_fields:
        raise ValueError(f"{label} has unsupported or missing fields")
    schema_version = parsed["schema_version"]
    configuration_sha256 = parsed["configuration_sha256"]
    repository = parsed["repository"]
    release_descriptor_locator = parsed["release_descriptor_locator"]
    release_descriptor_asset_name = parsed["release_descriptor_asset_name"]
    expected_bundle_identifier = parsed["expected_bundle_identifier"]
    expected_team_identifier = parsed["expected_team_identifier"]
    signature_threshold = parsed["signature_threshold"]
    public_key_values = parsed["ed25519_public_keys"]

    if type(schema_version) is not int or schema_version != INSTALLER_RELEASE_TRUST_SCHEMA_VERSION:
        raise ValueError(f"{label} schema version is unsupported")
    if not isinstance(configuration_sha256, str) or _SHA256.fullmatch(configuration_sha256) is None:
        raise ValueError(f"{label} configuration digest is invalid")
    if not isinstance(repository, str) or _GITHUB_REPOSITORY.fullmatch(repository) is None:
        raise ValueError(f"{label} repository is invalid")
    if release_descriptor_locator != GITHUB_RELEASE_ASSET_LOCATOR:
        raise ValueError(f"{label} descriptor locator is unsupported")
    if (
        not isinstance(release_descriptor_asset_name, str)
        or _DESCRIPTOR_ASSET_NAME.fullmatch(release_descriptor_asset_name) is None
    ):
        raise ValueError(f"{label} descriptor asset name is invalid")
    if (
        not isinstance(expected_bundle_identifier, str)
        or _BUNDLE_IDENTIFIER.fullmatch(expected_bundle_identifier) is None
    ):
        raise ValueError(f"{label} expected bundle identifier is invalid")
    if not isinstance(expected_team_identifier, str) or _TEAM_IDENTIFIER.fullmatch(expected_team_identifier) is None:
        raise ValueError(f"{label} expected team identifier is invalid")
    if type(signature_threshold) is not int or signature_threshold <= 0:
        raise ValueError(f"{label} signature threshold is invalid")
    if not isinstance(public_key_values, list) or not public_key_values:
        raise ValueError(f"{label} must contain public keys")
    if len(public_key_values) > MAXIMUM_ED25519_PUBLIC_KEYS:
        raise ValueError(f"{label} contains too many public keys")

    public_keys = tuple(
        _validated_ed25519_public_key(public_key, label=label)
        for public_key in public_key_values
    )
    key_ids = tuple(key_id for key_id, _ in public_keys)
    public_key_bytes = tuple(public_key_base64 for _, public_key_base64 in public_keys)
    if len(set(key_ids)) != len(key_ids) or len(set(public_key_bytes)) != len(public_key_bytes):
        raise ValueError(f"{label} public keys must be unique")
    if key_ids != tuple(sorted(key_ids)):
        raise ValueError(f"{label} public keys must be strictly ordered by key ID")
    if signature_threshold > len(public_keys):
        raise ValueError(f"{label} signature threshold exceeds public keys")
    expected_digest = canonical_release_trust_configuration_sha256(
        repository=repository,
        release_descriptor_locator=release_descriptor_locator,
        release_descriptor_asset_name=release_descriptor_asset_name,
        expected_bundle_identifier=expected_bundle_identifier,
        expected_team_identifier=expected_team_identifier,
        signature_threshold=signature_threshold,
        ed25519_public_keys=public_keys,
    )
    if configuration_sha256 != expected_digest:
        raise ValueError(f"{label} configuration digest does not match its fields")
    return InstallerReleaseTrust(
        configuration_sha256=configuration_sha256,
        repository=repository,
        release_descriptor_locator=release_descriptor_locator,
        release_descriptor_asset_name=release_descriptor_asset_name,
        expected_bundle_identifier=expected_bundle_identifier,
        expected_team_identifier=expected_team_identifier,
        signature_threshold=signature_threshold,
        ed25519_public_keys=public_keys,
    )
