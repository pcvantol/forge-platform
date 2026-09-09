#!/usr/bin/env python3
"""Behavioral checks for the product-owned operation delegation boundary."""

from __future__ import annotations

from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from forge_platform.component_operations import (  # noqa: E402
    ComponentOperationCoordinator,
    ComponentOperationRequest,
    ProductInstallationReadback,
    ProductOperationReceipt,
    ProductUpdateAssessment,
    QualifiedArtifact,
)


ARTIFACT = QualifiedArtifact(
    version="2.3.1", source_revision="a" * 40,
    source="https://registry.example.invalid/engineering-platform-2.3.1.whl",
    digest="sha256:" + "b" * 64,
    qualification="https://evidence.example.invalid/ep-2.3.1",
)
OLD_ARTIFACT = QualifiedArtifact(
    version="2.3.0", source_revision="c" * 40,
    source="https://registry.example.invalid/engineering-platform-2.3.0.whl",
    digest="sha256:" + "d" * 64,
    qualification="https://evidence.example.invalid/ep-2.3.0",
)


def active_readback(
    *,
    artifact: QualifiedArtifact = ARTIFACT,
    component: str = "engineering-platform-server",
    installation_identity: str = "ep-primary",
    runtime_identity: str = "ep-runtime-2.3.1",
    executable_identity: str = "ep-executable-2.3.1",
    server_identity: str | None = "ep-server-primary",
    instance_identity: str = "ep-instance-primary",
    inventory_coverage: str = "MACHINE_WIDE",
    conflict_state: str = "NONE",
) -> ProductInstallationReadback:
    return ProductInstallationReadback(
        component=component,
        installation_identity=installation_identity,
        state="ACTIVE",
        selected_runtime_identity=runtime_identity,
        selected_executable_identity=executable_identity,
        selected_server_identity=server_identity,
        selected_instance_identity=instance_identity,
        artifact=artifact,
        health_state="HEALTHY",
        inventory_coverage=inventory_coverage,
        conflict_state=conflict_state,
        evidence_reference="https://evidence.example.invalid/ep-primary-observation",
        health_evidence_reference="https://evidence.example.invalid/ep-primary-health",
        conflict_evidence_reference=(
            "https://evidence.example.invalid/ep-primary-conflicts"
            if conflict_state == "CONFLICTING" else None
        ),
    )


def unhealthy_readback(
    *, artifact: QualifiedArtifact = ARTIFACT,
    instance_identity: str = "wrong-instance",
) -> ProductInstallationReadback:
    return ProductInstallationReadback(
        component="engineering-platform-server",
        installation_identity="ep-primary",
        state="UNHEALTHY",
        selected_runtime_identity="ep-runtime-2.3.1",
        selected_executable_identity="ep-executable-2.3.1",
        selected_server_identity="wrong-server",
        selected_instance_identity=instance_identity,
        artifact=artifact,
        health_state="UNHEALTHY",
        inventory_coverage="MACHINE_WIDE",
        conflict_state="NONE",
        evidence_reference="https://evidence.example.invalid/ep-primary-observation",
        health_evidence_reference="https://evidence.example.invalid/wrong-instance-health",
    )


def assessment(
    *,
    state: str = "UPDATE_AVAILABLE",
    artifact: QualifiedArtifact = ARTIFACT,
    component: str = "engineering-platform-server",
    installation_identity: str = "ep-primary",
) -> ProductUpdateAssessment:
    return ProductUpdateAssessment(
        component=component,
        installation_identity=installation_identity,
        candidate_artifact=artifact,
        state=state,
        evidence_reference="https://evidence.example.invalid/ep-update-assessment",
    )


def receipt(
    *,
    state: str = "COMPLETED",
    artifact: QualifiedArtifact = ARTIFACT,
    component: str = "engineering-platform-server",
    installation_identity: str = "ep-primary",
    product_operation_id: str = "ep-operation-001",
) -> ProductOperationReceipt:
    return ProductOperationReceipt(
        product_operation_id=product_operation_id,
        component=component,
        installation_identity=installation_identity,
        artifact=artifact,
        state=state,
        evidence_reference="https://evidence.example.invalid/install-001",
        cleanup_evidence_reference=(
            "https://evidence.example.invalid/cleanup-001"
            if state == "CLEANUP_PENDING" else None
        ),
    )


class RecordingAdapter:
    """A product-owned adapter fixture; no PATH or local scan participates."""

    def __init__(
        self,
        *,
        readbacks: list[ProductInstallationReadback] | None = None,
        update_assessment: ProductUpdateAssessment | None = None,
        operation_receipt: ProductOperationReceipt | None = None,
        resume_receipt: ProductOperationReceipt | None = None,
    ) -> None:
        self.execution_requests: list[ComponentOperationRequest] = []
        self.readback_requests: list[ComponentOperationRequest] = []
        self.assessment_requests: list[ComponentOperationRequest] = []
        self.resume_requests: list[tuple[ComponentOperationRequest, ProductOperationReceipt]] = []
        self._readbacks = readbacks or [active_readback(artifact=OLD_ARTIFACT), active_readback()]
        self._next_readback = 0
        self._update_assessment = update_assessment or assessment()
        self._operation_receipt = operation_receipt or receipt()
        self._resume_receipt = resume_receipt or receipt()

    def readback(self, operation: ComponentOperationRequest) -> ProductInstallationReadback:
        self.readback_requests.append(operation)
        readback = self._readbacks[min(self._next_readback, len(self._readbacks) - 1)]
        self._next_readback += 1
        return readback

    def assess_update(self, operation: ComponentOperationRequest) -> ProductUpdateAssessment:
        self.assessment_requests.append(operation)
        return self._update_assessment

    def execute(self, operation: ComponentOperationRequest) -> ProductOperationReceipt:
        self.execution_requests.append(operation)
        return self._operation_receipt

    def resume(
        self,
        operation: ComponentOperationRequest,
        prior_receipt: ProductOperationReceipt,
    ) -> ProductOperationReceipt:
        self.resume_requests.append((operation, prior_receipt))
        return self._resume_receipt


def request(**changes: object) -> ComponentOperationRequest:
    fields: dict[str, object] = {
        "operation_id": "forge-platform-operation-001",
        "component": "engineering-platform-server",
        "kind": "update",
        "artifact": ARTIFACT,
        "installation_identity": "ep-primary",
        "requested_role": "server",
        "product_request": {"channel": "stable"},
    }
    fields.update(changes)
    return ComponentOperationRequest(**fields)  # type: ignore[arg-type]


class ComponentOperationTests(unittest.TestCase):
    def test_delegates_exact_qualified_identity_and_product_resolved_runtime(self):
        adapter = RecordingAdapter()
        record = ComponentOperationCoordinator().delegate(request(), adapter)
        self.assertEqual(len(adapter.execution_requests), 1)
        self.assertEqual(len(adapter.assessment_requests), 1)
        self.assertEqual(len(adapter.readback_requests), 2)
        self.assertEqual(adapter.execution_requests[0].artifact, ARTIFACT)
        self.assertEqual(record.update_assessment, assessment())
        self.assertEqual(record.product_receipt.product_operation_id, "ep-operation-001")
        self.assertEqual(record.postflight.selected_runtime_identity, "ep-runtime-2.3.1")
        self.assertTrue(record.postflight.single_operational_installation_verified)

    def test_retry_is_idempotent_and_any_artifact_locator_or_selection_change_fails_closed(self):
        coordinator, adapter = ComponentOperationCoordinator(), RecordingAdapter()
        first = coordinator.delegate(request(), adapter)
        self.assertEqual(coordinator.delegate(request(), adapter), first)
        self.assertEqual(len(adapter.execution_requests), 1)
        self.assertEqual(len(adapter.readback_requests), 2)
        different_digest = QualifiedArtifact(
            "2.3.1", "a" * 40, ARTIFACT.source, "sha256:" + "e" * 64, ARTIFACT.qualification,
        )
        different_source = QualifiedArtifact(
            ARTIFACT.version, ARTIFACT.source_revision,
            "https://other.example.invalid/engineering-platform-2.3.1.whl",
            ARTIFACT.digest, ARTIFACT.qualification,
        )
        for changed_request in (
            request(artifact=different_digest),
            request(artifact=different_source),
            request(product_request={"channel": "candidate"}),
        ):
            with self.assertRaisesRegex(RuntimeError, "different component artifact or action"):
                coordinator.delegate(changed_request, adapter)

    def test_rejects_product_runtime_instructions_and_non_finite_product_selection_values(self):
        for payload, fragment in (
            ({"interpreter": "/old/venv/bin/python"}, "interpreter"),
            ({"runtime-path": "/old/venv"}, "runtime_path"),
            ({"serviceReference": "user.ep"}, "servicereference"),
            ({"nested": {"launch_agent": "user.ep"}}, "launch_agent"),
            ({"installation_id": "other-ep"}, "installation_id"),
        ):
            with self.subTest(payload=payload), self.assertRaisesRegex(ValueError, fragment):
                request(product_request=payload)
        with self.assertRaisesRegex(ValueError, "finite JSON"):
            request(product_request={"rollout": float("nan")})

    def test_old_path_cannot_override_product_resolver_readback(self):
        adapter = RecordingAdapter(readbacks=[active_readback(runtime_identity="ep-runtime-owned-2.3.1")])
        observation = ComponentOperationCoordinator().observe(request(), adapter)
        self.assertEqual(observation.selected_runtime_identity, "ep-runtime-owned-2.3.1")
        self.assertEqual(len(adapter.execution_requests), 0)
        with self.assertRaisesRegex(ValueError, "path"):
            request(product_request={"PATH": "/old/ep-2.3.0/bin"})

    def test_completed_operation_rejects_product_health_that_flags_the_wrong_instance(self):
        adapter = RecordingAdapter(readbacks=[active_readback(artifact=OLD_ARTIFACT), unhealthy_readback()])
        with self.assertRaisesRegex(RuntimeError, "healthy selected runtime"):
            ComponentOperationCoordinator().delegate(request(), adapter)
        self.assertEqual(len(adapter.execution_requests), 1)

    def test_rejects_mismatched_product_receipt_and_update_assessment(self):
        wrong_receipt = RecordingAdapter(operation_receipt=receipt(component="workspace-server"))
        with self.assertRaisesRegex(RuntimeError, "receipt does not describe the requested component"):
            ComponentOperationCoordinator().delegate(request(), wrong_receipt)
        wrong_assessment = RecordingAdapter(update_assessment=assessment(artifact=OLD_ARTIFACT))
        with self.assertRaisesRegex(RuntimeError, "assessment does not describe the requested qualified artifact"):
            ComponentOperationCoordinator().delegate(request(), wrong_assessment)
        self.assertEqual(len(wrong_assessment.execution_requests), 0)

    def test_incompatible_unknown_or_already_current_update_never_dispatches_product_mutation(self):
        for state in ("INCOMPATIBLE", "UNKNOWN", "UP_TO_DATE"):
            adapter = RecordingAdapter(update_assessment=assessment(state=state))
            with self.subTest(state=state), self.assertRaisesRegex(RuntimeError, state):
                ComponentOperationCoordinator().delegate(request(), adapter)
            self.assertEqual(adapter.execution_requests, [])
            self.assertEqual(len(adapter.assessment_requests), 1)

    def test_cleanup_pending_resumes_the_same_product_operation_without_reexecuting(self):
        pending = receipt(state="CLEANUP_PENDING")
        adapter = RecordingAdapter(
            operation_receipt=pending,
            resume_receipt=receipt(),
            readbacks=[
                active_readback(artifact=OLD_ARTIFACT), active_readback(),
                active_readback(), active_readback(),
            ],
        )
        coordinator = ComponentOperationCoordinator()
        first = coordinator.delegate(request(), adapter)
        completed = coordinator.delegate(request(), adapter)
        self.assertEqual(first.product_receipt.state, "CLEANUP_PENDING")
        self.assertEqual(completed.product_receipt.state, "COMPLETED")
        self.assertEqual(completed.prior_product_receipts, (pending,))
        self.assertEqual(len(adapter.execution_requests), 1)
        self.assertEqual(len(adapter.resume_requests), 1)
        self.assertEqual(len(adapter.readback_requests), 4)

    def test_pending_product_operation_blocks_a_second_forge_platform_operation_for_the_same_target(self):
        adapter = RecordingAdapter(operation_receipt=receipt(state="CLEANUP_PENDING"))
        coordinator = ComponentOperationCoordinator()
        coordinator.delegate(request(), adapter)
        with self.assertRaisesRegex(RuntimeError, "resumable operation forge-platform-operation-001"):
            coordinator.delegate(request(operation_id="forge-platform-operation-002"), adapter)
        self.assertEqual(len(adapter.execution_requests), 1)
        self.assertEqual(len(adapter.resume_requests), 0)

    def test_resume_cannot_substitute_a_new_product_operation_identity(self):
        adapter = RecordingAdapter(
            operation_receipt=receipt(state="RECOVERY_PENDING"),
            resume_receipt=receipt(product_operation_id="ep-operation-002"),
        )
        coordinator = ComponentOperationCoordinator()
        coordinator.delegate(request(), adapter)
        with self.assertRaisesRegex(RuntimeError, "different product operation identity"):
            coordinator.delegate(request(), adapter)
        self.assertEqual(len(adapter.execution_requests), 1)
        self.assertEqual(len(adapter.resume_requests), 1)

    def test_machine_wide_coverage_and_no_conflict_are_required_for_single_installation_claim(self):
        self.assertTrue(active_readback().single_operational_installation_verified)
        self.assertFalse(active_readback(inventory_coverage="PARTIAL").single_operational_installation_verified)
        self.assertFalse(active_readback(conflict_state="CONFLICTING").single_operational_installation_verified)


if __name__ == "__main__":
    unittest.main()
