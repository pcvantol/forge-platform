#!/usr/bin/env python3
"""Behavioral checks for the Forge Platform composition release journal."""

from __future__ import annotations

from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from forge_platform.release_operation import ReleaseOperation, ReleaseOperationError, ReleaseOperationStore


def operation(
    identifier: str = "release-0001",
    *,
    source_revision: str = "a" * 40,
    digest: str = "b" * 64,
) -> ReleaseOperation:
    return ReleaseOperation.create(
        operation_id=identifier,
        product="forge-platform",
        component="composition",
        version="2.3.0",
        policy_revision="forge-platform-production-release-v3",
        source_revision=source_revision,
        artifacts={"composition_manifest": "sha256:" + digest},
    )


QUALIFICATION = {
    "exact_main_sha": "a" * 40,
    "artifact_digests": {"composition_manifest": "sha256:" + "b" * 64},
    "composition_asset": "forge-platform-composition-2.3.0-a.json",
}
PUBLICATION = {
    "registry": "github-release",
    "tag": "forge-platform-v2.3.0",
    "composition_asset": QUALIFICATION["composition_asset"],
    "artifact_digests": QUALIFICATION["artifact_digests"],
    "readback": "PASS",
}
PENDING_CLEANUP = {"result": "CLEANUP_PENDING", "targets": ["operation-readback"]}
COMPLETE_CLEANUP = {"result": "CLEANUP_COMPLETE", "targets": ["operation-readback"]}


class ReleaseOperationTests(unittest.TestCase):
    def test_lost_answer_resumes_published_receipt_and_cleanup_to_completion(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            store = ReleaseOperationStore(Path(temporary))
            expected = operation()
            store.acquire(expected.operation_id)
            try:
                qualified = store.prepare_qualified(expected, evidence=QUALIFICATION)
                published = store.mark_published(qualified, evidence=PUBLICATION)
                self.assertEqual(published.state, "PUBLISHED")
                self.assertEqual(store.load(expected.operation_id), published)
                self.assertEqual(oct(store._path(expected.operation_id).stat().st_mode & 0o777), "0o600")
            finally:
                store.release(expected.operation_id)

            recovered = ReleaseOperationStore(Path(temporary))
            recovered.acquire(expected.operation_id)
            try:
                self.assertEqual(recovered.prepare_qualified(expected, evidence=QUALIFICATION), published)
                self.assertEqual(recovered.mark_published(expected, evidence=PUBLICATION), published)
                pending = recovered.mark_cleanup_pending(published, evidence=PENDING_CLEANUP)
                completed = recovered.complete(pending, evidence=COMPLETE_CLEANUP)
                self.assertEqual(completed.state, "RELEASE_COMPLETE")
                self.assertEqual(recovered.complete(completed, evidence=COMPLETE_CLEANUP), completed)
            finally:
                recovered.release(expected.operation_id)

    def test_same_release_identity_with_different_composition_bytes_or_provenance_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            store = ReleaseOperationStore(Path(temporary))
            first = operation()
            store.acquire(first.operation_id)
            try:
                qualified = store.prepare_qualified(first, evidence=QUALIFICATION)
                store.mark_published(qualified, evidence=PUBLICATION)
            finally:
                store.release(first.operation_id)

            second = operation("release-0002", digest="c" * 64)
            changed_qualification = {
                **QUALIFICATION,
                "artifact_digests": {"composition_manifest": "sha256:" + "c" * 64},
            }
            store.acquire(second.operation_id)
            try:
                qualified = store.prepare_qualified(second, evidence=changed_qualification)
                changed_publication = {
                    **PUBLICATION,
                    "artifact_digests": changed_qualification["artifact_digests"],
                }
                with self.assertRaisesRegex(ReleaseOperationError, "different bytes or provenance"):
                    store.mark_published(qualified, evidence=changed_publication)
            finally:
                store.release(second.operation_id)

    def test_lock_ownership_serializes_writers_and_is_required_for_mutations(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            store = ReleaseOperationStore(Path(temporary))
            contender = ReleaseOperationStore(Path(temporary))
            expected = operation()
            with self.assertRaisesRegex(ReleaseOperationError, "must own"):
                store.save(expected)
            store.acquire(expected.operation_id)
            try:
                with self.assertRaisesRegex(ReleaseOperationError, "another release operation"):
                    contender.acquire("release-0002")
                with self.assertRaisesRegex(ReleaseOperationError, "does not own"):
                    contender.release("release-0002")
            finally:
                store.release(expected.operation_id)
            contender.acquire("release-0002")
            contender.release("release-0002")

    def test_resume_rejects_changed_qualification_and_immutable_identity(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            store = ReleaseOperationStore(Path(temporary))
            expected = operation()
            store.acquire(expected.operation_id)
            try:
                qualified = store.prepare_qualified(expected, evidence=QUALIFICATION)
                with self.assertRaisesRegex(ReleaseOperationError, "qualification evidence changed"):
                    store.prepare_qualified(expected, evidence={**QUALIFICATION, "extra": "tampered"})
                changed = operation(source_revision="c" * 40)
                with self.assertRaisesRegex(ReleaseOperationError, "changed before transition"):
                    store.replace(qualified, changed)
            finally:
                store.release(expected.operation_id)

    def test_bad_records_illegal_transitions_and_non_json_evidence_are_rejected(self) -> None:
        prepared = operation()
        with self.assertRaisesRegex(ReleaseOperationError, "not permitted"):
            prepared.transition("PUBLISHED", evidence={"receipt": "not qualified"})
        with self.assertRaisesRegex(ReleaseOperationError, "composition-manifest"):
            ReleaseOperation.create(
                operation_id="release-0003", product="forge-platform", component="composition", version="2.3.0",
                policy_revision="v1", source_revision="a" * 40, artifacts={"wheel": "sha256:" + "b" * 64},
            )
        with self.assertRaisesRegex(ReleaseOperationError, "JSON"):
            prepared.transition("QUALIFIED", evidence={"not_json": object()})
        with self.assertRaisesRegex(ReleaseOperationError, "JSON"):
            prepared.transition("QUALIFIED", evidence={"not_json": float("nan")})
        for state in ("CLEANUP_PENDING", "RELEASE_COMPLETE"):
            invalid = {
                **prepared.__dict__,
                "state": state,
                "qualification": {"check": "PASS"},
                "publication_receipt": {"registry": "github-release"},
                "cleanup": None,
            }
            with self.assertRaisesRegex(ReleaseOperationError, "missing cleanup"):
                ReleaseOperation.parse(invalid)
        with tempfile.TemporaryDirectory() as temporary:
            store = ReleaseOperationStore(Path(temporary))
            store._path("release-0001").parent.mkdir(parents=True)
            store._path("release-0001").write_text("{}", encoding="utf-8")
            with self.assertRaisesRegex(ReleaseOperationError, "unknown or missing"):
                store.load("release-0001")

    def test_artifact_digest_normalizes_symlink_and_space_paths_without_filename_trust(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            artifacts = root / "artifact path"
            artifacts.mkdir()
            actual = artifacts / "composition manifest.json"
            actual.write_bytes(b"exact qualified composition")
            alias = root / "linked composition.json"
            alias.symlink_to(actual)
            self.assertEqual(
                ReleaseOperationStore.artifact_digest(actual),
                ReleaseOperationStore.artifact_digest(alias),
            )
            with self.assertRaisesRegex(ReleaseOperationError, "unavailable"):
                ReleaseOperationStore.artifact_digest(root / "missing")


if __name__ == "__main__":
    unittest.main()
