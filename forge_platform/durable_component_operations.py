"""Durable, product-bound coordination records for component delegation."""

from __future__ import annotations

from contextlib import contextmanager
from dataclasses import asdict
import fcntl
from hashlib import sha256
import json
import os
from pathlib import Path
import re
import tempfile
from typing import Any, Iterator, Mapping

from .component_operations import (
    ComponentOperationCoordinator,
    ComponentOperationRecord,
    ComponentOperationRequest,
    ProductInstallationReadback,
    ProductOperationAdapter,
    ProductOperationReceipt,
    ProductUpdateAssessment,
    QualifiedArtifact,
    RESUMABLE_PRODUCT_STATES,
)


_SAFE_OPERATION_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
_ARTIFACT_FIELDS = frozenset({"version", "source_revision", "source", "digest", "qualification"})
_READBACK_FIELDS = frozenset({
    "component", "installation_identity", "state", "selected_runtime_identity",
    "selected_executable_identity", "selected_server_identity", "selected_instance_identity",
    "artifact", "health_state", "inventory_coverage", "conflict_state",
    "evidence_reference", "health_evidence_reference", "conflict_evidence_reference",
})
_UPDATE_ASSESSMENT_FIELDS = frozenset({
    "component", "installation_identity", "candidate_artifact", "state", "evidence_reference",
})
_RECEIPT_FIELDS = frozenset({
    "product_operation_id", "component", "installation_identity", "artifact", "state",
    "evidence_reference", "cleanup_evidence_reference",
})
_RECORD_FIELDS = frozenset({
    "operation_id", "request_fingerprint", "update_assessment", "preflight", "product_receipt",
    "postflight", "prior_product_receipts",
})


class DurableComponentOperationCoordinator(ComponentOperationCoordinator):
    """Persist non-secret coordination evidence without replacing a product lock.

    The target lock prevents this Forge Platform process family from dispatching
    two operations for one component/install identity at the same time.  It is
    a coordination throttle, not an installation lock: the product provisioner
    remains authoritative for cross-client serialization and reboot recovery.
    """

    def __init__(self, operations_root: Path) -> None:
        super().__init__()
        if not operations_root.is_absolute():
            raise ValueError("operations_root must be absolute")
        self.operations_root = operations_root.resolve(strict=False)

    def delegate(self, request: ComponentOperationRequest, adapter: ProductOperationAdapter) -> ComponentOperationRecord:
        target_lock = self._target_lock_path(request)
        with self._lock(target_lock, "component target operation is already in progress"):
            operation_directory = self._operation_directory(request.operation_id)
            operation_directory.mkdir(parents=True, exist_ok=True, mode=0o700)
            with self._lock(operation_directory / ".lock"):
                existing = self._read(operation_directory / "record.json", request.operation_id)
                fingerprint = request.fingerprint()
                if existing:
                    if existing.request_fingerprint != fingerprint:
                        raise RuntimeError("operation ID already binds a different component selection")
                    if existing.product_receipt.state in RESUMABLE_PRODUCT_STATES:
                        record = self._resume_once(request, existing, adapter)
                        self._write(operation_directory / "record.json", record)
                        return record
                    return existing
                pending = self._pending_durable_target_operation(request)
                if pending:
                    raise RuntimeError(
                        f"product target has resumable operation {pending.operation_id}; resume it before another dispatch"
                    )
                record = self._delegate_once(request, adapter)
                self._write(operation_directory / "record.json", record)
                return record

    def _operation_directory(self, operation_id: str) -> Path:
        if operation_id in {".", ".."} or not _SAFE_OPERATION_ID.fullmatch(operation_id):
            raise ValueError("operation_id must be a safe relative identifier")
        return self.operations_root / operation_id

    def _target_lock_path(self, request: ComponentOperationRequest) -> Path:
        targets_root = self.operations_root / ".targets"
        targets_root.mkdir(parents=True, exist_ok=True, mode=0o700)
        material = "\x1f".join((request.component, request.installation_identity)).encode("utf-8")
        return targets_root / f"{sha256(material).hexdigest()}.lock"

    def _pending_durable_target_operation(self, request: ComponentOperationRequest) -> ComponentOperationRecord | None:
        if not self.operations_root.exists():
            return None
        for operation_directory in self.operations_root.iterdir():
            if not operation_directory.is_dir() or operation_directory.name == ".targets":
                continue
            record = self._read(operation_directory / "record.json", operation_directory.name)
            if (
                record is not None
                and record.operation_id != request.operation_id
                and record.product_receipt.state in RESUMABLE_PRODUCT_STATES
                and self._same_target(record, request)
            ):
                return record
        return None

    @staticmethod
    @contextmanager
    def _lock(path: Path, contention_message: str = "component operation is already in progress") -> Iterator[None]:
        descriptor = os.open(path, os.O_CREAT | os.O_RDWR, 0o600)
        try:
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise RuntimeError(contention_message) from error
            yield
        finally:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
            os.close(descriptor)

    @classmethod
    def _read(cls, path: Path, expected_operation_id: str | None = None) -> ComponentOperationRecord | None:
        if not path.exists():
            return None
        try:
            payload = cls._mapping(
                json.loads(path.read_text(encoding="utf-8"), parse_constant=cls._reject_nonfinite_json),
                _RECORD_FIELDS,
            )
            operation_id = payload["operation_id"]
            if expected_operation_id is not None and operation_id != expected_operation_id:
                raise ValueError("record operation ID does not match its directory")
            prior_payloads = payload["prior_product_receipts"]
            if not isinstance(prior_payloads, list):
                raise ValueError("prior_product_receipts must be a list")
            return ComponentOperationRecord(
                operation_id,
                payload["request_fingerprint"],
                cls._read_update_assessment(payload["update_assessment"]),
                cls._read_installation_readback(payload["preflight"]),
                cls._read_receipt(payload["product_receipt"]),
                cls._read_installation_readback(payload["postflight"]),
                tuple(cls._read_receipt(item) for item in prior_payloads),
            )
        except (KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
            raise RuntimeError("durable component operation record is invalid") from error

    @staticmethod
    def _reject_nonfinite_json(value: str) -> None:
        raise ValueError(f"non-finite JSON value is not permitted: {value}")

    @staticmethod
    def _mapping(value: object, expected_fields: frozenset[str]) -> Mapping[str, Any]:
        if not isinstance(value, dict) or set(value) != expected_fields:
            raise ValueError("record object fields are invalid")
        return value

    @classmethod
    def _read_artifact(cls, value: object) -> QualifiedArtifact:
        return QualifiedArtifact(**cls._mapping(value, _ARTIFACT_FIELDS))

    @classmethod
    def _read_installation_readback(cls, value: object) -> ProductInstallationReadback:
        payload = dict(cls._mapping(value, _READBACK_FIELDS))
        artifact = payload["artifact"]
        payload["artifact"] = None if artifact is None else cls._read_artifact(artifact)
        return ProductInstallationReadback(**payload)

    @classmethod
    def _read_update_assessment(cls, value: object) -> ProductUpdateAssessment | None:
        if value is None:
            return None
        payload = dict(cls._mapping(value, _UPDATE_ASSESSMENT_FIELDS))
        payload["candidate_artifact"] = cls._read_artifact(payload["candidate_artifact"])
        return ProductUpdateAssessment(**payload)

    @classmethod
    def _read_receipt(cls, value: object) -> ProductOperationReceipt:
        payload = dict(cls._mapping(value, _RECEIPT_FIELDS))
        payload["artifact"] = cls._read_artifact(payload["artifact"])
        return ProductOperationReceipt(**payload)

    @staticmethod
    def _write(path: Path, record: ComponentOperationRecord) -> None:
        payload = {
            "operation_id": record.operation_id,
            "request_fingerprint": record.request_fingerprint,
            "update_assessment": None if record.update_assessment is None else asdict(record.update_assessment),
            "preflight": asdict(record.preflight),
            "product_receipt": asdict(record.product_receipt),
            "postflight": asdict(record.postflight),
            "prior_product_receipts": [asdict(receipt) for receipt in record.prior_product_receipts],
        }
        descriptor, temporary_name = tempfile.mkstemp(prefix=".record-", dir=path.parent)
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
                json.dump(payload, handle, sort_keys=True, separators=(",", ":"), allow_nan=False)
                handle.write("\n")
                handle.flush()
                os.fsync(handle.fileno())
            os.chmod(temporary_name, 0o600)
            os.replace(temporary_name, path)
        finally:
            if os.path.exists(temporary_name):
                os.unlink(temporary_name)
