#!/usr/bin/env python3
"""Behavioral checks for the product-owned operation delegation boundary."""

from __future__ import annotations

from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from forge_platform.component_operations import (  # noqa: E402
    ComponentOperationCoordinator, ComponentOperationRequest,
    ProductOperationReceipt, QualifiedArtifact,
)


ARTIFACT = QualifiedArtifact(
    version="2.3.1", source_revision="a" * 40,
    source="https://registry.example.invalid/engineering-platform-2.3.1.whl",
    digest="sha256:" + "b" * 64,
    qualification="https://evidence.example.invalid/ep-2.3.1",
)


class RecordingAdapter:
    def __init__(self) -> None:
        self.requests = []

    def execute(self, operation):
        self.requests.append(operation)
        return ProductOperationReceipt("ep-operation-001", "COMPLETED", "https://evidence.example.invalid/install-001")


def request(**changes):
    fields = {
        "operation_id": "forge-platform-operation-001",
        "component": "engineering-platform-server",
        "kind": "update", "artifact": ARTIFACT, "requested_role": "server",
        "product_request": {"channel": "stable", "installation_identity": "ep-primary"},
    }
    fields.update(changes)
    return ComponentOperationRequest(**fields)


class ComponentOperationTests(unittest.TestCase):
    def test_delegates_exact_qualified_identity_without_reinterpreting_product_result(self):
        adapter = RecordingAdapter()
        record = ComponentOperationCoordinator().delegate(request(), adapter)
        self.assertEqual(len(adapter.requests), 1)
        self.assertEqual(adapter.requests[0].artifact, ARTIFACT)
        self.assertEqual(record.product_receipt.product_operation_id, "ep-operation-001")
        self.assertEqual(record.product_receipt.evidence_reference, "https://evidence.example.invalid/install-001")

    def test_retry_reuses_same_product_operation_but_conflicting_artifact_fails_closed(self):
        coordinator, adapter = ComponentOperationCoordinator(), RecordingAdapter()
        first = coordinator.delegate(request(), adapter)
        self.assertEqual(coordinator.delegate(request(), adapter), first)
        self.assertEqual(len(adapter.requests), 1)
        different = QualifiedArtifact("2.3.1", "a" * 40, ARTIFACT.source, "sha256:" + "c" * 64, ARTIFACT.qualification)
        with self.assertRaisesRegex(RuntimeError, "different component artifact"):
            coordinator.delegate(request(artifact=different), adapter)
        with self.assertRaisesRegex(RuntimeError, "different component artifact"):
            coordinator.delegate(request(product_request={"channel": "candidate"}), adapter)

    def test_rejects_unqualified_artifacts_and_product_runtime_instructions(self):
        with self.assertRaisesRegex(ValueError, "sha256"):
            QualifiedArtifact("2.3.1", "a" * 40, "https://example.invalid", "sha256:unknown", "evidence")
        with self.assertRaisesRegex(ValueError, "product-runtime key: interpreter"):
            request(product_request={"interpreter": "/old/venv/bin/python"})
        with self.assertRaisesRegex(ValueError, "product-runtime key: migration"):
            request(product_request={"nested": {"migration": "run"}})

    def test_rejects_path_as_a_runtime_selection_mechanism(self):
        with self.assertRaisesRegex(ValueError, "product-runtime key: path"):
            request(product_request={"PATH": "/old/ep/bin"})


if __name__ == "__main__":
    unittest.main()
