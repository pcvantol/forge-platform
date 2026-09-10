"""Strict public V1 trust configuration for the composition-catalog feed.

This resource is deliberately independent from the installer-release trust
configuration.  A signer authorized to describe a newer installer is not,
without this separately code-signed policy, authorized to sign a composition
catalog.  The module is a parser/model only: it does not read a bundle path,
fetch a feed, verify catalog signatures, persist an anchor, or select/install a
product component.
"""

from __future__ import annotations

import base64
from dataclasses import dataclass
import hashlib
import json
import re
from typing import Mapping


COMPOSITION_CATALOG_TRUST_SCHEMA_VERSION = 1
COMPOSITION_CATALOG_TRUST_MAXIMUM_BYTES = 32 * 1024
COMPOSITION_CATALOG_TRUST_MAXIMUM_JSON_NESTING_DEPTH = 64
COMPOSITION_CATALOG_TRUST_MAXIMUM_JSON_NODES = 16_384
COMPOSITION_CATALOG_TRUST_RESOURCE_NAME = "ForgePlatformInstallerCompositionCatalogTrust.json"
MAXIMUM_ED25519_PUBLIC_KEYS = 16

_RAW_SHA256 = re.compile(r"^[0-9a-f]{64}$")
_TRUST_KEY_ID = re.compile(r"^[a-z0-9][a-z0-9._-]{0,127}$")


def _strict_json_object(pairs: list[tuple[object, object]]) -> dict[str, object]:
    value: dict[str, object] = {}
    for key, member in pairs:
        if not isinstance(key, str) or key in value:
            raise ValueError("duplicate or invalid JSON object key")
        value[key] = member
    return value


def _reject_json_constant(value: str) -> None:
    raise ValueError(f"unsupported JSON constant {value}")


def _require_bounded_json_structure(value: object, *, label: str) -> None:
    """Apply the native resource reader's container and value budgets.

    ``json.loads`` has already rejected malformed syntax, duplicate members and
    non-finite constants.  This iterative walk retains the native meaning of a
    JSON node: every JSON value consumes one node, while only objects and arrays
    consume nesting depth.  It avoids recursively walking an attacker-controlled
    object after parsing.
    """

    node_count = 0
    pending: list[tuple[object, int]] = [(value, 0)]
    while pending:
        current, parent_container_depth = pending.pop()
        node_count += 1
        if node_count > COMPOSITION_CATALOG_TRUST_MAXIMUM_JSON_NODES:
            raise ValueError(f"{label} exceeds the native JSON node limit")
        if isinstance(current, Mapping):
            depth = parent_container_depth + 1
            if depth > COMPOSITION_CATALOG_TRUST_MAXIMUM_JSON_NESTING_DEPTH:
                raise ValueError(f"{label} exceeds the native JSON nesting limit")
            pending.extend((child, depth) for child in current.values())
        elif isinstance(current, list):
            depth = parent_container_depth + 1
            if depth > COMPOSITION_CATALOG_TRUST_MAXIMUM_JSON_NESTING_DEPTH:
                raise ValueError(f"{label} exceeds the native JSON nesting limit")
            pending.extend((child, depth) for child in current)


def _raw_sha256(value: object, *, label: str) -> str:
    if not isinstance(value, str) or _RAW_SHA256.fullmatch(value) is None:
        raise ValueError(f"{label} is invalid")
    return value


def _validated_ed25519_public_key_values(
    key_id: object,
    public_key_base64: object,
    *,
    label: str,
) -> tuple[str, str]:
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


def _validated_ed25519_public_key(value: object, *, label: str) -> tuple[str, str]:
    if not isinstance(value, Mapping) or set(value) != {"key_id", "public_key_base64"}:
        raise ValueError(f"{label} public key fields are invalid")
    return _validated_ed25519_public_key_values(
        value["key_id"],
        value["public_key_base64"],
        label=label,
    )


def canonical_composition_catalog_trust_configuration_sha256(
    *,
    installer_release_trust_configuration_sha256: str,
    signature_threshold: int,
    ed25519_public_keys: tuple[tuple[str, str], ...] | list[tuple[str, str]],
) -> str:
    """Return the V1 NUL-delimited composition-catalog trust digest.

    The domain separator and field order are a cross-language wire contract.
    Callers supply already validated, ascending public keys; the parser and
    model enforce that precondition before they call this helper.
    """

    canonical_fields = [
        "forge-platform-installer-composition-catalog-trust-v1",
        "schema_version=1",
        "installer_release_trust_configuration_sha256=" + installer_release_trust_configuration_sha256,
        f"signature_threshold={signature_threshold}",
        f"ed25519_public_key_count={len(ed25519_public_keys)}",
    ]
    for key_id, public_key_base64 in ed25519_public_keys:
        canonical_fields.append(f"ed25519_public_key_id={key_id}")
        canonical_fields.append(f"ed25519_public_key_base64={public_key_base64}")
    return hashlib.sha256("\0".join(canonical_fields).encode("utf-8")).hexdigest()


@dataclass(frozen=True)
class CompositionCatalogTrust:
    """One semantic V1 catalog trust policy, with no source-path authority."""

    configuration_sha256: str
    installer_release_trust_configuration_sha256: str
    signature_threshold: int
    ed25519_public_keys: tuple[tuple[str, str], ...]

    def __post_init__(self) -> None:
        _raw_sha256(self.configuration_sha256, label="composition catalog trust configuration digest")
        _raw_sha256(
            self.installer_release_trust_configuration_sha256,
            label="composition catalog trust installer release trust configuration digest",
        )
        if type(self.signature_threshold) is not int or self.signature_threshold <= 0:
            raise ValueError("composition catalog trust signature threshold is invalid")
        if (
            not isinstance(self.ed25519_public_keys, tuple)
            or not self.ed25519_public_keys
            or len(self.ed25519_public_keys) > MAXIMUM_ED25519_PUBLIC_KEYS
        ):
            raise ValueError("composition catalog trust public keys are invalid")
        if any(
            not isinstance(public_key, tuple) or len(public_key) != 2
            for public_key in self.ed25519_public_keys
        ):
            raise ValueError("composition catalog trust public keys are invalid")
        public_keys = tuple(
            _validated_ed25519_public_key_values(key_id, public_key_base64, label="composition catalog trust")
            for key_id, public_key_base64 in self.ed25519_public_keys
        )
        key_ids = tuple(key_id for key_id, _ in public_keys)
        public_key_material = tuple(public_key_base64 for _, public_key_base64 in public_keys)
        if len(set(key_ids)) != len(key_ids) or len(set(public_key_material)) != len(public_key_material):
            raise ValueError("composition catalog trust public keys must be unique")
        if key_ids != tuple(sorted(key_ids)):
            raise ValueError("composition catalog trust public keys must be strictly ordered by key ID")
        if self.signature_threshold > len(public_keys):
            raise ValueError("composition catalog trust signature threshold exceeds public keys")
        expected_digest = canonical_composition_catalog_trust_configuration_sha256(
            installer_release_trust_configuration_sha256=self.installer_release_trust_configuration_sha256,
            signature_threshold=self.signature_threshold,
            ed25519_public_keys=public_keys,
        )
        if self.configuration_sha256 != expected_digest:
            raise ValueError("composition catalog trust configuration digest does not match its fields")

    @property
    def signature_key_ids(self) -> tuple[str, ...]:
        return tuple(key_id for key_id, _ in self.ed25519_public_keys)


def parse_composition_catalog_trust_bytes(
    contents: bytes,
    *,
    label: str = "composition catalog trust resource",
) -> CompositionCatalogTrust:
    """Parse only one bounded strict-JSON V1 catalog trust resource.

    The caller retains all bundle/path ownership.  This function recognizes no
    transport or product data and does not create a signature verifier; it only
    admits the independently code-signed public policy representation.
    """

    if (
        not isinstance(contents, bytes)
        or not contents
        or len(contents) > COMPOSITION_CATALOG_TRUST_MAXIMUM_BYTES
    ):
        raise ValueError(f"{label} contents are invalid")
    try:
        parsed = json.loads(
            contents.decode("utf-8"),
            object_pairs_hook=_strict_json_object,
            parse_constant=_reject_json_constant,
        )
    except (UnicodeDecodeError, ValueError, json.JSONDecodeError, RecursionError) as error:
        raise ValueError(f"{label} is not strict UTF-8 JSON") from error
    _require_bounded_json_structure(parsed, label=label)

    expected_fields = {
        "schema_version",
        "configuration_sha256",
        "installer_release_trust_configuration_sha256",
        "signature_threshold",
        "ed25519_public_keys",
    }
    if not isinstance(parsed, Mapping) or set(parsed) != expected_fields:
        raise ValueError(f"{label} has unsupported or missing fields")
    if type(parsed["schema_version"]) is not int or parsed["schema_version"] != COMPOSITION_CATALOG_TRUST_SCHEMA_VERSION:
        raise ValueError(f"{label} schema version is unsupported")
    public_key_values = parsed["ed25519_public_keys"]
    if not isinstance(public_key_values, list):
        raise ValueError(f"{label} public keys are invalid")
    try:
        return CompositionCatalogTrust(
            configuration_sha256=parsed["configuration_sha256"],  # type: ignore[arg-type]
            installer_release_trust_configuration_sha256=parsed[
                "installer_release_trust_configuration_sha256"
            ],  # type: ignore[arg-type]
            signature_threshold=parsed["signature_threshold"],  # type: ignore[arg-type]
            ed25519_public_keys=tuple(
                _validated_ed25519_public_key(public_key, label=label)
                for public_key in public_key_values
            ),
        )
    except ValueError as error:
        raise ValueError(f"{label} {error}") from error
