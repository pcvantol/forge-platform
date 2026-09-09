#!/usr/bin/env python3
"""Recovery and lock behavior for durable component-operation coordination."""

from __future__ import annotations

from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from forge_platform.durable_component_operations import DurableComponentOperationCoordinator  # noqa: E402
from test_component_operations import RecordingAdapter, request  # noqa: E402


class DurableComponentOperationTests(unittest.TestCase):
    def test_restart_reuses_exact_persisted_receipt_without_second_product_call(self):
        with tempfile.TemporaryDirectory() as directory:
            root, adapter = Path(directory), RecordingAdapter()
            first = DurableComponentOperationCoordinator(root).delegate(request(), adapter)
            recovered = DurableComponentOperationCoordinator(root).delegate(request(), adapter)
            self.assertEqual(recovered, first)
            self.assertEqual(len(adapter.requests), 1)
            record = root / "forge-platform-operation-001" / "record.json"
            self.assertEqual(oct(record.stat().st_mode & 0o777), "0o600")

    def test_rejects_unsafe_operation_path_and_corrupt_record(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            coordinator = DurableComponentOperationCoordinator(root)
            with self.assertRaisesRegex(ValueError, "safe relative"):
                coordinator.delegate(request(operation_id="../outside"), RecordingAdapter())
            record = root / "forge-platform-operation-001" / "record.json"
            record.parent.mkdir()
            record.write_text("not-json")
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
