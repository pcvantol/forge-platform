#!/usr/bin/env python3
"""Recovery and lock behavior for durable component-operation coordination."""

from __future__ import annotations

import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from forge_platform.durable_component_operations import DurableComponentOperationCoordinator  # noqa: E402
from test_component_operations import (  # noqa: E402
    RecordingAdapter,
    active_readback,
    receipt,
    request,
)


class DurableComponentOperationTests(unittest.TestCase):
    def test_restart_reuses_exact_persisted_record_without_second_product_call(self):
        with tempfile.TemporaryDirectory() as directory:
            root, adapter = Path(directory), RecordingAdapter()
            first = DurableComponentOperationCoordinator(root).delegate(request(), adapter)
            recovered = DurableComponentOperationCoordinator(root).delegate(request(), adapter)
            self.assertEqual(recovered, first)
            self.assertEqual(len(adapter.execution_requests), 1)
            self.assertEqual(len(adapter.readback_requests), 2)
            record = root / "forge-platform-operation-001" / "record.json"
            self.assertEqual(oct(record.stat().st_mode & 0o777), "0o600")
            payload = json.loads(record.read_text(encoding="utf-8"))
            self.assertEqual(
                set(payload),
                {
                    "operation_id", "request_fingerprint", "update_assessment", "preflight",
                    "product_receipt", "postflight", "prior_product_receipts",
                },
            )
            self.assertNotIn("product_request", payload)
            self.assertEqual(payload["postflight"]["selected_runtime_identity"], "ep-runtime-2.3.1")

    def test_reboot_resume_reuses_same_product_operation_and_retains_pending_receipt_history(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            pending = receipt(state="CLEANUP_PENDING")
            first_adapter = RecordingAdapter(operation_receipt=pending)
            first = DurableComponentOperationCoordinator(root).delegate(request(), first_adapter)
            resumed_adapter = RecordingAdapter(
                resume_receipt=receipt(),
                readbacks=[active_readback(), active_readback()],
            )
            completed = DurableComponentOperationCoordinator(root).delegate(request(), resumed_adapter)
            self.assertEqual(first.product_receipt.state, "CLEANUP_PENDING")
            self.assertEqual(completed.product_receipt.state, "COMPLETED")
            self.assertEqual(completed.prior_product_receipts, (pending,))
            self.assertEqual(resumed_adapter.execution_requests, [])
            self.assertEqual(len(resumed_adapter.resume_requests), 1)
            payload = json.loads((root / "forge-platform-operation-001" / "record.json").read_text())
            self.assertEqual(payload["prior_product_receipts"][0]["state"], "CLEANUP_PENDING")

    def test_pending_target_blocks_a_second_operation_after_restart(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            DurableComponentOperationCoordinator(root).delegate(
                request(), RecordingAdapter(operation_receipt=receipt(state="CLEANUP_PENDING")),
            )
            adapter = RecordingAdapter()
            with self.assertRaisesRegex(RuntimeError, "resumable operation forge-platform-operation-001"):
                DurableComponentOperationCoordinator(root).delegate(
                    request(operation_id="forge-platform-operation-002"), adapter,
                )
            self.assertEqual(adapter.execution_requests, [])
            self.assertEqual(adapter.resume_requests, [])

    def test_target_lock_prevents_concurrent_dispatch_for_different_operation_ids(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            first = DurableComponentOperationCoordinator(root)
            second = DurableComponentOperationCoordinator(root)
            original = request()
            with first._lock(first._target_lock_path(original), "component target operation is already in progress"):
                with self.assertRaisesRegex(RuntimeError, "component target operation is already in progress"):
                    second.delegate(request(operation_id="forge-platform-operation-002"), RecordingAdapter())

    def test_rejects_unsafe_operation_paths_corrupt_records_nonfinite_json_and_directory_identity_mismatch(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            coordinator = DurableComponentOperationCoordinator(root)
            for operation_id in (".", "..", "../outside"):
                with self.subTest(operation_id=operation_id), self.assertRaisesRegex(ValueError, "safe relative"):
                    coordinator.delegate(request(operation_id=operation_id), RecordingAdapter())

            coordinator.delegate(request(), RecordingAdapter())
            record = root / "forge-platform-operation-001" / "record.json"
            payload = json.loads(record.read_text(encoding="utf-8"))
            payload["operation_id"] = "other-operation"
            record.write_text(json.dumps(payload), encoding="utf-8")
            with self.assertRaisesRegex(RuntimeError, "record is invalid"):
                coordinator.delegate(request(), RecordingAdapter())

            payload["operation_id"] = "forge-platform-operation-001"
            payload["request_fingerprint"] = float("nan")
            record.write_text(json.dumps(payload), encoding="utf-8")
            with self.assertRaisesRegex(RuntimeError, "record is invalid"):
                coordinator.delegate(request(), RecordingAdapter())

    def test_rejects_another_coordinator_while_the_same_operation_lock_is_held(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            first = DurableComponentOperationCoordinator(root)
            second = DurableComponentOperationCoordinator(root)
            lock = root / "forge-platform-operation-001" / ".lock"
            lock.parent.mkdir()
            with first._lock(lock):
                with self.assertRaisesRegex(RuntimeError, "already in progress"):
                    with second._lock(lock):
                        pass


if __name__ == "__main__":
    unittest.main()
