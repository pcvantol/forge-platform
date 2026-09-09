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
import tempfile
from typing import Mapping


_OPERATION_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{7,127}$")
_SEMVER = re.compile(r"^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)$")
_REVISION = re.compile(r"^[0-9a-f]{40,64}$")
_SHA256 = re.compile(r"^sha256:[0-9a-f]{64}$")
_CAPABILITY = re.compile(r"^[a-z0-9][a-z0-9./_-]{0,127}$")
_RECEIPT_REFERENCE = re.compile(r"^receipt:[a-z0-9][a-z0-9._-]{0,127}$")
_TARGET_ID = re.compile(r"^[a-z0-9][a-z0-9._-]{0,127}$")
_BUNDLE_IDENTIFIER = re.compile(r"^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$")
_TEAM_IDENTIFIER = re.compile(r"^[A-Z0-9]{10}$")
_GITHUB_REPOSITORY = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
_RELEASE_TAG_PREFIX = re.compile(r"^[a-z0-9][a-z0-9._-]*$")
_ASSET_PREFIX = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
_SIGNING_KEY_ID = re.compile(r"^[a-z0-9][a-z0-9._-]{0,127}$")
_POLICY_REVISION = re.compile(r"^[a-z0-9][a-z0-9._/-]{0,127}$")
_ARCHITECTURES = frozenset({"arm64", "x86_64"})
_CHANNELS = frozenset({"stable", "candidate"})
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
            signature_algorithm=_required_string(payload["signature_algorithm"], "signature algorithm"),
            signature_key_ids=tuple(key_ids),
            signature_threshold=payload["signature_threshold"],
        )

    def release_tag(self, version: str) -> str:
        if _SEMVER.fullmatch(version) is None:
            raise InstallerReleaseOperationError("installer release version is invalid")
        return f"{self.release_tag_prefix}{version}"

    def asset_name(self, architecture: str) -> str:
        if architecture not in _ARCHITECTURES:
            raise InstallerReleaseOperationError("installer release archive architecture is unsupported")
        return f"{self.asset_prefix}{architecture}.zip"


@dataclass(frozen=True)
class InstallerQualificationEvidence:
    """Typed qualification receipt with no command output, path, or credentials."""

    source_revision: str
    policy_revision: str
    descriptor_digest: str
    archives: Mapping[str, str]
    qualification_receipt_reference: str
    result: str = "QUALIFIED"

    def __post_init__(self) -> None:
        if self.result != "QUALIFIED":
            raise InstallerReleaseOperationError("installer qualification result is invalid")
        if not isinstance(self.source_revision, str) or _REVISION.fullmatch(self.source_revision) is None:
            raise InstallerReleaseOperationError("installer qualification source revision is invalid")
        _policy_revision(self.policy_revision, "qualification policy revision")
        _digest(self.descriptor_digest, "qualification descriptor digest")
        object.__setattr__(self, "archives", _archives(self.archives))
        _receipt_reference(self.qualification_receipt_reference, "qualification receipt reference")

    @classmethod
    def from_mapping(cls, value: object) -> "InstallerQualificationEvidence":
        payload = _strict_mapping(
            value,
            frozenset({"result", "source_revision", "policy_revision", "descriptor_digest", "archives", "qualification_receipt_reference"}),
            "qualification evidence",
        )
        return cls(
            result=_required_string(payload["result"], "qualification result"),
            source_revision=_required_string(payload["source_revision"], "qualification source revision"),
            policy_revision=_required_string(payload["policy_revision"], "qualification policy revision"),
            descriptor_digest=_required_string(payload["descriptor_digest"], "qualification descriptor digest"),
            archives=_archives(payload["archives"]),
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
    descriptor_digest: str
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
        _digest(self.descriptor_digest, "publication descriptor digest")
        object.__setattr__(self, "archives", _archives(self.archives))
        _receipt_reference(self.publication_receipt_reference, "publication receipt reference")
        _receipt_reference(self.readback_receipt_reference, "publication readback receipt reference")

    @classmethod
    def from_mapping(cls, value: object) -> "InstallerPublicationEvidence":
        payload = _strict_mapping(
            value,
            frozenset({
                "result", "github_repository", "release_tag", "policy_revision", "descriptor_digest", "archives", "publication_receipt_reference",
                "readback_receipt_reference",
            }),
            "publication evidence",
        )
        return cls(
            result=_required_string(payload["result"], "publication result"),
            github_repository=_required_string(payload["github_repository"], "publication GitHub repository"),
            release_tag=_required_string(payload["release_tag"], "publication release tag"),
            policy_revision=_required_string(payload["policy_revision"], "publication policy revision"),
            descriptor_digest=_required_string(payload["descriptor_digest"], "publication descriptor digest"),
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
    source_revision: str
    policy_revision: str
    release_identity: InstallerReleaseIdentity
    capabilities: tuple[str, ...]
    archives: Mapping[str, str]
    descriptor_digest: str
    state: str
    qualification: InstallerQualificationEvidence
    publication: InstallerPublicationEvidence | None = None
    cleanup: InstallerCleanupEvidence | None = None

    def __post_init__(self) -> None:
        if not isinstance(self.operation_id, str) or _OPERATION_ID.fullmatch(self.operation_id) is None:
            raise InstallerReleaseOperationError("installer release operation ID is invalid")
        if not isinstance(self.installer_version, str) or _SEMVER.fullmatch(self.installer_version) is None:
            raise InstallerReleaseOperationError("installer release version is invalid")
        if self.channel not in _CHANNELS:
            raise InstallerReleaseOperationError("installer release channel is invalid")
        if not isinstance(self.source_revision, str) or _REVISION.fullmatch(self.source_revision) is None:
            raise InstallerReleaseOperationError("installer release source revision is invalid")
        _policy_revision(self.policy_revision, "policy revision")
        if not isinstance(self.release_identity, InstallerReleaseIdentity):
            raise InstallerReleaseOperationError("installer release identity is invalid")
        object.__setattr__(self, "capabilities", _capabilities(self.capabilities))
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
        source_revision: str,
        policy_revision: str,
        release_identity: InstallerReleaseIdentity,
        capabilities: tuple[str, ...] | list[str],
        archives: Mapping[str, str],
        descriptor_digest: str,
        qualification: InstallerQualificationEvidence,
    ) -> "InstallerReleaseOperation":
        """Create an already-qualified operation; qualification is a caller-owned gate."""

        return cls(
            operation_id=operation_id,
            installer_version=installer_version,
            channel=channel,
            source_revision=source_revision,
            policy_revision=policy_revision,
            release_identity=release_identity,
            capabilities=tuple(capabilities),
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
                "operation_id", "installer_version", "channel", "source_revision", "policy_revision", "capabilities", "archives",
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
            source_revision=_required_string(payload["source_revision"], "source revision"),
            policy_revision=_required_string(payload["policy_revision"], "policy revision"),
            release_identity=InstallerReleaseIdentity.from_mapping(payload["release_identity"]),
            capabilities=_capabilities(payload["capabilities"]),
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
            ):
                raise InstallerReleaseOperationError("installer qualification evidence does not bind exact source revision and policy")
        elif (
            evidence.github_repository != self.release_identity.github_repository
            or evidence.release_tag != self.release_tag
            or evidence.policy_revision != self.policy_revision
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


def _atomic_json(path: Path, value: object) -> None:
    """Write durable non-secret evidence without a partially written record."""

    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(value, stream, sort_keys=True, separators=(",", ":"), allow_nan=False)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary_name, 0o600)
        os.replace(temporary_name, path)
        directory_descriptor = os.open(path.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            os.fsync(directory_descriptor)
        finally:
            os.close(directory_descriptor)
    except BaseException:
        Path(temporary_name).unlink(missing_ok=True)
        raise


class InstallerReleaseOperationStore:
    """One-at-a-time durable journal for a separately versioned installer release.

    The lock is deliberately installer-wide rather than version-local: two
    release processes cannot race to issue conflicting GitHub Release evidence
    while one process is being reconciled.  The caller owns any actual GitHub
    API invocation and must acquire this lock before it begins that side effect.
    """

    def __init__(self, root: Path) -> None:
        self.root = Path(root).expanduser().resolve()
        self._lock_descriptor: int | None = None
        self._lock_owner: str | None = None

    def _path(self, operation_id: str) -> Path:
        if not isinstance(operation_id, str) or _OPERATION_ID.fullmatch(operation_id) is None:
            raise InstallerReleaseOperationError("installer release operation ID is invalid")
        return self.root / "operations" / f"{operation_id}.json"

    @property
    def _lock(self) -> Path:
        return self.root / "installer-release-operation.lock"

    def acquire(self, operation_id: str) -> None:
        self._path(operation_id)
        if self._lock_descriptor is not None:
            raise InstallerReleaseOperationError("this installer release store already owns the release lock")
        self.root.mkdir(mode=0o700, parents=True, exist_ok=True)
        descriptor = os.open(self._lock, os.O_WRONLY | os.O_CREAT, 0o600)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            os.close(descriptor)
            raise InstallerReleaseOperationError("another installer release operation owns the release lock") from error
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

    def load(self, operation_id: str) -> InstallerReleaseOperation | None:
        path = self._path(operation_id)
        if not path.exists():
            return None
        try:
            return InstallerReleaseOperation.parse(_strict_json_load(path.read_text(encoding="utf-8"), "operation record"))
        except (OSError, InstallerReleaseOperationError) as error:
            raise InstallerReleaseOperationError("installer release operation record is unreadable") from error

    def save(self, operation: InstallerReleaseOperation) -> InstallerReleaseOperation:
        self._require_lock(operation.operation_id)
        existing = self.load(operation.operation_id)
        if existing is not None and existing != operation:
            raise InstallerReleaseOperationError(
                "installer release operation record is immutable; save only an identical recovery record"
            )
        _atomic_json(self._path(operation.operation_id), asdict(operation))
        return operation

    @staticmethod
    def same_identity(left: InstallerReleaseOperation, right: InstallerReleaseOperation) -> bool:
        """Compare only immutable installer facts, never mutable lifecycle evidence."""

        return (
            left.operation_id,
            left.installer_version,
            left.channel,
            left.source_revision,
            left.policy_revision,
            left.release_identity,
            left.capabilities,
            dict(left.archives),
            left.descriptor_digest,
        ) == (
            right.operation_id,
            right.installer_version,
            right.channel,
            right.source_revision,
            right.policy_revision,
            right.release_identity,
            right.capabilities,
            dict(right.archives),
            right.descriptor_digest,
        )

    def prepare_qualified(
        self,
        operation: InstallerReleaseOperation,
    ) -> InstallerReleaseOperation:
        """Persist or resume exactly one already-qualified installer identity."""

        self._require_lock(operation.operation_id)
        if operation.state != "QUALIFIED":
            raise InstallerReleaseOperationError("only a qualified installer operation may begin or resume publication")
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
        self._assert_publication_available(published)
        current = self.load(published.operation_id)
        if current is None:
            current = self.save(published)
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
        if path.exists():
            self._assert_publication_available(operation)
            return
        _atomic_json(path, identity)

    def _assert_publication_available(self, operation: InstallerReleaseOperation) -> None:
        """Read an existing tag reservation before any local state transition."""

        path, identity = self._publication_path_and_identity(operation)
        if not path.exists():
            return
        try:
            existing = _strict_json_load(path.read_text(encoding="utf-8"), "published installer identity")
        except (OSError, InstallerReleaseOperationError) as error:
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
            "source_revision": operation.source_revision,
            "policy_revision": operation.policy_revision,
            "release_identity": release_identity,
            "capabilities": list(operation.capabilities),
            "archives": dict(operation.archives),
            "descriptor_digest": operation.descriptor_digest,
            "publication": asdict(operation.publication),
        }
