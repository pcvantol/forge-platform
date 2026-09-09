#!/usr/bin/env python3
"""Behavioral checks for the separately versioned installer release journal."""

from __future__ import annotations

from dataclasses import asdict, replace
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from forge_platform.installer_release_operation import (  # noqa: E402
    InstallerCleanupEvidence,
    InstallerPreparationEvidence,
    InstallerPublicationEvidence,
    InstallerQualificationEvidence,
    InstallerReleaseIdentity,
    InstallerReleaseOperation,
    InstallerReleaseOperationError,
    InstallerReleaseOperationStore,
    InstallerReleasePreparation,
)


SOURCE_REVISION = "a" * 40
DESCRIPTOR_DIGEST = "sha256:" + "b" * 64
ARM64_ARCHIVE_DIGEST = "sha256:" + "c" * 64
X86_64_ARCHIVE_DIGEST = "sha256:" + "d" * 64
CANDIDATE_MANIFEST_DIGEST = "sha256:" + "e" * 64
ARM64_CANDIDATE_DIGEST = "sha256:" + "f" * 64
X86_64_CANDIDATE_DIGEST = "sha256:" + "1" * 64
CAPABILITIES = ("composition/v1", "provider-gate/v1", "system-launchdaemon/v1")
POLICY_REVISION = "forge-platform-installer-release-v1"
RELEASE_IDENTITY = InstallerReleaseIdentity(
    github_repository="example/forge-platform",
    bundle_identifier="com.example.forge-platform-installer",
    team_identifier="ABCDE12345",
    release_tag_prefix="forge-platform-installer-v",
    asset_prefix="ForgePlatformInstaller-macos-",
    signature_algorithm="ed25519",
    signature_key_ids=("release-key-001",),
    signature_threshold=1,
)
ALTERNATE_RELEASE_IDENTITY = InstallerReleaseIdentity(
    github_repository="example/forge-platform",
    bundle_identifier="com.example.forge-platform-installer",
    team_identifier="ZYXWV98765",
    release_tag_prefix="forge-platform-installer-v",
    asset_prefix="ForgePlatformInstaller-macos-",
    signature_algorithm="ed25519",
    signature_key_ids=("release-key-002",),
    signature_threshold=1,
)


def archives(*, arm64_digest: str = ARM64_ARCHIVE_DIGEST) -> dict[str, str]:
    return {"arm64": arm64_digest, "x86_64": X86_64_ARCHIVE_DIGEST}


def candidate_archives(*, arm64_digest: str = ARM64_CANDIDATE_DIGEST) -> dict[str, str]:
    return {"arm64": arm64_digest, "x86_64": X86_64_CANDIDATE_DIGEST}


def preparation(
    *,
    candidate_manifest_digest: str = CANDIDATE_MANIFEST_DIGEST,
    candidate_archive_digests: dict[str, str] | None = None,
) -> InstallerPreparationEvidence:
    return InstallerPreparationEvidence(
        candidate_manifest_digest=candidate_manifest_digest,
        candidate_archives=candidate_archive_digests or candidate_archives(),
        preparation_receipt_reference="receipt:installer-preparation-001",
    )


def qualification(
    *,
    source_revision: str = SOURCE_REVISION,
    policy_revision: str = POLICY_REVISION,
    descriptor_digest: str = DESCRIPTOR_DIGEST,
    archive_digests: dict[str, str] | None = None,
    candidate_manifest_digest: str = CANDIDATE_MANIFEST_DIGEST,
    candidate_archive_digests: dict[str, str] | None = None,
) -> InstallerQualificationEvidence:
    return InstallerQualificationEvidence(
        source_revision=source_revision,
        policy_revision=policy_revision,
        candidate_manifest_digest=candidate_manifest_digest,
        candidate_archives=candidate_archive_digests or candidate_archives(),
        descriptor_digest=descriptor_digest,
        archives=archive_digests or archives(),
        qualification_receipt_reference="receipt:installer-qualification-001",
    )


def operation(
    identifier: str = "installer-release-0001",
    *,
    version: str = "1.1.0",
    channel: str = "stable",
    source_revision: str = SOURCE_REVISION,
    policy_revision: str = POLICY_REVISION,
    release_identity: InstallerReleaseIdentity = RELEASE_IDENTITY,
    capabilities: tuple[str, ...] = CAPABILITIES,
    archive_digests: dict[str, str] | None = None,
    descriptor_digest: str = DESCRIPTOR_DIGEST,
    candidate_manifest_digest: str = CANDIDATE_MANIFEST_DIGEST,
    candidate_archive_digests: dict[str, str] | None = None,
) -> InstallerReleaseOperation:
    archive_digests = archive_digests or archives()
    candidate_archive_digests = candidate_archive_digests or candidate_archives()
    prepared = preparation(
        candidate_manifest_digest=candidate_manifest_digest,
        candidate_archive_digests=candidate_archive_digests,
    )
    return InstallerReleaseOperation.create(
        operation_id=identifier,
        installer_version=version,
        channel=channel,
        source_revision=source_revision,
        policy_revision=policy_revision,
        release_identity=release_identity,
        capabilities=capabilities,
        preparation=prepared,
        archives=archive_digests,
        descriptor_digest=descriptor_digest,
        qualification=qualification(
            source_revision=source_revision,
            policy_revision=policy_revision,
            descriptor_digest=descriptor_digest,
            archive_digests=archive_digests,
            candidate_manifest_digest=candidate_manifest_digest,
            candidate_archive_digests=candidate_archive_digests,
        ),
    )


def prepared_candidate(operation: InstallerReleaseOperation) -> InstallerReleasePreparation:
    return InstallerReleasePreparation(
        operation_id=operation.operation_id,
        installer_version=operation.installer_version,
        channel=operation.channel,
        source_revision=operation.source_revision,
        policy_revision=operation.policy_revision,
        release_identity=operation.release_identity,
        capabilities=operation.capabilities,
        preparation=operation.preparation,
    )


def publication(expected: InstallerReleaseOperation) -> InstallerPublicationEvidence:
    return InstallerPublicationEvidence(
        github_repository=expected.release_identity.github_repository,
        release_tag=expected.release_tag,
        policy_revision=expected.policy_revision,
        descriptor_digest=expected.descriptor_digest,
        archives=expected.archives,
        publication_receipt_reference="receipt:installer-publication-001",
        readback_receipt_reference="receipt:installer-readback-001",
    )


PENDING_CLEANUP = InstallerCleanupEvidence(
    result="CLEANUP_PENDING",
    cleanup_receipt_reference="receipt:installer-cleanup-pending-001",
    target_ids=("operation-cache", "staged-archive"),
)
COMPLETE_CLEANUP = InstallerCleanupEvidence(
    result="CLEANUP_COMPLETE",
    cleanup_receipt_reference="receipt:installer-cleanup-complete-001",
    target_ids=("operation-cache", "staged-archive"),
)


class InstallerReleaseOperationTests(unittest.TestCase):
    def test_lost_answer_recovers_exact_published_installer_and_completes_cleanup(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            expected = operation()
            self.assertEqual(expected.release_tag, "forge-platform-installer-v1.1.0")
            first = InstallerReleaseOperationStore(Path(temporary))
            first.acquire(expected.operation_id)
            try:
                self.assertEqual(first.prepare_candidate(prepared_candidate(expected)), prepared_candidate(expected))
                qualified = first.prepare_qualified(expected)
                published = first.mark_published(qualified, evidence=publication(expected))
                self.assertEqual(published.state, "PUBLISHED")
                self.assertEqual(first.load(expected.operation_id), published)
                self.assertEqual(oct(first._path(expected.operation_id).stat().st_mode & 0o777), "0o600")
            finally:
                first.release(expected.operation_id)

            recovered = InstallerReleaseOperationStore(Path(temporary) / "recovered")
            recovered.acquire(expected.operation_id)
            try:
                restored = recovered.recover_published(published)
                self.assertEqual(restored, published)
                pending = recovered.mark_cleanup_pending(restored, evidence=PENDING_CLEANUP)
                self.assertEqual(pending.state, "CLEANUP_PENDING")
                completed = recovered.complete(pending, evidence=COMPLETE_CLEANUP)
                self.assertEqual(completed.state, "RELEASE_COMPLETE")
                self.assertEqual(recovered.complete(completed, evidence=COMPLETE_CLEANUP), completed)
            finally:
                recovered.release(expected.operation_id)

    def test_candidate_is_durable_before_qualification_and_cannot_be_replaced(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            expected = operation()
            store = InstallerReleaseOperationStore(Path(temporary))
            prepared = prepared_candidate(expected)
            store.acquire(expected.operation_id)
            try:
                self.assertEqual(store.prepare_candidate(prepared), prepared)
                self.assertEqual(store.load_preparation(expected.operation_id), prepared)
                self.assertEqual(
                    oct(store._preparation_path(expected.operation_id).stat().st_mode & 0o777),
                    "0o600",
                )
                changed = replace(
                    prepared,
                    preparation=preparation(candidate_manifest_digest="sha256:" + "2" * 64),
                )
                with self.assertRaisesRegex(InstallerReleaseOperationError, "different candidate bytes or provenance"):
                    store.prepare_candidate(changed)
                self.assertEqual(store.prepare_qualified(expected), expected)
            finally:
                store.release(expected.operation_id)

    def test_qualification_requires_matching_durable_prepared_candidate(self) -> None:
        expected = operation()
        with tempfile.TemporaryDirectory() as temporary:
            store = InstallerReleaseOperationStore(Path(temporary))
            store.acquire(expected.operation_id)
            try:
                with self.assertRaisesRegex(InstallerReleaseOperationError, "immutable PREPARED"):
                    store.prepare_qualified(expected)
                store.prepare_candidate(prepared_candidate(expected))
                mismatched_qualification = InstallerQualificationEvidence(
                    source_revision=expected.source_revision,
                    policy_revision=expected.policy_revision,
                    candidate_manifest_digest="sha256:" + "3" * 64,
                    candidate_archives=expected.preparation.candidate_archives,
                    descriptor_digest=expected.descriptor_digest,
                    archives=expected.archives,
                    qualification_receipt_reference="receipt:installer-qualification-mismatched-candidate",
                )
                with self.assertRaisesRegex(InstallerReleaseOperationError, "prepared candidate bytes"):
                    InstallerReleaseOperation.create(
                        operation_id=expected.operation_id,
                        installer_version=expected.installer_version,
                        channel=expected.channel,
                        source_revision=expected.source_revision,
                        policy_revision=expected.policy_revision,
                        release_identity=expected.release_identity,
                        capabilities=expected.capabilities,
                        preparation=expected.preparation,
                        archives=expected.archives,
                        descriptor_digest=expected.descriptor_digest,
                        qualification=mismatched_qualification,
                    )
            finally:
                store.release(expected.operation_id)

    def test_same_operation_retry_requires_every_immutable_installer_fact(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            store = InstallerReleaseOperationStore(Path(temporary))
            expected = operation()
            store.acquire(expected.operation_id)
            try:
                self.assertEqual(store.prepare_candidate(prepared_candidate(expected)), prepared_candidate(expected))
                self.assertEqual(store.prepare_qualified(expected), expected)
                changed_qualification = InstallerReleaseOperation.create(
                    operation_id=expected.operation_id,
                    installer_version=expected.installer_version,
                    channel=expected.channel,
                    source_revision=expected.source_revision,
                    policy_revision=expected.policy_revision,
                    release_identity=expected.release_identity,
                    capabilities=expected.capabilities,
                    preparation=expected.preparation,
                    archives=expected.archives,
                    descriptor_digest=expected.descriptor_digest,
                    qualification=InstallerQualificationEvidence(
                        source_revision=expected.source_revision,
                        policy_revision=expected.policy_revision,
                        candidate_manifest_digest=expected.preparation.candidate_manifest_digest,
                        candidate_archives=expected.preparation.candidate_archives,
                        descriptor_digest=expected.descriptor_digest,
                        archives=expected.archives,
                        qualification_receipt_reference="receipt:installer-qualification-changed",
                    ),
                )
                with self.assertRaisesRegex(InstallerReleaseOperationError, "qualification evidence changed"):
                    store.prepare_qualified(changed_qualification)
                changed_archive = operation(
                    archive_digests=archives(arm64_digest="sha256:" + "e" * 64),
                )
                with self.assertRaisesRegex(InstallerReleaseOperationError, "different immutable identity"):
                    store.prepare_qualified(changed_archive)
                changed_capability = operation(capabilities=("composition/v1", "provider-gate/v2"))
                with self.assertRaisesRegex(InstallerReleaseOperationError, "different candidate bytes or provenance"):
                    store.prepare_candidate(prepared_candidate(changed_capability))
                changed_descriptor = operation(descriptor_digest="sha256:" + "f" * 64)
                with self.assertRaisesRegex(InstallerReleaseOperationError, "different immutable identity"):
                    store.prepare_qualified(changed_descriptor)
                changed_source = operation(source_revision="9" * 40)
                with self.assertRaisesRegex(InstallerReleaseOperationError, "different candidate bytes or provenance"):
                    store.prepare_candidate(prepared_candidate(changed_source))
                changed_policy = operation(policy_revision="forge-platform-installer-release-v2")
                with self.assertRaisesRegex(InstallerReleaseOperationError, "different candidate bytes or provenance"):
                    store.prepare_candidate(prepared_candidate(changed_policy))
                changed_release_identity = operation(release_identity=ALTERNATE_RELEASE_IDENTITY)
                with self.assertRaisesRegex(InstallerReleaseOperationError, "different candidate bytes or provenance"):
                    store.prepare_candidate(prepared_candidate(changed_release_identity))
            finally:
                store.release(expected.operation_id)

    def test_same_github_release_tag_across_channels_with_changed_archive_bytes_fails_before_local_transition(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            first = InstallerReleaseOperationStore(Path(temporary))
            initial = operation("installer-release-0001")
            first.acquire(initial.operation_id)
            try:
                first.prepare_candidate(prepared_candidate(initial))
                first.mark_published(first.prepare_qualified(initial), evidence=publication(initial))
            finally:
                first.release(initial.operation_id)

            contender = operation(
                "installer-release-0002",
                channel="candidate",
                archive_digests=archives(arm64_digest="sha256:" + "e" * 64),
            )
            second = InstallerReleaseOperationStore(Path(temporary))
            second.acquire(contender.operation_id)
            try:
                second.prepare_candidate(prepared_candidate(contender))
                qualified = second.prepare_qualified(contender)
                with self.assertRaisesRegex(InstallerReleaseOperationError, "different bytes or provenance"):
                    second.mark_published(qualified, evidence=publication(contender))
                self.assertEqual(second.load(contender.operation_id), qualified)
            finally:
                second.release(contender.operation_id)

    def test_release_lock_serializes_writers_and_is_required_for_mutation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            expected = operation()
            store = InstallerReleaseOperationStore(Path(temporary))
            contender = InstallerReleaseOperationStore(Path(temporary))
            with self.assertRaisesRegex(InstallerReleaseOperationError, "must own"):
                store.prepare_qualified(expected)
            store.acquire(expected.operation_id)
            try:
                with self.assertRaisesRegex(InstallerReleaseOperationError, "another installer release operation"):
                    contender.acquire("installer-release-0002")
                with self.assertRaisesRegex(InstallerReleaseOperationError, "does not own"):
                    contender.release("installer-release-0002")
            finally:
                store.release(expected.operation_id)
            contender.acquire("installer-release-0002")
            contender.release("installer-release-0002")

    def test_release_lock_serializes_an_independent_process_and_recovers_after_exit(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            expected = operation()
            child_source = (
                "from pathlib import Path\n"
                "import sys\n"
                f"sys.path.insert(0, {str(ROOT)!r})\n"
                "from forge_platform.installer_release_operation import InstallerReleaseOperationStore\n"
                "store = InstallerReleaseOperationStore(Path(sys.argv[1]))\n"
                "store.acquire(sys.argv[2])\n"
                "print('LOCKED', flush=True)\n"
                "sys.stdin.read()\n"
                "store.release(sys.argv[2])\n"
            )
            holder = subprocess.Popen(
                [sys.executable, "-c", child_source, temporary, expected.operation_id],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            try:
                assert holder.stdout is not None
                self.assertEqual(holder.stdout.readline().strip(), "LOCKED")
                contender = InstallerReleaseOperationStore(Path(temporary))
                with self.assertRaisesRegex(InstallerReleaseOperationError, "another installer release operation"):
                    contender.acquire("installer-release-0002")
            finally:
                assert holder.stdin is not None
                holder.stdin.close()
                return_code = holder.wait(timeout=10)
                stderr = holder.stderr.read() if holder.stderr else ""
                if holder.stdout is not None:
                    holder.stdout.close()
                if holder.stderr is not None:
                    holder.stderr.close()
                self.assertEqual(return_code, 0, stderr)

            contender = InstallerReleaseOperationStore(Path(temporary))
            contender.acquire("installer-release-0002")
            contender.release("installer-release-0002")

    def test_typed_evidence_rejects_secret_like_fields_paths_and_wrong_bindings(self) -> None:
        expected = operation()
        record = asdict(expected)
        record["qualification"]["access_token"] = "never-persisted"
        with self.assertRaisesRegex(InstallerReleaseOperationError, "unknown or missing fields"):
            InstallerReleaseOperation.parse(record)
        with self.assertRaisesRegex(InstallerReleaseOperationError, "opaque non-secret"):
            InstallerCleanupEvidence(
                result="CLEANUP_PENDING",
                cleanup_receipt_reference="/private/tmp/unsafe-path",
                target_ids=("operation-cache",),
            )
        with self.assertRaisesRegex(InstallerReleaseOperationError, "target ID"):
            InstallerCleanupEvidence(
                result="CLEANUP_PENDING",
                cleanup_receipt_reference="receipt:cleanup-001",
                target_ids=("/private/tmp/unsafe-path",),
            )
        wrong_publication = InstallerPublicationEvidence(
            github_repository=expected.release_identity.github_repository,
            release_tag="forge-platform-installer-stable-v9.9.9",
            policy_revision=expected.policy_revision,
            descriptor_digest=expected.descriptor_digest,
            archives=expected.archives,
            publication_receipt_reference="receipt:publication-001",
            readback_receipt_reference="receipt:readback-001",
        )
        with self.assertRaisesRegex(InstallerReleaseOperationError, "canonical release identity"):
            expected.transition("PUBLISHED", evidence=wrong_publication)
        wrong_repository_publication = InstallerPublicationEvidence(
            github_repository="other/forge-platform",
            release_tag=expected.release_tag,
            policy_revision=expected.policy_revision,
            descriptor_digest=expected.descriptor_digest,
            archives=expected.archives,
            publication_receipt_reference="receipt:publication-001",
            readback_receipt_reference="receipt:readback-001",
        )
        with self.assertRaisesRegex(InstallerReleaseOperationError, "canonical release identity"):
            expected.transition("PUBLISHED", evidence=wrong_repository_publication)

    def test_store_rejects_duplicate_key_or_non_finite_recovery_records(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            expected = operation()
            store = InstallerReleaseOperationStore(Path(temporary))
            record_path = store._path(expected.operation_id)
            record_path.parent.mkdir(parents=True)
            record_path.write_text(
                '{"operation_id":"first","operation_id":"second"}',
                encoding="utf-8",
            )
            with self.assertRaisesRegex(InstallerReleaseOperationError, "record is unreadable"):
                store.load(expected.operation_id)
            record_path.write_text('{"value":NaN}', encoding="utf-8")
            with self.assertRaisesRegex(InstallerReleaseOperationError, "record is unreadable"):
                store.load(expected.operation_id)

    def test_bad_transitions_and_tampered_recovery_receipt_fail_closed(self) -> None:
        expected = operation()
        with self.assertRaisesRegex(InstallerReleaseOperationError, "not permitted"):
            expected.transition("CLEANUP_PENDING", evidence=PENDING_CLEANUP)
        with self.assertRaisesRegex(InstallerReleaseOperationError, "typed publication"):
            expected.transition("PUBLISHED", evidence=PENDING_CLEANUP)
        published = expected.transition("PUBLISHED", evidence=publication(expected))
        with self.assertRaisesRegex(InstallerReleaseOperationError, "does not match the requested transition"):
            published.transition("CLEANUP_PENDING", evidence=COMPLETE_CLEANUP)

        with tempfile.TemporaryDirectory() as temporary:
            store = InstallerReleaseOperationStore(Path(temporary))
            store.acquire(expected.operation_id)
            try:
                store.prepare_candidate(prepared_candidate(expected))
                store.prepare_qualified(expected)
                store.mark_published(expected, evidence=publication(expected))
            finally:
                store.release(expected.operation_id)

            changed = operation(source_revision="9" * 40)
            tampered_published = changed.transition("PUBLISHED", evidence=publication(changed))
            recovered = InstallerReleaseOperationStore(Path(temporary))
            recovered.acquire(expected.operation_id)
            try:
                with self.assertRaisesRegex(InstallerReleaseOperationError, "different bytes or provenance"):
                    recovered.recover_published(tampered_published)
            finally:
                recovered.release(expected.operation_id)

    def test_direct_successful_cleanup_is_release_complete_without_inventing_pending_failure(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            expected = operation()
            store = InstallerReleaseOperationStore(Path(temporary))
            store.acquire(expected.operation_id)
            try:
                store.prepare_candidate(prepared_candidate(expected))
                published = store.mark_published(store.prepare_qualified(expected), evidence=publication(expected))
                complete = store.complete(published, evidence=COMPLETE_CLEANUP)
                self.assertEqual(complete.state, "RELEASE_COMPLETE")
                self.assertEqual(complete.cleanup, COMPLETE_CLEANUP)
            finally:
                store.release(expected.operation_id)


if __name__ == "__main__":
    unittest.main()
