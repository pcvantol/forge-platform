#!/usr/bin/env python3
"""Behavioral checks for strict, read-only EP OI-3 wire decoding."""

from __future__ import annotations

from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from forge_platform.component_operations import ComponentOperationRequest, QualifiedArtifact  # noqa: E402
from forge_platform.engineering_platform_readback import (  # noqa: E402
    EPReadbackWireError,
    decode_installation_readback,
    decode_update_assessment,
    validate_assessment_for_request,
    validate_readback_for_request,
)


SOURCE_REVISION = "a" * 40
DIGEST = "sha256:" + "b" * 64
ARTIFACT = QualifiedArtifact(
    version="2.3.1",
    source_revision=SOURCE_REVISION,
    source="https://registry.example.invalid/engineering-platform-2.3.1.whl",
    digest=DIGEST,
    qualification="https://evidence.example.invalid/ep-2.3.1",
)


def request(**changes: object) -> ComponentOperationRequest:
    fields: dict[str, object] = {
        "operation_id": "forge-platform-operation-001",
        "component": "engineering-platform-server",
        "kind": "update",
        "artifact": ARTIFACT,
        "installation_identity": "ep-primary",
        "requested_role": "server",
        "product_request": {},
    }
    fields.update(changes)
    return ComponentOperationRequest(**fields)  # type: ignore[arg-type]


def active_payload() -> dict[str, object]:
    return {
        "contract_version": "1.0",
        "component": "engineering-platform-server",
        "installation_identity": "ep-primary",
        "state": "ACTIVE",
        "selected_runtime_identity": "ep-runtime-owned-2.3.1",
        "selected_executable_identity": "ep-executable-owned-2.3.1",
        "selected_server_identity": "ep-server-primary",
        "selected_instance_identity": "ep-primary",
        "artifact": {
            "version": "2.3.1",
            "source_revision": SOURCE_REVISION,
            "digest": DIGEST,
            "channel": "stable",
        },
        "health_state": "HEALTHY",
        "inventory_coverage": "PARTIAL",
        "conflict_state": "UNKNOWN",
        "inventory_scope": {
            "required": "MACOS_MACHINE",
            "observed": "CURRENT_OS_USER_EXPLICIT_REFERENCES_ONLY",
            "status": "INCOMPLETE",
            "nested_scope_evidence": ["service", {"account": "current"}],
        },
        "single_operational_installation_verified": False,
        "evidence": {
            "record_state": "REGISTERED",
            "runtime": {"instance_id": "ep-primary", "versions": ["2.3.1"]},
            "health_qualification": "PASS",
        },
    }


def unknown_payload() -> dict[str, object]:
    return {
        "contract_version": "1.0",
        "component": "engineering-platform-server",
        "installation_identity": None,
        "state": "UNKNOWN",
        "selected_runtime_identity": None,
        "selected_executable_identity": None,
        "selected_server_identity": None,
        "selected_instance_identity": None,
        "artifact": None,
        "health_state": "UNKNOWN",
        "inventory_coverage": "UNKNOWN",
        "conflict_state": "UNKNOWN",
        "inventory_scope": {"required": "MACOS_MACHINE", "status": "INCOMPLETE"},
        "single_operational_installation_verified": False,
        "evidence": {
            "reason": "OWNED_SERVICE_INTERPRETER_UNAVAILABLE",
            "inventory": {"state": "NOT_REQUESTED"},
        },
    }


def assessment_payload(*, state: str = "UPDATE_AVAILABLE", identity: str | None = "ep-primary") -> dict[str, object]:
    return {
        "contract_version": "1.0",
        "component": "engineering-platform-server",
        "installation_identity": identity,
        "candidate": {
            "version": "2.3.1",
            "source_revision": SOURCE_REVISION,
            "digest": DIGEST,
        },
        "state": state,
        "evidence": {
            "assessment": "PREPARED" if state == "UPDATE_AVAILABLE" else "REJECTED",
            "nested": ["preserved", {"operation_id": "ep-operation-001"}],
        },
    }


class EPOI3ReadbackDecoderTests(unittest.TestCase):
    def test_decodes_active_readback_with_inline_scope_evidence_and_triple_only(self) -> None:
        payload = active_payload()
        observation = decode_installation_readback(payload, request=request())

        self.assertTrue(observation.installation_actionable)
        self.assertFalse(observation.single_operational_installation_verified)
        self.assertEqual(observation.artifact, ARTIFACT.correlation)
        self.assertEqual(observation.artifact_channel, "stable")
        self.assertFalse(hasattr(observation.artifact, "source"))
        self.assertEqual(observation.inventory_scope, payload["inventory_scope"])
        self.assertEqual(observation.evidence, payload["evidence"])

        # Input mutation cannot rewrite retained product evidence or scope.
        scope = payload["inventory_scope"]
        evidence = payload["evidence"]
        assert isinstance(scope, dict) and isinstance(evidence, dict)
        scope["status"] = "MUTATED"
        evidence["runtime"] = "MUTATED"
        self.assertEqual(observation.inventory_scope["status"], "INCOMPLETE")
        self.assertIsInstance(observation.evidence["runtime"], dict)

    def test_decodes_unhealthy_readback_without_treating_it_as_actionable(self) -> None:
        payload = active_payload()
        payload.update({
            "state": "UNHEALTHY",
            "health_state": "UNHEALTHY",
            "selected_server_identity": None,
        })
        payload["evidence"] = {"health_qualification": "UNAVAILABLE"}
        observation = decode_installation_readback(payload, request=request())
        self.assertFalse(observation.installation_actionable)
        self.assertEqual(observation.selected_server_identity, None)

    def test_anonymous_unknown_is_preserved_but_non_actionable(self) -> None:
        observation = decode_installation_readback(unknown_payload(), request=request())
        self.assertIsNone(observation.installation_identity)
        self.assertFalse(observation.installation_actionable)
        self.assertFalse(observation.single_operational_installation_verified)
        self.assertEqual(
            observation.evidence,
            {"reason": "OWNED_SERVICE_INTERPRETER_UNAVAILABLE", "inventory": {"state": "NOT_REQUESTED"}},
        )

    def test_rejects_wrong_readback_contract_component_identity_state_and_health(self) -> None:
        cases = (
            ("contract", {"contract_version": "2.0"}, "contract version"),
            ("component", {"component": "workspace-server"}, "component"),
            ("identity", {"installation_identity": "ep-other"}, "installation identity"),
            ("state", {"state": "READY"}, "readback state"),
            ("health", {"health_state": "UNKNOWN"}, "healthy state"),
        )
        for name, changes, message in cases:
            with self.subTest(name=name):
                payload = active_payload()
                payload.update(changes)
                with self.assertRaisesRegex(EPReadbackWireError, message):
                    decode_installation_readback(payload, request=request())

    def test_rejects_nonanonymous_unknown_and_malformed_absent(self) -> None:
        unknown = unknown_payload()
        unknown["installation_identity"] = "ep-primary"
        with self.assertRaisesRegex(EPReadbackWireError, "anonymous"):
            decode_installation_readback(unknown)

        absent = unknown_payload()
        absent.update({"installation_identity": "ep-primary", "state": "ABSENT"})
        absent["selected_runtime_identity"] = "incidental-path-runtime"
        with self.assertRaisesRegex(EPReadbackWireError, "cannot select"):
            decode_installation_readback(absent)

    def test_rejects_unexpected_wire_fields_and_non_json_product_evidence(self) -> None:
        payload = active_payload()
        payload["fallback_interpreter"] = "/old/venv/bin/python"
        with self.assertRaisesRegex(EPReadbackWireError, "unexpected fallback_interpreter"):
            decode_installation_readback(payload)

        payload = active_payload()
        payload["artifact"] = {**payload["artifact"], "source": "should-not-cross-boundary"}  # type: ignore[arg-type]
        with self.assertRaisesRegex(EPReadbackWireError, "artifact fields"):
            decode_installation_readback(payload)

        payload = active_payload()
        payload["evidence"] = {"unsupported": object()}
        with self.assertRaisesRegex(EPReadbackWireError, "JSON-compatible"):
            decode_installation_readback(payload)

        payload = active_payload()
        artifact = payload["artifact"]
        assert isinstance(artifact, dict)
        artifact["digest"] = "sha256:not-a-real-digest"
        with self.assertRaisesRegex(ValueError, "artifact sha256"):
            decode_installation_readback(payload)

    def test_readback_keeps_an_observed_prior_correlation_distinct_from_the_candidate(self) -> None:
        payload = active_payload()
        artifact = payload["artifact"]
        assert isinstance(artifact, dict)
        artifact.update({
            "version": "2.3.0",
            "source_revision": "c" * 40,
            "digest": "sha256:" + "d" * 64,
        })
        observation = decode_installation_readback(payload, request=request())
        self.assertNotEqual(observation.artifact, ARTIFACT.correlation)
        self.assertTrue(observation.installation_actionable)

    def test_decodes_exact_candidate_assessment_with_verbatim_inline_evidence(self) -> None:
        payload = assessment_payload()
        assessment = decode_update_assessment(payload, request=request())
        self.assertTrue(assessment.update_actionable)
        self.assertEqual(assessment.candidate, ARTIFACT.correlation)
        self.assertEqual(assessment.evidence, payload["evidence"])
        self.assertFalse(hasattr(assessment.candidate, "qualification"))

        evidence = payload["evidence"]
        assert isinstance(evidence, dict)
        evidence["nested"] = "mutated"
        self.assertEqual(assessment.evidence["nested"], ["preserved", {"operation_id": "ep-operation-001"}])

    def test_anonymous_unknown_update_assessment_is_non_actionable(self) -> None:
        assessment = decode_update_assessment(
            assessment_payload(state="UNKNOWN", identity=None), request=request(),
        )
        self.assertIsNone(assessment.installation_identity)
        self.assertFalse(assessment.update_actionable)

    def test_rejects_wrong_assessment_contract_component_identity_state_and_triple(self) -> None:
        cases = (
            ("contract", {"contract_version": "1.1"}, "contract version"),
            ("component", {"component": "workspace-server"}, "component"),
            ("identity", {"installation_identity": "ep-other"}, "installation identity"),
            ("state", {"state": "MAYBE"}, "update assessment state"),
        )
        for name, changes, message in cases:
            with self.subTest(name=name):
                payload = assessment_payload()
                payload.update(changes)
                with self.assertRaisesRegex(EPReadbackWireError, message):
                    decode_update_assessment(payload, request=request())

        for field, value in (("version", "2.3.2"), ("source_revision", "c" * 40), ("digest", "sha256:" + "d" * 64)):
            with self.subTest(triple_field=field):
                payload = assessment_payload()
                candidate = payload["candidate"]
                assert isinstance(candidate, dict)
                candidate[field] = value
                with self.assertRaisesRegex(EPReadbackWireError, "artifact correlation"):
                    decode_update_assessment(payload, request=request())

    def test_rejects_unsupported_role_kind_and_product_request(self) -> None:
        for name, changed_request, decoder in (
            ("role", request(requested_role="project-agent"), decode_installation_readback),
            ("kind", request(kind="repair"), decode_installation_readback),
            ("product-request", request(product_request={"channel": "stable"}), decode_update_assessment),
        ):
            with self.subTest(name=name), self.assertRaisesRegex(EPReadbackWireError, "only supports|does not support"):
                payload = active_payload() if decoder is decode_installation_readback else assessment_payload()
                decoder(payload, request=changed_request)

    def test_explicit_binding_helpers_reject_wrong_identity_and_candidate_without_fallback(self) -> None:
        observation = decode_installation_readback(active_payload())
        with self.assertRaisesRegex(EPReadbackWireError, "installation identity"):
            validate_readback_for_request(observation, request(installation_identity="ep-other"))

        assessment = decode_update_assessment(assessment_payload())
        replacement = QualifiedArtifact(
            version="2.3.1",
            source_revision=SOURCE_REVISION,
            source=ARTIFACT.source,
            digest="sha256:" + "e" * 64,
            qualification=ARTIFACT.qualification,
        )
        with self.assertRaisesRegex(EPReadbackWireError, "artifact correlation"):
            validate_assessment_for_request(assessment, request(artifact=replacement))

    def test_rejects_false_machine_wide_claim(self) -> None:
        payload = active_payload()
        payload.update({
            "inventory_coverage": "PARTIAL",
            "conflict_state": "NONE",
            "single_operational_installation_verified": True,
        })
        with self.assertRaisesRegex(EPReadbackWireError, "machine-wide"):
            decode_installation_readback(payload)

    def test_does_not_upgrade_a_false_product_uniqueness_result(self) -> None:
        payload = active_payload()
        payload.update({
            "inventory_coverage": "MACHINE_WIDE",
            "conflict_state": "NONE",
            "single_operational_installation_verified": False,
        })
        observation = decode_installation_readback(payload)
        self.assertFalse(observation.single_operational_installation_verified)


if __name__ == "__main__":
    unittest.main()
