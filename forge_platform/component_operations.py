"""Evidence-bound delegation for product-owned component operations.

Forge Platform can select a qualified component artifact and coordinate a
product operation. It must not become a second product installer: the
delegated adapter owns target runtime selection, service changes, data,
migrations, backups and rollback semantics.
"""

from __future__ import annotations

from dataclasses import dataclass
from hashlib import sha256
import json
from typing import Mapping, Protocol


COMPONENT_IDENTITIES = frozenset({
    "forge-runtime", "workspace-server", "workspace-client",
    "engineering-platform-server", "engineering-platform-project-agent",
})
OPERATION_KINDS = frozenset({"install", "update", "repair", "rollback"})
TERMINAL_PRODUCT_STATES = frozenset({"COMPLETED", "CLEANUP_PENDING", "RECOVERY_PENDING", "FAILED"})

# These are product-runtime concerns. An opaque public product contract may
# carry its own domain fields, but the universal coordinator cannot accept a
# direct instruction to operate on them.
FORBIDDEN_DELEGATION_KEYS = frozenset({
    "backup_path", "central", "command", "data_root", "database",
    "database_path", "environment", "interpreter", "migration", "path",
    "runtime", "service_label",
})


def _require(value: str, label: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{label} is required")
    return value


def _validate_delegation(value: object) -> None:
    if isinstance(value, Mapping):
        for key, nested in value.items():
            if not isinstance(key, str):
                raise ValueError("delegation keys must be strings")
            normalized_key = key.lower()
            if normalized_key in FORBIDDEN_DELEGATION_KEYS:
                raise ValueError(f"delegation cannot contain product-runtime key: {normalized_key}")
            _validate_delegation(nested)
    elif isinstance(value, (list, tuple)):
        for nested in value:
            _validate_delegation(nested)
    elif value is not None and not isinstance(value, (str, int, float, bool)):
        raise ValueError("delegation values must be JSON-compatible")


def _canonical_delegation(value: Mapping[str, object]) -> str:
    """Make every public product selection part of the retry identity."""
    try:
        return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True)
    except (TypeError, ValueError) as error:  # defensive for exotic Mapping implementations
        raise ValueError("product_request must be JSON-compatible") from error


@dataclass(frozen=True)
class QualifiedArtifact:
    """Artifact identity independently qualified by its producing product."""

    version: str
    source_revision: str
    source: str
    digest: str
    qualification: str

    def __post_init__(self) -> None:
        for label in ("version", "source_revision", "source", "qualification"):
            _require(getattr(self, label), label)
        if not isinstance(self.digest, str) or not self.digest.startswith("sha256:"):
            raise ValueError("artifact digest must be a sha256 identity")
        digest_hex = self.digest.removeprefix("sha256:")
        if len(digest_hex) != 64 or any(character not in "0123456789abcdef" for character in digest_hex):
            raise ValueError("artifact sha256 digest must contain 64 lowercase hexadecimal bytes")


@dataclass(frozen=True)
class ComponentOperationRequest:
    """A coordinator request that can safely be passed to a product adapter."""

    operation_id: str
    component: str
    kind: str
    artifact: QualifiedArtifact
    requested_role: str
    product_request: Mapping[str, object]

    def __post_init__(self) -> None:
        _require(self.operation_id, "operation_id")
        if self.component not in COMPONENT_IDENTITIES:
            raise ValueError(f"unknown component identity: {self.component}")
        if self.kind not in OPERATION_KINDS:
            raise ValueError(f"unsupported operation kind: {self.kind}")
        _require(self.requested_role, "requested_role")
        if not isinstance(self.product_request, Mapping):
            raise ValueError("product_request must be a mapping")
        _validate_delegation(self.product_request)

    def fingerprint(self) -> str:
        """Stable retry identity, including the product's public selection."""
        material = "\x1f".join((
            self.operation_id, self.component, self.kind, self.requested_role,
            self.artifact.version, self.artifact.source_revision,
            self.artifact.digest, self.artifact.qualification,
            _canonical_delegation(self.product_request),
        ))
        return sha256(material.encode("utf-8")).hexdigest()


@dataclass(frozen=True)
class ProductOperationReceipt:
    """Product-owned result, retained verbatim rather than reinterpreted."""

    product_operation_id: str
    state: str
    evidence_reference: str

    def __post_init__(self) -> None:
        _require(self.product_operation_id, "product_operation_id")
        if self.state not in TERMINAL_PRODUCT_STATES:
            raise ValueError(f"unsupported product operation state: {self.state}")
        _require(self.evidence_reference, "evidence_reference")


class ProductOperationAdapter(Protocol):
    """Public product boundary; implementations reside with the product."""

    def execute(self, request: ComponentOperationRequest) -> ProductOperationReceipt:
        """Perform the product-owned operation for the exact requested artifact."""


@dataclass(frozen=True)
class ComponentOperationRecord:
    """Forge Platform's coordination view, not an installation record."""

    operation_id: str
    request_fingerprint: str
    product_receipt: ProductOperationReceipt


class ComponentOperationCoordinator:
    """Idempotently delegates evidence-bound component operations in-process.

    Persistence and inter-process locking are deployment adapters that will be
    added with the concrete installer. This kernel ensures retries in one
    coordinator cannot silently select different artifact bytes.
    """

    def __init__(self) -> None:
        self._records: dict[str, ComponentOperationRecord] = {}

    def delegate(self, request: ComponentOperationRequest, adapter: ProductOperationAdapter) -> ComponentOperationRecord:
        fingerprint = request.fingerprint()
        existing = self._records.get(request.operation_id)
        if existing:
            if existing.request_fingerprint != fingerprint:
                raise RuntimeError("operation ID already binds a different component artifact or action")
            return existing
        receipt = adapter.execute(request)
        if not isinstance(receipt, ProductOperationReceipt):
            raise TypeError("product adapter must return ProductOperationReceipt")
        record = ComponentOperationRecord(request.operation_id, fingerprint, receipt)
        self._records[request.operation_id] = record
        return record
