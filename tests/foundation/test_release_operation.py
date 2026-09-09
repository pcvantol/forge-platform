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


def operation(identifier: str = "release-0001") -> ReleaseOperation:
    return ReleaseOperation.create(
        operation_id=identifier,
        product="forge-platform",
        component="composition",
        version="2.3.0",
        policy_revision="forge-platform-production-release-v2",
        source_revision="a" * 40,
        artifacts={"composition_manifest": "sha256:" + "b" * 64},
    )


class ReleaseOperationTests(unittest.TestCase):
    def test_lost_answer_resumes_published_receipt_before_cleanup_completion(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            store = ReleaseOperationStore(Path(temporary))
            prepared = store.save(operation())
            qualified = store.replace(
                prepared,
                prepared.transition("QUALIFIED", evidence={"exact_main_sha": "a" * 40, "artifact_digests": prepared.artifacts}),
            )
            published = store.replace(
                qualified,
                qualified.transition("PUBLISHED", evidence={"registry": "github-release", "readback": "PASS"}),
            )
            store.record_publication(published)
            self.assertEqual(store.load("release-0001"), published)
            self.assertEqual(oct(store._path("release-0001").stat().st_mode & 0o777), "0o600")
            pending = store.replace(
                published,
                published.transition("CLEANUP_PENDING", evidence={"result": "PENDING", "temporary_paths": ["readback"]}),
            )
            completed = store.replace(
                pending,
                pending.transition("RELEASE_COMPLETE", evidence={"result": "COMPLETE", "temporary_paths": ["readback"]}),
            )
            store.record_publication(completed)
            self.assertEqual(completed.state, "RELEASE_COMPLETE")

    def test_same_release_identity_with_different_composition_bytes_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            store = ReleaseOperationStore(Path(temporary))
            first = operation().transition("QUALIFIED", evidence={"check": "PASS"})
            first = first.transition("PUBLISHED", evidence={"receipt": "one"})
            store.record_publication(first)
            changed = ReleaseOperation.create(
                operation_id="release-0002",
                product="forge-platform",
                component="composition",
                version="2.3.0",
                policy_revision="forge-platform-production-release-v2",
                source_revision="a" * 40,
                artifacts={"composition_manifest": "sha256:" + "c" * 64},
            ).transition("QUALIFIED", evidence={"check": "PASS"}).transition("PUBLISHED", evidence={"receipt": "two"})
            with self.assertRaisesRegex(ReleaseOperationError, "different bytes"):
                store.record_publication(changed)

    def test_only_one_release_operation_can_hold_the_lock(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            store = ReleaseOperationStore(Path(temporary))
            contender = ReleaseOperationStore(Path(temporary))
            store.acquire("release-0001")
            with self.assertRaisesRegex(ReleaseOperationError, "another release operation"):
                contender.acquire("release-0002")
            with self.assertRaisesRegex(ReleaseOperationError, "does not own"):
                contender.release("release-0002")
            store.release("release-0001")
            contender.acquire("release-0002")
            contender.release("release-0002")

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
        invalid_pending = {
            **prepared.__dict__,
            "state": "CLEANUP_PENDING",
            "qualification": {"check": "PASS"},
            "publication_receipt": {"registry": "github-release"},
            "cleanup": None,
        }
        with self.assertRaisesRegex(ReleaseOperationError, "missing cleanup"):
            ReleaseOperation.parse(invalid_pending)
        with tempfile.TemporaryDirectory() as temporary:
            store = ReleaseOperationStore(Path(temporary))
            store._path("release-0001").parent.mkdir(parents=True)
            store._path("release-0001").write_text("{}", encoding="utf-8")
            with self.assertRaisesRegex(ReleaseOperationError, "unknown or missing"):
                store.load("release-0001")

    def test_recovery_guards_and_artifact_hashing_cover_tampering(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            store = ReleaseOperationStore(root)
            prepared = store.save(operation())
            with self.assertRaisesRegex(ReleaseOperationError, "immutable"):
                store.save(prepared.transition("QUALIFIED", evidence={"pass": True}))
            with self.assertRaisesRegex(ReleaseOperationError, "changed before"):
                store.replace(operation("release-0002"), prepared)
            artifact = root / "composition.json"
            artifact.write_bytes(b"exact qualified composition")
            self.assertTrue(store.artifact_digest(artifact).startswith("sha256:"))
            with self.assertRaisesRegex(ReleaseOperationError, "unavailable"):
                store.artifact_digest(root / "missing")


if __name__ == "__main__":
    unittest.main()
