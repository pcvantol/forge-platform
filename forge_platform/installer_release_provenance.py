"""Strict public V1 provenance carried by a released installer bundle.

This small module deliberately contains only the public, non-secret resource
contract shared by bundle packaging and protected release-evidence inspection.
It does not open paths, extract archives, sign bytes, contact GitHub, or
activate an installer.  Keeping the canonical digest and strict JSON parser in
one Python location prevents a packager and qualification verifier from
quietly accepting different provenance semantics.
"""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
import re
from typing import Mapping


INSTALLER_RELEASE_PROVENANCE_SCHEMA_VERSION = 1
INSTALLER_RELEASE_PROVENANCE_MAXIMUM_BYTES = 32 * 1024
INSTALLER_RELEASE_PROVENANCE_RESOURCE_NAME = "ForgePlatformInstallerReleaseProvenance.json"
MAXIMUM_NATIVE_SIGNED_INTEGER = (1 << 63) - 1
MAXIMUM_RELEASE_SEQUENCE = (1 << 64) - 1

_SHA256 = re.compile(r"^[0-9a-f]{64}$")
_SEMVER = re.compile(r"^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)$")
_CHANNEL = re.compile(r"^(?:stable|candidate)$")
_SOURCE_REVISION = re.compile(r"^[0-9a-f]{40,64}$")
_POLICY_REVISION = re.compile(r"^[a-z0-9][a-z0-9._/-]{0,127}$")
_CAPABILITY = re.compile(r"^[a-z0-9][a-z0-9./_-]{0,127}$")


def _strict_json_object(pairs: list[tuple[object, object]]) -> dict[str, object]:
    value: dict[str, object] = {}
    for key, member in pairs:
        if not isinstance(key, str) or key in value:
            raise ValueError("duplicate or invalid JSON object key")
        value[key] = member
    return value


def _reject_json_constant(value: str) -> None:
    raise ValueError(f"unsupported JSON constant {value}")


def _stable_semver(value: object) -> bool:
    return (
        isinstance(value, str)
        and _SEMVER.fullmatch(value) is not None
        and all(int(component) <= MAXIMUM_NATIVE_SIGNED_INTEGER for component in value.split("."))
    )


def canonical_release_provenance_sha256(
    *,
    installer_version: str,
    channel: str,
    release_sequence: int,
    source_revision: str,
    policy_revision: str,
    release_trust_configuration_sha256: str,
    capabilities: tuple[str, ...] | list[str],
) -> str:
    """Return the V1 public canonical provenance digest.

    The NUL-delimited UTF-8 domain and field order are part of the published
    contract.  Callers must supply already validated, strictly sorted
    capabilities; :func:`parse_installer_release_provenance_bytes` does that
    before it invokes this helper.
    """

    canonical_fields = [
        "forge-platform-installer-release-provenance-v1",
        "schema_version=1",
        f"installer_version={installer_version}",
        f"channel={channel}",
        f"release_sequence={release_sequence}",
        f"source_revision={source_revision}",
        f"policy_revision={policy_revision}",
        f"release_trust_configuration_sha256={release_trust_configuration_sha256}",
        f"capability_count={len(capabilities)}",
    ]
    canonical_fields.extend(f"capability={capability}" for capability in capabilities)
    return hashlib.sha256("\0".join(canonical_fields).encode("utf-8")).hexdigest()


@dataclass(frozen=True)
class InstallerReleaseProvenance:
    """One validated V1 resource semantic identity, without source-path state."""

    provenance_sha256: str
    installer_version: str
    channel: str
    release_sequence: int
    source_revision: str
    policy_revision: str
    capabilities: tuple[str, ...]
    release_trust_configuration_sha256: str

    def __post_init__(self) -> None:
        if not isinstance(self.provenance_sha256, str) or _SHA256.fullmatch(self.provenance_sha256) is None:
            raise ValueError("installer release provenance digest is invalid")
        if not _stable_semver(self.installer_version):
            raise ValueError("installer release provenance installer version is invalid")
        if not isinstance(self.channel, str) or _CHANNEL.fullmatch(self.channel) is None:
            raise ValueError("installer release provenance channel is invalid")
        if (
            type(self.release_sequence) is not int
            or self.release_sequence <= 0
            or self.release_sequence > MAXIMUM_RELEASE_SEQUENCE
        ):
            raise ValueError("installer release provenance sequence is invalid")
        if not isinstance(self.source_revision, str) or _SOURCE_REVISION.fullmatch(self.source_revision) is None:
            raise ValueError("installer release provenance source revision is invalid")
        if not isinstance(self.policy_revision, str) or _POLICY_REVISION.fullmatch(self.policy_revision) is None:
            raise ValueError("installer release provenance policy revision is invalid")
        if (
            not isinstance(self.release_trust_configuration_sha256, str)
            or _SHA256.fullmatch(self.release_trust_configuration_sha256) is None
        ):
            raise ValueError("installer release provenance trust configuration digest is invalid")
        if (
            not isinstance(self.capabilities, tuple)
            or not self.capabilities
            or any(not isinstance(capability, str) or _CAPABILITY.fullmatch(capability) is None for capability in self.capabilities)
            or self.capabilities != tuple(sorted(self.capabilities))
            or len(self.capabilities) != len(set(self.capabilities))
        ):
            raise ValueError("installer release provenance capabilities must be sorted, unique, and valid")
        expected_digest = canonical_release_provenance_sha256(
            installer_version=self.installer_version,
            channel=self.channel,
            release_sequence=self.release_sequence,
            source_revision=self.source_revision,
            policy_revision=self.policy_revision,
            release_trust_configuration_sha256=self.release_trust_configuration_sha256,
            capabilities=self.capabilities,
        )
        if self.provenance_sha256 != expected_digest:
            raise ValueError("installer release provenance digest does not match its fields")


def parse_installer_release_provenance_bytes(
    contents: bytes,
    *,
    label: str = "installer release provenance resource",
) -> InstallerReleaseProvenance:
    """Parse only one bounded strict-JSON V1 provenance resource.

    The caller owns path and archive handling.  This parser owns the byte
    bounds, strict UTF-8 JSON syntax, exact public field set, native numeric
    bounds, canonical capability order, and semantic digest recomputation.
    """

    if not isinstance(contents, bytes) or len(contents) > INSTALLER_RELEASE_PROVENANCE_MAXIMUM_BYTES:
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
        "provenance_sha256",
        "installer_version",
        "channel",
        "release_sequence",
        "source_revision",
        "policy_revision",
        "capabilities",
        "release_trust_configuration_sha256",
    }
    if not isinstance(parsed, Mapping) or set(parsed) != expected_fields:
        raise ValueError(f"{label} has unsupported or missing fields")
    if type(parsed["schema_version"]) is not int or parsed["schema_version"] != INSTALLER_RELEASE_PROVENANCE_SCHEMA_VERSION:
        raise ValueError(f"{label} schema version is unsupported")
    capabilities = parsed["capabilities"]
    if not isinstance(capabilities, list):
        raise ValueError(f"{label} capabilities must be sorted, unique, and valid")
    try:
        return InstallerReleaseProvenance(
            provenance_sha256=parsed["provenance_sha256"],  # type: ignore[arg-type]
            installer_version=parsed["installer_version"],  # type: ignore[arg-type]
            channel=parsed["channel"],  # type: ignore[arg-type]
            release_sequence=parsed["release_sequence"],  # type: ignore[arg-type]
            source_revision=parsed["source_revision"],  # type: ignore[arg-type]
            policy_revision=parsed["policy_revision"],  # type: ignore[arg-type]
            capabilities=tuple(capabilities),
            release_trust_configuration_sha256=parsed["release_trust_configuration_sha256"],  # type: ignore[arg-type]
        )
    except ValueError as error:
        raise ValueError(f"{label} {error}") from error
