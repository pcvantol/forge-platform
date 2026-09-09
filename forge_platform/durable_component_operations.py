"""Durable, per-operation coordination records for product delegation."""

from __future__ import annotations

from contextlib import contextmanager
from dataclasses import asdict
import fcntl
import json
import os
from pathlib import Path
import re
import tempfile
from typing import Iterator

from .component_operations import (
    ComponentOperationCoordinator,
    ComponentOperationRecord,
    ComponentOperationRequest,
    ProductOperationAdapter,
    ProductOperationReceipt,
)


_SAFE_OPERATION_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")


class DurableComponentOperationCoordinator(ComponentOperationCoordinator):
    """Persist coordination receipts without persisting product secrets/payloads."""

    def __init__(self, operations_root: Path) -> None:
        super().__init__()
        if not operations_root.is_absolute():
            raise ValueError("operations_root must be absolute")
        self.operations_root = operations_root.resolve(strict=False)

    def delegate(self, request: ComponentOperationRequest, adapter: ProductOperationAdapter) -> ComponentOperationRecord:
        operation_directory = self._operation_directory(request.operation_id)
        operation_directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        with self._lock(operation_directory / ".lock"):
            existing = self._read(operation_directory / "record.json")
            fingerprint = request.fingerprint()
            if existing:
                if existing.request_fingerprint != fingerprint:
                    raise RuntimeError("operation ID already binds a different component selection")
                return existing
            receipt = adapter.execute(request)
            if not isinstance(receipt, ProductOperationReceipt):
                raise TypeError("product adapter must return ProductOperationReceipt")
            record = ComponentOperationRecord(request.operation_id, fingerprint, receipt)
            self._write(operation_directory / "record.json", record)
            return record

    def _operation_directory(self, operation_id: str) -> Path:
        if not _SAFE_OPERATION_ID.fullmatch(operation_id):
            raise ValueError("operation_id must be a safe relative identifier")
        return self.operations_root / operation_id

    @staticmethod
    @contextmanager
    def _lock(path: Path) -> Iterator[None]:
        descriptor = os.open(path, os.O_CREAT | os.O_RDWR, 0o600)
        try:
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise RuntimeError("component operation is already in progress") from error
            yield
        finally:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
            os.close(descriptor)

    @staticmethod
    def _read(path: Path) -> ComponentOperationRecord | None:
        if not path.exists():
            return None
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
            receipt = ProductOperationReceipt(**payload["product_receipt"])
            return ComponentOperationRecord(payload["operation_id"], payload["request_fingerprint"], receipt)
        except (KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
            raise RuntimeError("durable component operation record is invalid") from error

    @staticmethod
    def _write(path: Path, record: ComponentOperationRecord) -> None:
        payload = {
            "operation_id": record.operation_id,
            "request_fingerprint": record.request_fingerprint,
            "product_receipt": asdict(record.product_receipt),
        }
        descriptor, temporary_name = tempfile.mkstemp(prefix=".record-", dir=path.parent)
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
                json.dump(payload, handle, sort_keys=True, separators=(",", ":"))
                handle.write("\n")
                handle.flush()
                os.fsync(handle.fileno())
            os.chmod(temporary_name, 0o600)
            os.replace(temporary_name, path)
        finally:
            if os.path.exists(temporary_name):
                os.unlink(temporary_name)
