"""Durable evidence for releasing the separately versioned macOS installer.

This module is intentionally separate from :mod:`forge_platform.release_operation`.
The latter records an immutable *product composition*; this journal records the
Forge Platform Universal Installer bundle which consumes those compositions.
It contains no GitHub client, signing implementation, credential, package
installation, or product-runtime mutation.  Its sole purpose is to retain a
small, non-secret, fail-closed record around an already-qualified installer
release so a lost publication response can be reconciled safely.

The installer artifact is identified by its stable version/channel, protected
source revision, declared capability set, exact per-architecture archive
digests, and exact signed descriptor digest.  A retry must retain every one of
those facts.  ``PUBLISHED`` and ``RELEASE_COMPLETE`` remain deliberately
different states: a public GitHub Release is not proof that operation-scoped
cleanup completed.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass, replace
import fcntl
import json
import os
from pathlib import Path
import re
import stat
from typing import Mapping


_OPERATION_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{7,127}$")
_SEMVER = re.compile(r"^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)$")
_REVISION = re.compile(r"^[0-9a-f]{40,64}$")
_SHA256 = re.compile(r"^sha256:[0-9a-f]{64}$")
_RAW_SHA256 = re.compile(r"^[0-9a-f]{64}$")
_CAPABILITY = re.compile(r"^[a-z0-9][a-z0-9./_-]{0,127}$")
_RECEIPT_REFERENCE = re.compile(r"^receipt:[a-z0-9][a-z0-9._-]{0,127}$")
_TARGET_ID = re.compile(r"^[a-z0-9][a-z0-9._-]{0,127}$")
_BUNDLE_IDENTIFIER = re.compile(r"^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$")
_TEAM_IDENTIFIER = re.compile(r"^[A-Z0-9]{10}$")
_GITHUB_REPOSITORY = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,99}/[A-Za-z0-9][A-Za-z0-9._-]{0,99}$")
_RELEASE_TAG_PREFIX = re.compile(r"^[a-z0-9][a-z0-9._-]{0,68}$")
_ASSET_PREFIX = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,117}$")
_GITHUB_RELEASE_TAG = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
_DESCRIPTOR_ASSET_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,122}\.json$")
_ARCHIVE_ASSET_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,123}\.zip$")
_SIGNING_KEY_ID = re.compile(r"^[a-z0-9][a-z0-9._-]{0,127}$")
_POLICY_REVISION = re.compile(r"^[a-z0-9][a-z0-9._/-]{0,127}$")
_ARCHITECTURES = frozenset({"arm64", "x86_64"})
_CHANNELS = frozenset({"stable", "candidate"})
_SEQUENCE_RESERVATION_FILENAME = re.compile(r"^([1-9][0-9]*)\.json$")
_MAXIMUM_NATIVE_SIGNED_INTEGER = (1 << 63) - 1
_MAXIMUM_RELEASE_SEQUENCE = (1 << 64) - 1
_MAXIMUM_JOURNAL_RECORD_BYTES = 512 * 1024
_STATES = frozenset({"QUALIFIED", "PUBLISHED", "CLEANUP_PENDING", "RELEASE_COMPLETE"})
_ALLOWED_TRANSITIONS = {
    "QUALIFIED": frozenset({"PUBLISHED"}),
    "PUBLISHED": frozenset({"CLEANUP_PENDING", "RELEASE_COMPLETE"}),
    "CLEANUP_PENDING": frozenset({"RELEASE_COMPLETE"}),
    "RELEASE_COMPLETE": frozenset(),
}
INSTALLER_RELEASE_POLICY_REVISION = "forge-platform-installer-release-v1"


class InstallerReleaseOperationError(ValueError):
    """An installer release operation has invalid identity or evidence."""


def _required_string(value: object, label: str) -> str:
    if not isinstance(value, str) or not value:
        raise InstallerReleaseOperationError(f"installer release {label} is invalid")
    return value


def _digest(value: object, label: str) -> str:
    result = _required_string(value, label)
    if _SHA256.fullmatch(result) is None:
        raise InstallerReleaseOperationError(f"installer release {label} must be a lowercase SHA-256 identity")
    return result


def _raw_sha256(value: object, label: str) -> str:
    result = _required_string(value, label)
    if _RAW_SHA256.fullmatch(result) is None:
        raise InstallerReleaseOperationError(
            f"installer release {label} must be a raw lowercase SHA-256 identity"
        )
    return result


def _release_sequence(value: object, label: str) -> int:
    if (
        isinstance(value, bool)
        or not isinstance(value, int)
        or value <= 0
        or value > _MAXIMUM_RELEASE_SEQUENCE
    ):
        raise InstallerReleaseOperationError(f"installer release {label} must be a positive UInt64 integer")
    return value


def _stable_semver(value: object, label: str) -> str:
    result = _required_string(value, label)
    match = _SEMVER.fullmatch(result)
    if match is None or any(int(component) > _MAXIMUM_NATIVE_SIGNED_INTEGER for component in match.groups()):
        raise InstallerReleaseOperationError(f"installer release {label} is invalid")
    return result


def _receipt_reference(value: object, label: str) -> str:
    result = _required_string(value, label)
    if _RECEIPT_REFERENCE.fullmatch(result) is None:
        raise InstallerReleaseOperationError(f"installer release {label} must be an opaque non-secret receipt reference")
    return result


def _policy_revision(value: object, label: str) -> str:
    result = _required_string(value, label)
    if _POLICY_REVISION.fullmatch(result) is None:
        raise InstallerReleaseOperationError(f"installer release {label} is invalid")
    return result


def _strict_mapping(value: object, expected: frozenset[str], label: str) -> Mapping[str, object]:
    if not isinstance(value, Mapping) or set(value) != expected:
        raise InstallerReleaseOperationError(f"installer release {label} has unknown or missing fields")
    return value


def _reject_json_constant(value: str) -> None:
    raise ValueError(f"non-finite JSON value is not permitted: {value}")


def _unique_json_pairs(pairs: list[tuple[object, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if not isinstance(key, str) or key in result:
            raise ValueError("duplicate or invalid JSON object key")
        result[key] = value
    return result


def _strict_json_load(raw: str, label: str) -> object:
    try:
        return json.loads(
            raw,
            object_pairs_hook=_unique_json_pairs,
            parse_constant=_reject_json_constant,
        )
    except (TypeError, ValueError, json.JSONDecodeError) as error:
        raise InstallerReleaseOperationError(f"installer release {label} is unreadable") from error


def _capabilities(value: object) -> tuple[str, ...]:
    if not isinstance(value, (tuple, list)) or not value:
        raise InstallerReleaseOperationError("installer release capabilities must be a non-empty list")
    if any(not isinstance(item, str) or _CAPABILITY.fullmatch(item) is None for item in value):
        raise InstallerReleaseOperationError("installer release capability identity is invalid")
    normalized = tuple(sorted(value))
    if len(set(normalized)) != len(normalized):
        raise InstallerReleaseOperationError("installer release capabilities must be unique")
    return normalized


def _archives(value: object) -> dict[str, str]:
    if not isinstance(value, Mapping) or not value:
        raise InstallerReleaseOperationError("installer release architecture archives are required")
    result: dict[str, str] = {}
    for architecture, digest in value.items():
        if not isinstance(architecture, str) or architecture not in _ARCHITECTURES:
            raise InstallerReleaseOperationError("installer release archive architecture is unsupported")
        result[architecture] = _digest(digest, f"{architecture} archive digest")
    return dict(sorted(result.items()))


def _code_directories(value: object) -> dict[str, str]:
    if not isinstance(value, Mapping) or not value:
        raise InstallerReleaseOperationError("installer release CodeDirectory digests are required")
    result: dict[str, str] = {}
    for architecture, digest in value.items():
        if not isinstance(architecture, str) or architecture not in _ARCHITECTURES:
            raise InstallerReleaseOperationError("installer release CodeDirectory architecture is unsupported")
        result[architecture] = _raw_sha256(digest, f"{architecture} CodeDirectory digest")
    return dict(sorted(result.items()))


def _notarization_receipts(value: object) -> dict[str, str]:
    if not isinstance(value, Mapping) or not value:
        raise InstallerReleaseOperationError("installer release notarization receipts are required")
    result: dict[str, str] = {}
    for architecture, reference in value.items():
        if not isinstance(architecture, str) or architecture not in _ARCHITECTURES:
            raise InstallerReleaseOperationError("installer release notarization receipt architecture is unsupported")
        result[architecture] = _receipt_reference(reference, f"{architecture} notarization receipt reference")
    return dict(sorted(result.items()))


def _target_ids(value: object) -> tuple[str, ...]:
    if not isinstance(value, (tuple, list)):
        raise InstallerReleaseOperationError("installer release cleanup target IDs are invalid")
    if any(not isinstance(item, str) or _TARGET_ID.fullmatch(item) is None for item in value):
        raise InstallerReleaseOperationError("installer release cleanup target ID is invalid")
    normalized = tuple(sorted(value))
    if len(set(normalized)) != len(normalized):
        raise InstallerReleaseOperationError("installer release cleanup target IDs must be unique")
    if not normalized:
        raise InstallerReleaseOperationError("installer release cleanup target IDs are required")
    return normalized


@dataclass(frozen=True)
class InstallerReleaseIdentity:
    """Reviewed non-secret identity that a released installer must bind.

    This type deliberately excludes certificates, private keys, tokens and
    notarization credentials.  It gives a protected signer/publisher the exact
    public identity it must prove: GitHub repository/tag/asset naming, app
    bundle/team identity, and the rotatable descriptor-signing key policy.
    """

    github_repository: str
    bundle_identifier: str
    team_identifier: str
    release_tag_prefix: str
    asset_prefix: str
    release_descriptor_asset_name: str
    release_trust_configuration_sha256: str
    signature_algorithm: str
    signature_key_ids: tuple[str, ...]
    signature_threshold: int

    def __post_init__(self) -> None:
        if not isinstance(self.github_repository, str) or _GITHUB_REPOSITORY.fullmatch(self.github_repository) is None:
            raise InstallerReleaseOperationError("installer release GitHub repository is invalid")
        if not isinstance(self.bundle_identifier, str) or _BUNDLE_IDENTIFIER.fullmatch(self.bundle_identifier) is None:
            raise InstallerReleaseOperationError("installer release bundle identifier is invalid")
        if not isinstance(self.team_identifier, str) or _TEAM_IDENTIFIER.fullmatch(self.team_identifier) is None:
            raise InstallerReleaseOperationError("installer release Apple Team identifier is invalid")
        if not isinstance(self.release_tag_prefix, str) or _RELEASE_TAG_PREFIX.fullmatch(self.release_tag_prefix) is None:
            raise InstallerReleaseOperationError("installer release tag prefix is invalid")
        if not isinstance(self.asset_prefix, str) or _ASSET_PREFIX.fullmatch(self.asset_prefix) is None:
            raise InstallerReleaseOperationError("installer release asset prefix is invalid")
        if (
            not isinstance(self.release_descriptor_asset_name, str)
            or _DESCRIPTOR_ASSET_NAME.fullmatch(self.release_descriptor_asset_name) is None
        ):
            raise InstallerReleaseOperationError("installer release descriptor asset name is invalid")
        _raw_sha256(self.release_trust_configuration_sha256, "release trust configuration digest")
        if self.signature_algorithm != "ed25519":
            raise InstallerReleaseOperationError("installer release signature algorithm is unsupported")
        if not isinstance(self.signature_key_ids, (tuple, list)):
            raise InstallerReleaseOperationError("installer release signing key identities must be a list")
        if any(not isinstance(key_id, str) for key_id in self.signature_key_ids):
            raise InstallerReleaseOperationError("installer release signing key identity is invalid")
        key_ids = tuple(sorted(self.signature_key_ids))
        if not key_ids or any(_SIGNING_KEY_ID.fullmatch(key_id) is None for key_id in key_ids):
            raise InstallerReleaseOperationError("installer release signing key identity is invalid")
        if len(set(key_ids)) != len(key_ids):
            raise InstallerReleaseOperationError("installer release signing key identities must be unique")
        if (
            isinstance(self.signature_threshold, bool)
            or not isinstance(self.signature_threshold, int)
            or self.signature_threshold <= 0
            or self.signature_threshold > len(key_ids)
        ):
            raise InstallerReleaseOperationError("installer release signature threshold is invalid")
        object.__setattr__(self, "signature_key_ids", key_ids)

    @classmethod
    def from_mapping(cls, value: object) -> "InstallerReleaseIdentity":
        payload = _strict_mapping(
            value,
            frozenset({
                "github_repository", "bundle_identifier", "team_identifier", "release_tag_prefix", "asset_prefix",
                "release_descriptor_asset_name", "release_trust_configuration_sha256",
                "signature_algorithm", "signature_key_ids", "signature_threshold",
            }),
            "identity",
        )
        key_ids = payload["signature_key_ids"]
        if not isinstance(key_ids, list):
            raise InstallerReleaseOperationError("installer release signing key identities must be a list")
        return cls(
            github_repository=_required_string(payload["github_repository"], "GitHub repository"),
            bundle_identifier=_required_string(payload["bundle_identifier"], "bundle identifier"),
            team_identifier=_required_string(payload["team_identifier"], "Apple Team identifier"),
            release_tag_prefix=_required_string(payload["release_tag_prefix"], "tag prefix"),
            asset_prefix=_required_string(payload["asset_prefix"], "asset prefix"),
            release_descriptor_asset_name=_required_string(
                payload["release_descriptor_asset_name"], "descriptor asset name"
            ),
            release_trust_configuration_sha256=_raw_sha256(
                payload["release_trust_configuration_sha256"], "release trust configuration digest"
            ),
            signature_algorithm=_required_string(payload["signature_algorithm"], "signature algorithm"),
            signature_key_ids=tuple(key_ids),
            signature_threshold=payload["signature_threshold"],
        )

    def release_tag(self, version: str) -> str:
        _stable_semver(version, "version")
        tag = f"{self.release_tag_prefix}{version}"
        if _GITHUB_RELEASE_TAG.fullmatch(tag) is None:
            raise InstallerReleaseOperationError("installer release tag exceeds the canonical GitHub identity limit")
        return tag

    def asset_name(self, architecture: str) -> str:
        if architecture not in _ARCHITECTURES:
            raise InstallerReleaseOperationError("installer release archive architecture is unsupported")
        name = f"{self.asset_prefix}{architecture}.zip"
        if _ARCHIVE_ASSET_NAME.fullmatch(name) is None:
            raise InstallerReleaseOperationError("installer release archive name exceeds the canonical GitHub identity limit")
        return name


@dataclass(frozen=True)
class InstallerPreparationEvidence:
    """Exact unsigned candidate bytes retained before protected side effects.

    A signer may transform an unsigned archive into a signed/notarized release
    archive, but it must do so from this exact candidate input.  The evidence
    intentionally contains only digest identities and opaque receipt names;
    no filesystem path, credential, or command output belongs in it.
    """

    candidate_manifest_digest: str
    candidate_archives: Mapping[str, str]
    preparation_receipt_reference: str
    result: str = "PREPARED"

    def __post_init__(self) -> None:
        if self.result != "PREPARED":
            raise InstallerReleaseOperationError("installer preparation result is invalid")
        _digest(self.candidate_manifest_digest, "candidate manifest digest")
        object.__setattr__(self, "candidate_archives", _archives(self.candidate_archives))
        _receipt_reference(self.preparation_receipt_reference, "preparation receipt reference")

    @classmethod
    def from_mapping(cls, value: object) -> "InstallerPreparationEvidence":
        payload = _strict_mapping(
            value,
            frozenset({"result", "candidate_manifest_digest", "candidate_archives", "preparation_receipt_reference"}),
            "preparation evidence",
        )
        return cls(
            result=_required_string(payload["result"], "preparation result"),
            candidate_manifest_digest=_required_string(payload["candidate_manifest_digest"], "candidate manifest digest"),
            candidate_archives=_archives(payload["candidate_archives"]),
            preparation_receipt_reference=_required_string(
                payload["preparation_receipt_reference"], "preparation receipt reference"
            ),
        )


@dataclass(frozen=True)
class InstallerReleasePreparation:
    """The durable ``PREPARED`` precursor of one installer release operation.

    This record is persisted before any signing, notarization, upload or
    publication side effect.  It has the same operation ID and immutable
    source/policy/release identity as the later qualified operation, while
    retaining the unsigned candidate's exact digest identities separately from
    the signed release archives.
    """

    operation_id: str
    installer_version: str
    channel: str
    release_sequence: int
    source_revision: str
    policy_revision: str
    provenance_sha256: str
    release_identity: InstallerReleaseIdentity
    capabilities: tuple[str, ...]
    preparation: InstallerPreparationEvidence
    state: str = "PREPARED"

    def __post_init__(self) -> None:
        if not isinstance(self.operation_id, str) or _OPERATION_ID.fullmatch(self.operation_id) is None:
            raise InstallerReleaseOperationError("installer preparation operation ID is invalid")
        _stable_semver(self.installer_version, "preparation version")
        if self.channel not in _CHANNELS:
            raise InstallerReleaseOperationError("installer preparation channel is invalid")
        _release_sequence(self.release_sequence, "preparation release sequence")
        if not isinstance(self.source_revision, str) or _REVISION.fullmatch(self.source_revision) is None:
            raise InstallerReleaseOperationError("installer preparation source revision is invalid")
        _policy_revision(self.policy_revision, "preparation policy revision")
        _raw_sha256(self.provenance_sha256, "preparation provenance digest")
        if not isinstance(self.release_identity, InstallerReleaseIdentity):
            raise InstallerReleaseOperationError("installer preparation release identity is invalid")
        object.__setattr__(self, "capabilities", _capabilities(self.capabilities))
        if not isinstance(self.preparation, InstallerPreparationEvidence):
            raise InstallerReleaseOperationError("installer preparation evidence is invalid")
        if self.state != "PREPARED":
            raise InstallerReleaseOperationError("installer preparation state is invalid")

    @classmethod
    def parse(cls, value: object) -> "InstallerReleasePreparation":
        payload = _strict_mapping(
            value,
            frozenset({
                "operation_id", "installer_version", "channel", "release_sequence", "source_revision", "policy_revision",
                "provenance_sha256", "release_identity", "capabilities", "preparation", "state",
            }),
            "preparation record",
        )
        return cls(
            operation_id=_required_string(payload["operation_id"], "preparation operation ID"),
            installer_version=_required_string(payload["installer_version"], "preparation version"),
            channel=_required_string(payload["channel"], "preparation channel"),
            release_sequence=_release_sequence(payload["release_sequence"], "preparation release sequence"),
            source_revision=_required_string(payload["source_revision"], "preparation source revision"),
            policy_revision=_required_string(payload["policy_revision"], "preparation policy revision"),
            provenance_sha256=_raw_sha256(payload["provenance_sha256"], "preparation provenance digest"),
            release_identity=InstallerReleaseIdentity.from_mapping(payload["release_identity"]),
            capabilities=_capabilities(payload["capabilities"]),
            preparation=InstallerPreparationEvidence.from_mapping(payload["preparation"]),
            state=_required_string(payload["state"], "preparation state"),
        )


@dataclass(frozen=True)
class InstallerQualificationEvidence:
    """Typed qualification receipt with no command output, path, or credentials."""

    source_revision: str
    policy_revision: str
    release_sequence: int
    provenance_sha256: str
    release_trust_configuration_sha256: str
    candidate_manifest_digest: str
    candidate_archives: Mapping[str, str]
    descriptor_digest: str
    archives: Mapping[str, str]
    archive_code_directory_sha256: Mapping[str, str]
    archive_notarization_receipt_references: Mapping[str, str]
    qualification_receipt_reference: str
    result: str = "QUALIFIED"

    def __post_init__(self) -> None:
        if self.result != "QUALIFIED":
            raise InstallerReleaseOperationError("installer qualification result is invalid")
        if not isinstance(self.source_revision, str) or _REVISION.fullmatch(self.source_revision) is None:
            raise InstallerReleaseOperationError("installer qualification source revision is invalid")
        _policy_revision(self.policy_revision, "qualification policy revision")
        _release_sequence(self.release_sequence, "qualification release sequence")
        _raw_sha256(self.provenance_sha256, "qualification provenance digest")
        _raw_sha256(
            self.release_trust_configuration_sha256,
            "qualification release trust configuration digest",
        )
        _digest(self.candidate_manifest_digest, "qualification candidate manifest digest")
        object.__setattr__(self, "candidate_archives", _archives(self.candidate_archives))
        _digest(self.descriptor_digest, "qualification descriptor digest")
        object.__setattr__(self, "archives", _archives(self.archives))
        object.__setattr__(self, "archive_code_directory_sha256", _code_directories(self.archive_code_directory_sha256))
        object.__setattr__(
            self,
            "archive_notarization_receipt_references",
            _notarization_receipts(self.archive_notarization_receipt_references),
        )
        if (
            set(self.archive_code_directory_sha256) != set(self.archives)
            or set(self.archive_notarization_receipt_references) != set(self.archives)
        ):
            raise InstallerReleaseOperationError(
                "installer qualification CodeDirectory and notarization evidence must bind every archive"
            )
        _receipt_reference(self.qualification_receipt_reference, "qualification receipt reference")

    @classmethod
    def from_mapping(cls, value: object) -> "InstallerQualificationEvidence":
        payload = _strict_mapping(
            value,
            frozenset({
                "result", "source_revision", "policy_revision", "release_sequence", "provenance_sha256",
                "release_trust_configuration_sha256", "candidate_manifest_digest", "candidate_archives",
                "descriptor_digest", "archives", "archive_code_directory_sha256",
                "archive_notarization_receipt_references", "qualification_receipt_reference",
            }),
            "qualification evidence",
        )
        return cls(
            result=_required_string(payload["result"], "qualification result"),
            source_revision=_required_string(payload["source_revision"], "qualification source revision"),
            policy_revision=_required_string(payload["policy_revision"], "qualification policy revision"),
            release_sequence=_release_sequence(payload["release_sequence"], "qualification release sequence"),
            provenance_sha256=_raw_sha256(payload["provenance_sha256"], "qualification provenance digest"),
            release_trust_configuration_sha256=_raw_sha256(
                payload["release_trust_configuration_sha256"], "qualification release trust configuration digest"
            ),
            candidate_manifest_digest=_required_string(
                payload["candidate_manifest_digest"], "qualification candidate manifest digest"
            ),
            candidate_archives=_archives(payload["candidate_archives"]),
            descriptor_digest=_required_string(payload["descriptor_digest"], "qualification descriptor digest"),
            archives=_archives(payload["archives"]),
            archive_code_directory_sha256=_code_directories(payload["archive_code_directory_sha256"]),
            archive_notarization_receipt_references=_notarization_receipts(
                payload["archive_notarization_receipt_references"]
            ),
            qualification_receipt_reference=_required_string(
                payload["qualification_receipt_reference"], "qualification receipt reference"
            ),
        )


@dataclass(frozen=True)
class InstallerPublicationEvidence:
    """Typed GitHub Release publication and immutable readback evidence."""

    github_repository: str
    release_tag: str
    policy_revision: str
    release_sequence: int
    provenance_sha256: str
    release_trust_configuration_sha256: str
    descriptor_asset_name: str
    descriptor_digest: str
    descriptor_readback_digest: str
    archives: Mapping[str, str]
    publication_receipt_reference: str
    readback_receipt_reference: str
    result: str = "PUBLISHED"

    def __post_init__(self) -> None:
        if self.result != "PUBLISHED":
            raise InstallerReleaseOperationError("installer publication result is invalid")
        if not isinstance(self.github_repository, str) or _GITHUB_REPOSITORY.fullmatch(self.github_repository) is None:
            raise InstallerReleaseOperationError("installer publication GitHub repository is invalid")
        _required_string(self.release_tag, "publication release tag")
        _policy_revision(self.policy_revision, "publication policy revision")
        _release_sequence(self.release_sequence, "publication release sequence")
        _raw_sha256(self.provenance_sha256, "publication provenance digest")
        _raw_sha256(
            self.release_trust_configuration_sha256,
            "publication release trust configuration digest",
        )
        if (
            not isinstance(self.descriptor_asset_name, str)
            or _DESCRIPTOR_ASSET_NAME.fullmatch(self.descriptor_asset_name) is None
        ):
            raise InstallerReleaseOperationError("installer publication descriptor asset name is invalid")
        _digest(self.descriptor_digest, "publication descriptor digest")
        _digest(self.descriptor_readback_digest, "publication descriptor readback digest")
        object.__setattr__(self, "archives", _archives(self.archives))
        _receipt_reference(self.publication_receipt_reference, "publication receipt reference")
        _receipt_reference(self.readback_receipt_reference, "publication readback receipt reference")

    @classmethod
    def from_mapping(cls, value: object) -> "InstallerPublicationEvidence":
        payload = _strict_mapping(
            value,
            frozenset({
                "result", "github_repository", "release_tag", "policy_revision", "release_sequence", "provenance_sha256",
                "release_trust_configuration_sha256", "descriptor_asset_name", "descriptor_digest",
                "descriptor_readback_digest", "archives", "publication_receipt_reference",
                "readback_receipt_reference",
            }),
            "publication evidence",
        )
        return cls(
            result=_required_string(payload["result"], "publication result"),
            github_repository=_required_string(payload["github_repository"], "publication GitHub repository"),
            release_tag=_required_string(payload["release_tag"], "publication release tag"),
            policy_revision=_required_string(payload["policy_revision"], "publication policy revision"),
            release_sequence=_release_sequence(payload["release_sequence"], "publication release sequence"),
            provenance_sha256=_raw_sha256(payload["provenance_sha256"], "publication provenance digest"),
            release_trust_configuration_sha256=_raw_sha256(
                payload["release_trust_configuration_sha256"], "publication release trust configuration digest"
            ),
            descriptor_asset_name=_required_string(
                payload["descriptor_asset_name"], "publication descriptor asset name"
            ),
            descriptor_digest=_required_string(payload["descriptor_digest"], "publication descriptor digest"),
            descriptor_readback_digest=_required_string(
                payload["descriptor_readback_digest"], "publication descriptor readback digest"
            ),
            archives=_archives(payload["archives"]),
            publication_receipt_reference=_required_string(
                payload["publication_receipt_reference"], "publication receipt reference"
            ),
            readback_receipt_reference=_required_string(
                payload["readback_receipt_reference"], "publication readback receipt reference"
            ),
        )


@dataclass(frozen=True)
class InstallerCleanupEvidence:
    """Typed cleanup outcome; target IDs are opaque rather than filesystem paths."""

    result: str
    cleanup_receipt_reference: str
    target_ids: tuple[str, ...]

    def __post_init__(self) -> None:
        if self.result not in {"CLEANUP_PENDING", "CLEANUP_COMPLETE"}:
            raise InstallerReleaseOperationError("installer cleanup result is invalid")
        _receipt_reference(self.cleanup_receipt_reference, "cleanup receipt reference")
        object.__setattr__(self, "target_ids", _target_ids(self.target_ids))

    @classmethod
    def from_mapping(cls, value: object) -> "InstallerCleanupEvidence":
        payload = _strict_mapping(
            value,
            frozenset({"result", "cleanup_receipt_reference", "target_ids"}),
            "cleanup evidence",
        )
        return cls(
            result=_required_string(payload["result"], "cleanup result"),
            cleanup_receipt_reference=_required_string(payload["cleanup_receipt_reference"], "cleanup receipt reference"),
            target_ids=_target_ids(payload["target_ids"]),
        )


@dataclass(frozen=True)
class InstallerReleaseOperation:
    """Immutable installer identity and its separate publication lifecycle."""

    operation_id: str
    installer_version: str
    channel: str
    release_sequence: int
    source_revision: str
    policy_revision: str
    provenance_sha256: str
    release_identity: InstallerReleaseIdentity
    capabilities: tuple[str, ...]
    preparation: InstallerPreparationEvidence
    archives: Mapping[str, str]
    descriptor_digest: str
    state: str
    qualification: InstallerQualificationEvidence
    publication: InstallerPublicationEvidence | None = None
    cleanup: InstallerCleanupEvidence | None = None

    def __post_init__(self) -> None:
        if not isinstance(self.operation_id, str) or _OPERATION_ID.fullmatch(self.operation_id) is None:
            raise InstallerReleaseOperationError("installer release operation ID is invalid")
        _stable_semver(self.installer_version, "version")
        if self.channel not in _CHANNELS:
            raise InstallerReleaseOperationError("installer release channel is invalid")
        _release_sequence(self.release_sequence, "release sequence")
        if not isinstance(self.source_revision, str) or _REVISION.fullmatch(self.source_revision) is None:
            raise InstallerReleaseOperationError("installer release source revision is invalid")
        _policy_revision(self.policy_revision, "policy revision")
        _raw_sha256(self.provenance_sha256, "provenance digest")
        if not isinstance(self.release_identity, InstallerReleaseIdentity):
            raise InstallerReleaseOperationError("installer release identity is invalid")
        object.__setattr__(self, "capabilities", _capabilities(self.capabilities))
        if not isinstance(self.preparation, InstallerPreparationEvidence):
            raise InstallerReleaseOperationError("installer release preparation evidence is invalid")
        object.__setattr__(self, "archives", _archives(self.archives))
        _digest(self.descriptor_digest, "descriptor digest")
        if self.state not in _STATES:
            raise InstallerReleaseOperationError("installer release state is invalid")
        if not isinstance(self.qualification, InstallerQualificationEvidence):
            raise InstallerReleaseOperationError("installer release qualification evidence is invalid")
        self._require_bound_evidence(self.qualification)
        if self.state == "QUALIFIED":
            if self.publication is not None or self.cleanup is not None:
                raise InstallerReleaseOperationError("qualified installer release cannot include later evidence")
            return
        if not isinstance(self.publication, InstallerPublicationEvidence):
            raise InstallerReleaseOperationError("published installer release is missing publication evidence")
        self._require_bound_evidence(self.publication)
        if self.state == "PUBLISHED":
            if self.cleanup is not None:
                raise InstallerReleaseOperationError("published installer release cannot include cleanup evidence")
            return
        if not isinstance(self.cleanup, InstallerCleanupEvidence):
            raise InstallerReleaseOperationError("post-publication installer release is missing cleanup evidence")
        if self.state == "CLEANUP_PENDING" and self.cleanup.result != "CLEANUP_PENDING":
            raise InstallerReleaseOperationError("cleanup-pending installer release has wrong cleanup evidence")
        if self.state == "RELEASE_COMPLETE" and self.cleanup.result != "CLEANUP_COMPLETE":
            raise InstallerReleaseOperationError("completed installer release has wrong cleanup evidence")

    @classmethod
    def create(
        cls,
        *,
        operation_id: str,
        installer_version: str,
        channel: str,
        release_sequence: int,
        source_revision: str,
        policy_revision: str,
        provenance_sha256: str,
        release_identity: InstallerReleaseIdentity,
        capabilities: tuple[str, ...] | list[str],
        preparation: InstallerPreparationEvidence,
        archives: Mapping[str, str],
        descriptor_digest: str,
        qualification: InstallerQualificationEvidence,
    ) -> "InstallerReleaseOperation":
        """Create an already-qualified operation; qualification is a caller-owned gate."""

        return cls(
            operation_id=operation_id,
            installer_version=installer_version,
            channel=channel,
            release_sequence=release_sequence,
            source_revision=source_revision,
            policy_revision=policy_revision,
            provenance_sha256=provenance_sha256,
            release_identity=release_identity,
            capabilities=tuple(capabilities),
            preparation=preparation,
            archives=dict(archives),
            descriptor_digest=descriptor_digest,
            state="QUALIFIED",
            qualification=qualification,
        )

    @classmethod
    def parse(cls, value: object) -> "InstallerReleaseOperation":
        payload = _strict_mapping(
            value,
            frozenset({
                "operation_id", "installer_version", "channel", "release_sequence", "source_revision", "policy_revision",
                "provenance_sha256", "capabilities", "preparation", "archives",
                "release_identity", "descriptor_digest", "state", "qualification", "publication", "cleanup",
            }),
            "operation record",
        )
        qualification = InstallerQualificationEvidence.from_mapping(payload["qualification"])
        publication = None if payload["publication"] is None else InstallerPublicationEvidence.from_mapping(payload["publication"])
        cleanup = None if payload["cleanup"] is None else InstallerCleanupEvidence.from_mapping(payload["cleanup"])
        return cls(
            operation_id=_required_string(payload["operation_id"], "operation ID"),
            installer_version=_required_string(payload["installer_version"], "version"),
            channel=_required_string(payload["channel"], "channel"),
            release_sequence=_release_sequence(payload["release_sequence"], "release sequence"),
            source_revision=_required_string(payload["source_revision"], "source revision"),
            policy_revision=_required_string(payload["policy_revision"], "policy revision"),
            provenance_sha256=_raw_sha256(payload["provenance_sha256"], "provenance digest"),
            release_identity=InstallerReleaseIdentity.from_mapping(payload["release_identity"]),
            capabilities=_capabilities(payload["capabilities"]),
            preparation=InstallerPreparationEvidence.from_mapping(payload["preparation"]),
            archives=_archives(payload["archives"]),
            descriptor_digest=_required_string(payload["descriptor_digest"], "descriptor digest"),
            state=_required_string(payload["state"], "state"),
            qualification=qualification,
            publication=publication,
            cleanup=cleanup,
        )

    @property
    def release_tag(self) -> str:
        return self.release_identity.release_tag(self.installer_version)

    def _require_bound_evidence(self, evidence: InstallerQualificationEvidence | InstallerPublicationEvidence) -> None:
        if evidence.descriptor_digest != self.descriptor_digest or dict(evidence.archives) != dict(self.archives):
            raise InstallerReleaseOperationError("installer release evidence does not bind exact descriptor and archive bytes")
        if isinstance(evidence, InstallerQualificationEvidence):
            if (
                evidence.source_revision != self.source_revision
                or evidence.policy_revision != self.policy_revision
                or evidence.release_sequence != self.release_sequence
                or evidence.provenance_sha256 != self.provenance_sha256
                or (
                    evidence.release_trust_configuration_sha256
                    != self.release_identity.release_trust_configuration_sha256
                )
                or evidence.candidate_manifest_digest != self.preparation.candidate_manifest_digest
                or dict(evidence.candidate_archives) != dict(self.preparation.candidate_archives)
            ):
                raise InstallerReleaseOperationError(
                    "installer qualification evidence does not bind exact source, policy, and prepared candidate bytes"
                )
        elif (
            evidence.github_repository != self.release_identity.github_repository
            or evidence.release_tag != self.release_tag
            or evidence.policy_revision != self.policy_revision
            or evidence.release_sequence != self.release_sequence
            or evidence.provenance_sha256 != self.provenance_sha256
            or (
                evidence.release_trust_configuration_sha256
                != self.release_identity.release_trust_configuration_sha256
            )
            or evidence.descriptor_asset_name != self.release_identity.release_descriptor_asset_name
            or evidence.descriptor_readback_digest != self.descriptor_digest
        ):
            raise InstallerReleaseOperationError("installer publication evidence does not bind the canonical release identity")

    def transition(
        self,
        state: str,
        *,
        evidence: InstallerPublicationEvidence | InstallerCleanupEvidence,
    ) -> "InstallerReleaseOperation":
        """Return the next durable state after strictly typed evidence arrives."""

        if state not in _ALLOWED_TRANSITIONS.get(self.state, frozenset()):
            raise InstallerReleaseOperationError(
                f"installer release transition {self.state} -> {state} is not permitted"
            )
        if state == "PUBLISHED":
            if not isinstance(evidence, InstallerPublicationEvidence):
                raise InstallerReleaseOperationError("installer publication transition requires typed publication evidence")
            return replace(self, state=state, publication=evidence)
        else:
            if not isinstance(evidence, InstallerCleanupEvidence):
                raise InstallerReleaseOperationError("installer cleanup transition requires typed cleanup evidence")
            expected_result = "CLEANUP_PENDING" if state == "CLEANUP_PENDING" else "CLEANUP_COMPLETE"
            if evidence.result != expected_result:
                raise InstallerReleaseOperationError("installer cleanup evidence does not match the requested transition")
            return replace(self, state=state, cleanup=evidence)


def _no_follow_flag(label: str) -> int:
    """Return the required no-follow primitive, never silently weakening it."""

    nofollow = getattr(os, "O_NOFOLLOW", None)
    if nofollow is None:
        raise InstallerReleaseOperationError(f"{label} requires a platform no-follow open primitive")
    return nofollow


def _require_private_directory(status: os.stat_result, label: str) -> None:
    if (
        not stat.S_ISDIR(status.st_mode)
        or status.st_uid != os.geteuid()
        or status.st_mode & 0o022
    ):
        raise InstallerReleaseOperationError(f"{label} is unsafe")


def _require_private_regular_file(status: os.stat_result, label: str) -> None:
    if (
        not stat.S_ISREG(status.st_mode)
        or status.st_nlink != 1
        or status.st_uid != os.geteuid()
        or status.st_mode & 0o022
    ):
        raise InstallerReleaseOperationError(f"{label} is unsafe")


def _open_private_directory(
    path: Path,
    *,
    label: str,
    create: bool,
    parents: bool = False,
) -> int | None:
    """Open one journal directory without accepting a redirected leaf."""

    if create:
        try:
            path.mkdir(mode=0o700, parents=parents, exist_ok=True)
        except OSError as error:
            raise InstallerReleaseOperationError(f"{label} is unsafe or unavailable") from error
    try:
        descriptor = os.open(
            path,
            os.O_RDONLY
            | getattr(os, "O_DIRECTORY", 0)
            | _no_follow_flag(label)
            | getattr(os, "O_CLOEXEC", 0),
        )
    except FileNotFoundError:
        if not create:
            return None
        raise InstallerReleaseOperationError(f"{label} is unavailable") from None
    except OSError as error:
        raise InstallerReleaseOperationError(f"{label} is unsafe or unavailable") from error
    try:
        _require_private_directory(os.fstat(descriptor), label)
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def _read_private_json(path: Path, label: str) -> str | None:
    """Read one owned regular journal record through a no-follow descriptor."""

    directory_descriptor = _open_private_directory(
        path.parent,
        label="installer release journal record directory",
        create=False,
    )
    if directory_descriptor is None:
        return None
    descriptor = -1
    try:
        try:
            descriptor = os.open(
                path.name,
                os.O_RDONLY
                | os.O_NONBLOCK
                | _no_follow_flag(label)
                | getattr(os, "O_CLOEXEC", 0),
                dir_fd=directory_descriptor,
            )
        except FileNotFoundError:
            return None
        except OSError as error:
            raise InstallerReleaseOperationError(f"{label} is unreadable") from error
        before = os.fstat(descriptor)
        _require_private_regular_file(before, label)
        if before.st_size < 1 or before.st_size > _MAXIMUM_JOURNAL_RECORD_BYTES:
            raise InstallerReleaseOperationError(f"{label} is unreadable")
        try:
            with os.fdopen(descriptor, "rb", closefd=False) as stream:
                raw = stream.read(_MAXIMUM_JOURNAL_RECORD_BYTES + 1)
            if len(raw) > _MAXIMUM_JOURNAL_RECORD_BYTES:
                raise InstallerReleaseOperationError(f"{label} is unreadable")
            result = raw.decode("utf-8")
        except (OSError, UnicodeDecodeError) as error:
            raise InstallerReleaseOperationError(f"{label} is unreadable") from error
        after = os.fstat(descriptor)
        if (
            before.st_dev != after.st_dev
            or before.st_ino != after.st_ino
            or before.st_size != after.st_size
            or before.st_mtime_ns != after.st_mtime_ns
        ):
            raise InstallerReleaseOperationError(f"{label} changed while it was being read")
        return result
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        os.close(directory_descriptor)


def _open_temporary_record(directory_descriptor: int, name: str) -> tuple[int, str]:
    flags = (
        os.O_WRONLY
        | os.O_CREAT
        | os.O_EXCL
        | _no_follow_flag("installer release journal temporary record")
        | getattr(os, "O_CLOEXEC", 0)
    )
    for _ in range(128):
        temporary_name = f".{name}.{os.urandom(16).hex()}"
        try:
            return os.open(temporary_name, flags, 0o600, dir_fd=directory_descriptor), temporary_name
        except FileExistsError:
            continue
        except OSError as error:
            raise InstallerReleaseOperationError("installer release journal temporary record is unavailable") from error
    raise InstallerReleaseOperationError("installer release journal temporary record name could not be allocated")


def _atomic_json(path: Path, value: object) -> None:
    """Write durable non-secret evidence without a partial or redirected record."""

    directory_descriptor = _open_private_directory(
        path.parent,
        label="installer release journal record directory",
        create=True,
    )
    assert directory_descriptor is not None
    descriptor = -1
    temporary_name: str | None = None
    try:
        try:
            _require_private_regular_file(
                os.lstat(path.name, dir_fd=directory_descriptor),
                "installer release journal record",
            )
        except FileNotFoundError:
            pass
        descriptor, temporary_name = _open_temporary_record(directory_descriptor, path.name)
        _require_private_regular_file(os.fstat(descriptor), "installer release journal temporary record")
        with os.fdopen(descriptor, "w", encoding="utf-8", closefd=False) as stream:
            json.dump(value, stream, sort_keys=True, separators=(",", ":"), allow_nan=False)
            stream.write("\n")
            os.fchmod(stream.fileno(), 0o600)
            stream.flush()
            os.fsync(stream.fileno())
        os.close(descriptor)
        descriptor = -1
        os.replace(
            temporary_name,
            path.name,
            src_dir_fd=directory_descriptor,
            dst_dir_fd=directory_descriptor,
        )
        temporary_name = None
        os.fsync(directory_descriptor)
    except BaseException:
        if temporary_name is not None:
            try:
                os.unlink(temporary_name, dir_fd=directory_descriptor)
            except FileNotFoundError:
                pass
        raise
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        os.close(directory_descriptor)


class InstallerReleaseOperationStore:
    """One-at-a-time durable journal for a separately versioned installer release.

    The lock is deliberately installer-wide rather than version-local: two
    release processes cannot race to issue conflicting GitHub Release evidence
    while one process is being reconciled.  The caller owns any actual GitHub
    API invocation and must acquire this lock before it begins that side effect.
    """

    def __init__(self, root: Path) -> None:
        # Keep the configured leaf intact: ``resolve()`` would erase evidence
        # that a caller selected a redirected journal root before O_NOFOLLOW
        # can reject it in ``acquire``.
        self.root = Path(os.path.abspath(os.fspath(Path(root).expanduser())))
        self._lock_descriptor: int | None = None
        self._lock_owner: str | None = None

    def _secure_root(self, *, create: bool) -> bool:
        descriptor = _open_private_directory(
            self.root,
            label="installer release operation store root",
            create=create,
            parents=True,
        )
        if descriptor is None:
            return False
        os.close(descriptor)
        return True

    def _path(self, operation_id: str) -> Path:
        if not isinstance(operation_id, str) or _OPERATION_ID.fullmatch(operation_id) is None:
            raise InstallerReleaseOperationError("installer release operation ID is invalid")
        return self.root / "operations" / f"{operation_id}.json"

    def _preparation_path(self, operation_id: str) -> Path:
        if not isinstance(operation_id, str) or _OPERATION_ID.fullmatch(operation_id) is None:
            raise InstallerReleaseOperationError("installer preparation operation ID is invalid")
        return self.root / "preparations" / f"{operation_id}.json"

    def _sequence_path(self, release_sequence: int) -> Path:
        _release_sequence(release_sequence, "sequence reservation")
        return self.root / "sequences" / f"{release_sequence}.json"

    @property
    def _lock(self) -> Path:
        return self.root / "installer-release-operation.lock"

    def acquire(self, operation_id: str) -> None:
        self._path(operation_id)
        if self._lock_descriptor is not None:
            raise InstallerReleaseOperationError("this installer release store already owns the release lock")
        self._secure_root(create=True)
        nofollow = getattr(os, "O_NOFOLLOW", None)
        if nofollow is None:
            raise InstallerReleaseOperationError(
                "installer release operation lock requires a platform no-follow open primitive"
            )
        try:
            descriptor = os.open(
                self._lock,
                os.O_WRONLY | os.O_CREAT | nofollow | getattr(os, "O_CLOEXEC", 0),
                0o600,
            )
        except OSError as error:
            raise InstallerReleaseOperationError("installer release operation lock is unsafe or unavailable") from error
        try:
            lock_status = os.fstat(descriptor)
            if (
                not stat.S_ISREG(lock_status.st_mode)
                or lock_status.st_nlink != 1
                or lock_status.st_uid != os.geteuid()
                or lock_status.st_mode & 0o022
            ):
                raise InstallerReleaseOperationError("installer release operation lock is unsafe")
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            os.close(descriptor)
            raise InstallerReleaseOperationError("another installer release operation owns the release lock") from error
        except BaseException:
            os.close(descriptor)
            raise
        try:
            os.ftruncate(descriptor, 0)
            os.write(descriptor, (operation_id + "\n").encode("utf-8"))
            os.fsync(descriptor)
        except BaseException:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
            os.close(descriptor)
            raise
        self._lock_descriptor, self._lock_owner = descriptor, operation_id

    def release(self, operation_id: str) -> None:
        if self._lock_descriptor is None or self._lock_owner != operation_id:
            raise InstallerReleaseOperationError("installer release operation does not own the release lock")
        try:
            fcntl.flock(self._lock_descriptor, fcntl.LOCK_UN)
        finally:
            os.close(self._lock_descriptor)
            self._lock_descriptor, self._lock_owner = None, None

    def _require_lock(self, operation_id: str) -> None:
        if self._lock_descriptor is None or self._lock_owner != operation_id:
            raise InstallerReleaseOperationError("installer release operation must own the release lock")

    @staticmethod
    def _sequence_reservation_identity(
        record: InstallerReleasePreparation | InstallerReleaseOperation,
    ) -> dict[str, object]:
        """The non-secret immutable facts which consume one release sequence.

        A sequence is allocated while the unsigned candidate is durable, not
        during publication.  This prevents an interrupted or concurrent flow
        from reusing a descriptor sequence for different source, policy,
        provenance, trust configuration, or candidate bytes.
        """

        release_identity = asdict(record.release_identity)
        release_identity["signature_key_ids"] = list(record.release_identity.signature_key_ids)
        return {
            "operation_id": record.operation_id,
            "installer_version": record.installer_version,
            "channel": record.channel,
            "release_sequence": record.release_sequence,
            "source_revision": record.source_revision,
            "policy_revision": record.policy_revision,
            "provenance_sha256": record.provenance_sha256,
            "release_identity": release_identity,
            "capabilities": list(record.capabilities),
            "preparation": asdict(record.preparation),
        }

    @staticmethod
    def _parse_sequence_reservation(
        value: object,
        *,
        expected_sequence: int,
    ) -> InstallerReleasePreparation:
        """Accept only an exact immutable ``PREPARED`` reservation identity.

        A numeric filename and a matching ``release_sequence`` member are not
        enough to establish a durable frontier.  Corruption must not manufacture
        a fake high-water mark that blocks a later release or hides a malformed
        collision record.
        """

        if not isinstance(value, Mapping):
            raise InstallerReleaseOperationError("installer release sequence reservation is unreadable")
        candidate = dict(value)
        candidate["state"] = "PREPARED"
        try:
            preparation = InstallerReleasePreparation.parse(candidate)
        except InstallerReleaseOperationError as error:
            raise InstallerReleaseOperationError("installer release sequence reservation is unreadable") from error
        if preparation.release_sequence != expected_sequence:
            raise InstallerReleaseOperationError("installer release sequence reservation is unreadable")
        if dict(value) != InstallerReleaseOperationStore._sequence_reservation_identity(preparation):
            raise InstallerReleaseOperationError("installer release sequence reservation is unreadable")
        return preparation

    def _reserve_sequence(
        self,
        record: InstallerReleasePreparation | InstallerReleaseOperation,
        *,
        allow_verified_historical_recovery: bool = False,
    ) -> None:
        self._require_lock(record.operation_id)
        if allow_verified_historical_recovery and (
            not isinstance(record, InstallerReleaseOperation) or record.state != "PUBLISHED"
        ):
            raise InstallerReleaseOperationError(
                "only an externally verified published installer receipt may reserve a historical sequence"
            )
        path = self._sequence_path(record.release_sequence)
        identity = self._sequence_reservation_identity(record)
        sequence_root = path.parent
        raw = _read_private_json(path, "installer release sequence reservation")
        if raw is not None:
            try:
                existing = self._parse_sequence_reservation(
                    _strict_json_load(raw, "release sequence reservation"),
                    expected_sequence=record.release_sequence,
                )
            except InstallerReleaseOperationError as error:
                raise InstallerReleaseOperationError("installer release sequence reservation is unreadable") from error
            if self._sequence_reservation_identity(existing) != identity:
                raise InstallerReleaseOperationError(
                    "installer release sequence is already reserved by different bytes or provenance"
                )
            return
        if (
            record.release_sequence <= self._highest_reserved_sequence(sequence_root)
            and not allow_verified_historical_recovery
        ):
            raise InstallerReleaseOperationError(
                "installer release sequence must be strictly higher than every durable reservation"
            )
        _atomic_json(path, identity)

    @staticmethod
    def _highest_reserved_sequence(sequence_root: Path) -> int:
        """Read the monotonic reservation frontier without trusting filenames.

        A lower sequence would create a signed descriptor that no already
        updated installer may accept.  Unknown, unreadable, non-regular, or
        mismatched reservation records therefore block allocation rather than
        being silently ignored.
        """

        directory_descriptor = _open_private_directory(
            sequence_root,
            label="installer release sequence reservation directory",
            create=False,
        )
        if directory_descriptor is None:
            return 0
        highest = 0
        try:
            try:
                entries = os.listdir(directory_descriptor)
            except OSError as error:
                raise InstallerReleaseOperationError("installer release sequence reservations are unreadable") from error
            for name in entries:
                match = _SEQUENCE_RESERVATION_FILENAME.fullmatch(name)
                if match is None:
                    raise InstallerReleaseOperationError("installer release sequence reservation directory is unsafe")
                try:
                    _require_private_regular_file(
                        os.lstat(name, dir_fd=directory_descriptor),
                        "installer release sequence reservation",
                    )
                except OSError as error:
                    raise InstallerReleaseOperationError("installer release sequence reservation directory is unsafe") from error
                sequence = _release_sequence(int(match.group(1)), "reserved sequence")
                try:
                    raw = _read_private_json(sequence_root / name, "installer release sequence reservation")
                    if raw is None:
                        raise InstallerReleaseOperationError("installer release sequence reservation is unreadable")
                    record = InstallerReleaseOperationStore._parse_sequence_reservation(
                        _strict_json_load(raw, "release sequence reservation"),
                        expected_sequence=sequence,
                    )
                except InstallerReleaseOperationError as error:
                    raise InstallerReleaseOperationError("installer release sequence reservation is unreadable") from error
                highest = max(highest, sequence)
            return highest
        finally:
            os.close(directory_descriptor)

    def _require_sequence_frontier(self, record: InstallerReleasePreparation | InstallerReleaseOperation) -> None:
        highest = self._highest_reserved_sequence(self.root / "sequences")
        if record.release_sequence != highest:
            raise InstallerReleaseOperationError(
                "installer release sequence is no longer the durable reservation frontier"
            )

    def load(self, operation_id: str) -> InstallerReleaseOperation | None:
        path = self._path(operation_id)
        if not self._secure_root(create=False):
            return None
        try:
            raw = _read_private_json(path, "installer release operation record")
            if raw is None:
                return None
            return InstallerReleaseOperation.parse(_strict_json_load(raw, "operation record"))
        except InstallerReleaseOperationError as error:
            raise InstallerReleaseOperationError("installer release operation record is unreadable") from error

    def load_preparation(self, operation_id: str) -> InstallerReleasePreparation | None:
        path = self._preparation_path(operation_id)
        if not self._secure_root(create=False):
            return None
        try:
            raw = _read_private_json(path, "installer release preparation record")
            if raw is None:
                return None
            return InstallerReleasePreparation.parse(
                _strict_json_load(raw, "preparation record")
            )
        except InstallerReleaseOperationError as error:
            raise InstallerReleaseOperationError("installer release preparation record is unreadable") from error

    @staticmethod
    def _preparation_binds_operation(
        preparation: InstallerReleasePreparation,
        operation: InstallerReleaseOperation,
    ) -> bool:
        return (
            preparation.operation_id,
            preparation.installer_version,
            preparation.channel,
            preparation.release_sequence,
            preparation.source_revision,
            preparation.policy_revision,
            preparation.provenance_sha256,
            preparation.release_identity,
            preparation.capabilities,
            preparation.preparation,
        ) == (
            operation.operation_id,
            operation.installer_version,
            operation.channel,
            operation.release_sequence,
            operation.source_revision,
            operation.policy_revision,
            operation.provenance_sha256,
            operation.release_identity,
            operation.capabilities,
            operation.preparation,
        )

    def prepare_candidate(self, preparation: InstallerReleasePreparation) -> InstallerReleasePreparation:
        """Persist or resume immutable candidate bytes before protected signing.

        This is the only write allowed before a signer/notarizer receives an
        installer candidate.  A changed digest under the same operation ID
        fails closed rather than replacing the original candidate.
        """

        self._require_lock(preparation.operation_id)
        existing = self.load_preparation(preparation.operation_id)
        if existing is not None and existing != preparation:
            raise InstallerReleaseOperationError(
                "installer release preparation operation ID already binds different candidate bytes or provenance"
            )
        self._reserve_sequence(preparation)
        if existing is None:
            _atomic_json(self._preparation_path(preparation.operation_id), asdict(preparation))
            return preparation
        return existing

    def _save_exact(self, operation: InstallerReleaseOperation) -> InstallerReleaseOperation:
        """Persist one already-authorized record without opening a lifecycle gate."""

        self._require_lock(operation.operation_id)
        existing = self.load(operation.operation_id)
        if existing is not None and existing != operation:
            raise InstallerReleaseOperationError(
                "installer release operation record is immutable; save only an identical recovery record"
            )
        _atomic_json(self._path(operation.operation_id), asdict(operation))
        return operation

    def save(self, operation: InstallerReleaseOperation) -> InstallerReleaseOperation:
        """Persist only a qualified record that is bound to PREPARED evidence.

        Publication recovery intentionally has a separate ``recover_published``
        entry point.  Keeping this public method on the prepared path prevents
        callers from manufacturing a qualified record, then marking it
        published, without a durable candidate or sequence reservation.
        """

        self._require_lock(operation.operation_id)
        if operation.state != "QUALIFIED":
            raise InstallerReleaseOperationError(
                "only a qualified installer operation may be saved outside publication recovery"
            )
        preparation = self.load_preparation(operation.operation_id)
        if preparation is None or not self._preparation_binds_operation(preparation, operation):
            raise InstallerReleaseOperationError(
                "installer release save requires an immutable PREPARED candidate record"
            )
        self._reserve_sequence(operation)
        self._require_sequence_frontier(operation)
        return self._save_exact(operation)

    @staticmethod
    def same_identity(left: InstallerReleaseOperation, right: InstallerReleaseOperation) -> bool:
        """Compare only immutable installer facts, never mutable lifecycle evidence."""

        return (
            left.operation_id,
            left.installer_version,
            left.channel,
            left.release_sequence,
            left.source_revision,
            left.policy_revision,
            left.provenance_sha256,
            left.release_identity,
            left.capabilities,
            left.preparation,
            dict(left.archives),
            left.descriptor_digest,
        ) == (
            right.operation_id,
            right.installer_version,
            right.channel,
            right.release_sequence,
            right.source_revision,
            right.policy_revision,
            right.provenance_sha256,
            right.release_identity,
            right.capabilities,
            right.preparation,
            dict(right.archives),
            right.descriptor_digest,
        )

    def prepare_qualified(
        self,
        operation: InstallerReleaseOperation,
    ) -> InstallerReleaseOperation:
        """Persist or resume a qualification bound to a prior PREPARED record."""

        self._require_lock(operation.operation_id)
        if operation.state != "QUALIFIED":
            raise InstallerReleaseOperationError("only a qualified installer operation may begin or resume publication")
        preparation = self.load_preparation(operation.operation_id)
        if preparation is None:
            raise InstallerReleaseOperationError(
                "installer release qualification requires an immutable PREPARED candidate record"
            )
        if not self._preparation_binds_operation(preparation, operation):
            raise InstallerReleaseOperationError(
                "installer release qualification does not bind the durable PREPARED candidate record"
            )
        self._reserve_sequence(operation)
        self._require_sequence_frontier(operation)
        existing = self.load(operation.operation_id)
        if existing is None:
            return self.save(operation)
        if not self.same_identity(existing, operation):
            raise InstallerReleaseOperationError("installer release operation ID already binds different immutable identity")
        if existing.qualification != operation.qualification:
            raise InstallerReleaseOperationError("installer release qualification evidence changed during recovery")
        return existing

    def mark_published(
        self,
        operation: InstallerReleaseOperation,
        *,
        evidence: InstallerPublicationEvidence,
    ) -> InstallerReleaseOperation:
        """Record verified GitHub Release publication/readback under exact identity."""

        self._require_lock(operation.operation_id)
        self._require_sequence_frontier(operation)
        current = self.load(operation.operation_id)
        if current is None or not self.same_identity(current, operation):
            raise InstallerReleaseOperationError("installer release operation does not bind the exact requested identity")
        if current.qualification != operation.qualification:
            raise InstallerReleaseOperationError("installer release qualification evidence changed during recovery")
        if current.state == "QUALIFIED":
            proposed = current.transition("PUBLISHED", evidence=evidence)
            self._assert_publication_available(proposed)
            current = self.replace(current, proposed)
        elif current.state not in {"PUBLISHED", "CLEANUP_PENDING", "RELEASE_COMPLETE"}:
            raise InstallerReleaseOperationError("installer release operation cannot be published from its current state")
        elif current.publication != evidence:
            raise InstallerReleaseOperationError("installer publication evidence changed during recovery")
        self.record_publication(current)
        return current

    def recover_published(self, published: InstallerReleaseOperation) -> InstallerReleaseOperation:
        """Seed a lost local journal only from the exact verified ``PUBLISHED`` receipt.

        Callers must verify the externally retained GitHub Release receipt before
        constructing ``published``.  This method does not treat a network reply
        or GitHub's mutable ``latest`` marker as durable evidence.
        """

        self._require_lock(published.operation_id)
        if published.state != "PUBLISHED":
            raise InstallerReleaseOperationError("only a published installer receipt can seed recovery")
        # A verified external receipt may arrive after a newer candidate has
        # already reserved a sequence locally.  Recovery records that historic
        # publication; it does not initiate or authorize a lower publication.
        self._reserve_sequence(published, allow_verified_historical_recovery=True)
        self._assert_publication_available(published)
        current = self.load(published.operation_id)
        if current is None:
            current = self._save_exact(published)
        elif (
            not self.same_identity(current, published)
            or current.qualification != published.qualification
            or current.publication != published.publication
        ):
            raise InstallerReleaseOperationError("durable installer release evidence does not match the published receipt")
        if current.state not in {"PUBLISHED", "CLEANUP_PENDING"}:
            raise InstallerReleaseOperationError("durable installer release evidence is not resumable")
        self.record_publication(current)
        return current

    def mark_cleanup_pending(
        self,
        operation: InstallerReleaseOperation,
        *,
        evidence: InstallerCleanupEvidence,
    ) -> InstallerReleaseOperation:
        """Persist a failed operation-scoped cleanup for controlled retry."""

        self._require_lock(operation.operation_id)
        current = self.load(operation.operation_id)
        if current is None or not self.same_identity(current, operation):
            raise InstallerReleaseOperationError("installer release operation does not bind the exact requested identity")
        if current.qualification != operation.qualification or (
            operation.publication is not None and current.publication != operation.publication
        ):
            raise InstallerReleaseOperationError("installer release evidence changed during recovery")
        if current.state == "PUBLISHED":
            return self.replace(current, current.transition("CLEANUP_PENDING", evidence=evidence))
        if current.state == "CLEANUP_PENDING" and current.cleanup == evidence:
            return current
        raise InstallerReleaseOperationError("installer release operation cannot record this cleanup-pending result")

    def complete(
        self,
        operation: InstallerReleaseOperation,
        *,
        evidence: InstallerCleanupEvidence,
    ) -> InstallerReleaseOperation:
        """Terminalize only after typed operation-scoped cleanup evidence arrives."""

        self._require_lock(operation.operation_id)
        current = self.load(operation.operation_id)
        if current is None or not self.same_identity(current, operation):
            raise InstallerReleaseOperationError("installer release operation does not bind the exact requested identity")
        if current.qualification != operation.qualification or (
            operation.publication is not None and current.publication != operation.publication
        ):
            raise InstallerReleaseOperationError("installer release evidence changed during recovery")
        if current.state in {"PUBLISHED", "CLEANUP_PENDING"}:
            current = self.replace(current, current.transition("RELEASE_COMPLETE", evidence=evidence))
        elif current.state != "RELEASE_COMPLETE" or current.cleanup != evidence:
            raise InstallerReleaseOperationError("installer release operation cannot complete from its current state")
        self.record_publication(current)
        return current

    def replace(
        self,
        previous: InstallerReleaseOperation,
        current: InstallerReleaseOperation,
    ) -> InstallerReleaseOperation:
        self._require_lock(previous.operation_id)
        if not self.same_identity(previous, current) or self.load(previous.operation_id) != previous:
            raise InstallerReleaseOperationError("installer release operation changed before transition")
        _atomic_json(self._path(current.operation_id), asdict(current))
        return current

    def record_publication(self, operation: InstallerReleaseOperation) -> None:
        """Reserve a GitHub tag identity; changed bytes/provenance fail closed."""

        self._require_lock(operation.operation_id)
        if operation.state not in {"PUBLISHED", "CLEANUP_PENDING", "RELEASE_COMPLETE"}:
            raise InstallerReleaseOperationError("only a published installer release may reserve its immutable identity")
        path, identity = self._publication_path_and_identity(operation)
        if _read_private_json(path, "published installer release identity") is not None:
            self._assert_publication_available(operation)
            return
        _atomic_json(path, identity)

    def _assert_publication_available(self, operation: InstallerReleaseOperation) -> None:
        """Read an existing tag reservation before any local state transition."""

        path, identity = self._publication_path_and_identity(operation)
        try:
            raw = _read_private_json(path, "published installer release identity")
        except InstallerReleaseOperationError as error:
            raise InstallerReleaseOperationError("published installer release identity is unreadable") from error
        if raw is None:
            return
        try:
            existing = _strict_json_load(raw, "published installer identity")
        except InstallerReleaseOperationError as error:
            raise InstallerReleaseOperationError("published installer release identity is unreadable") from error
        if existing != identity:
            raise InstallerReleaseOperationError(
                "published installer release identity already exists with different bytes or provenance"
            )

    def _publication_path_and_identity(
        self,
        operation: InstallerReleaseOperation,
    ) -> tuple[Path, dict[str, object]]:
        if operation.state not in {"PUBLISHED", "CLEANUP_PENDING", "RELEASE_COMPLETE"}:
            raise InstallerReleaseOperationError("only a published installer release may reserve its immutable identity")
        release_identity = asdict(operation.release_identity)
        release_identity["signature_key_ids"] = list(operation.release_identity.signature_key_ids)
        return self.root / "published" / f"{operation.installer_version}.json", {
            "operation_id": operation.operation_id,
            "installer_version": operation.installer_version,
            "channel": operation.channel,
            "release_sequence": operation.release_sequence,
            "source_revision": operation.source_revision,
            "policy_revision": operation.policy_revision,
            "provenance_sha256": operation.provenance_sha256,
            "release_identity": release_identity,
            "capabilities": list(operation.capabilities),
            "preparation": asdict(operation.preparation),
            "archives": dict(operation.archives),
            "descriptor_digest": operation.descriptor_digest,
            "publication": asdict(operation.publication),
        }
