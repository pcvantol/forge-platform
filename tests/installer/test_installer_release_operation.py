#!/usr/bin/env python3
"""Behavioral checks for the separately versioned installer release journal."""

from __future__ import annotations

from dataclasses import asdict, replace
import os
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
CANDIDATE_MANIFEST_DIGEST = "sha256:" + "e" * 64
ARM64_CANDIDATE_DIGEST = "sha256:" + "f" * 64
RELEASE_SEQUENCE = 7
PROVENANCE_SHA256 = "2" * 64
RELEASE_TRUST_CONFIGURATION_SHA256 = "3" * 64
ARM64_CODE_DIRECTORY_SHA256 = "4" * 64
CAPABILITIES = ("composition/v1", "provider-gate/v1", "system-launchdaemon/v1")
POLICY_REVISION = "forge-platform-installer-release-v1"
RELEASE_IDENTITY = InstallerReleaseIdentity(
    github_repository="example/forge-platform",
    bundle_identifier="com.example.forge-platform-installer",
    team_identifier="ABCDE12345",
    release_tag_prefix="forge-platform-installer-v",
    asset_prefix="ForgePlatformInstaller-macos-",
    release_descriptor_asset_name="ForgePlatformInstallerReleaseDescriptor.json",
    release_trust_configuration_sha256=RELEASE_TRUST_CONFIGURATION_SHA256,
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
    release_descriptor_asset_name="ForgePlatformInstallerReleaseDescriptor.json",
    release_trust_configuration_sha256="6" * 64,
    signature_algorithm="ed25519",
    signature_key_ids=("release-key-002",),
    signature_threshold=1,
)


def archives(*, arm64_digest: str = ARM64_ARCHIVE_DIGEST) -> dict[str, str]:
    return {"arm64": arm64_digest}


def candidate_archives(*, arm64_digest: str = ARM64_CANDIDATE_DIGEST) -> dict[str, str]:
    return {"arm64": arm64_digest}


def code_directories() -> dict[str, str]:
    return {"arm64": ARM64_CODE_DIRECTORY_SHA256}


def notarization_receipts() -> dict[str, str]:
    return {"arm64": "receipt:installer-notarization-arm64-001"}


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
    release_sequence: int = RELEASE_SEQUENCE,
    provenance_sha256: str = PROVENANCE_SHA256,
    release_trust_configuration_sha256: str = RELEASE_TRUST_CONFIGURATION_SHA256,
    descriptor_digest: str = DESCRIPTOR_DIGEST,
    archive_digests: dict[str, str] | None = None,
    archive_code_directory_sha256: dict[str, str] | None = None,
    archive_notarization_receipt_references: dict[str, str] | None = None,
    candidate_manifest_digest: str = CANDIDATE_MANIFEST_DIGEST,
    candidate_archive_digests: dict[str, str] | None = None,
) -> InstallerQualificationEvidence:
    return InstallerQualificationEvidence(
        source_revision=source_revision,
        policy_revision=policy_revision,
        release_sequence=release_sequence,
        provenance_sha256=provenance_sha256,
        release_trust_configuration_sha256=release_trust_configuration_sha256,
        candidate_manifest_digest=candidate_manifest_digest,
        candidate_archives=candidate_archive_digests or candidate_archives(),
        descriptor_digest=descriptor_digest,
        archives=archive_digests or archives(),
        archive_code_directory_sha256=archive_code_directory_sha256 or code_directories(),
        archive_notarization_receipt_references=(
            archive_notarization_receipt_references or notarization_receipts()
        ),
        qualification_receipt_reference="receipt:installer-qualification-001",
    )


def operation(
    identifier: str = "installer-release-0001",
    *,
    version: str = "1.1.0",
    channel: str = "stable",
    release_sequence: int = RELEASE_SEQUENCE,
    source_revision: str = SOURCE_REVISION,
    policy_revision: str = POLICY_REVISION,
    provenance_sha256: str = PROVENANCE_SHA256,
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
        release_sequence=release_sequence,
        source_revision=source_revision,
        policy_revision=policy_revision,
        provenance_sha256=provenance_sha256,
        release_identity=release_identity,
        capabilities=capabilities,
        preparation=prepared,
        archives=archive_digests,
        descriptor_digest=descriptor_digest,
        qualification=qualification(
            source_revision=source_revision,
            policy_revision=policy_revision,
            release_sequence=release_sequence,
            provenance_sha256=provenance_sha256,
            release_trust_configuration_sha256=release_identity.release_trust_configuration_sha256,
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
        release_sequence=operation.release_sequence,
        source_revision=operation.source_revision,
        policy_revision=operation.policy_revision,
        provenance_sha256=operation.provenance_sha256,
        release_identity=operation.release_identity,
        capabilities=operation.capabilities,
        preparation=operation.preparation,
    )


def publication(expected: InstallerReleaseOperation) -> InstallerPublicationEvidence:
    return InstallerPublicationEvidence(
        github_repository=expected.release_identity.github_repository,
        release_tag=expected.release_tag,
        policy_revision=expected.policy_revision,
        release_sequence=expected.release_sequence,
        provenance_sha256=expected.provenance_sha256,
        release_trust_configuration_sha256=expected.release_identity.release_trust_configuration_sha256,
        descriptor_asset_name=expected.release_identity.release_descriptor_asset_name,
        descriptor_digest=expected.descriptor_digest,
        descriptor_readback_digest=expected.descriptor_digest,
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
                    release_sequence=expected.release_sequence,
                    provenance_sha256=expected.provenance_sha256,
                    release_trust_configuration_sha256=expected.release_identity.release_trust_configuration_sha256,
                    candidate_manifest_digest="sha256:" + "3" * 64,
                    candidate_archives=expected.preparation.candidate_archives,
                    descriptor_digest=expected.descriptor_digest,
                    archives=expected.archives,
                    archive_code_directory_sha256=code_directories(),
                    archive_notarization_receipt_references=notarization_receipts(),
                    qualification_receipt_reference="receipt:installer-qualification-mismatched-candidate",
                )
                with self.assertRaisesRegex(InstallerReleaseOperationError, "prepared candidate bytes"):
                    InstallerReleaseOperation.create(
                        operation_id=expected.operation_id,
                        installer_version=expected.installer_version,
                        channel=expected.channel,
                        release_sequence=expected.release_sequence,
                        source_revision=expected.source_revision,
                        policy_revision=expected.policy_revision,
                        provenance_sha256=expected.provenance_sha256,
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
                    release_sequence=expected.release_sequence,
                    source_revision=expected.source_revision,
                    policy_revision=expected.policy_revision,
                    provenance_sha256=expected.provenance_sha256,
                    release_identity=expected.release_identity,
                    capabilities=expected.capabilities,
                    preparation=expected.preparation,
                    archives=expected.archives,
                    descriptor_digest=expected.descriptor_digest,
                    qualification=InstallerQualificationEvidence(
                        source_revision=expected.source_revision,
                        policy_revision=expected.policy_revision,
                        release_sequence=expected.release_sequence,
                        provenance_sha256=expected.provenance_sha256,
                        release_trust_configuration_sha256=expected.release_identity.release_trust_configuration_sha256,
                        candidate_manifest_digest=expected.preparation.candidate_manifest_digest,
                        candidate_archives=expected.preparation.candidate_archives,
                        descriptor_digest=expected.descriptor_digest,
                        archives=expected.archives,
                        archive_code_directory_sha256=code_directories(),
                        archive_notarization_receipt_references=notarization_receipts(),
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
                release_sequence=RELEASE_SEQUENCE + 1,
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

    def test_same_release_sequence_cannot_be_reused_for_different_candidate_provenance(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            initial = operation("installer-release-0001")
            first = InstallerReleaseOperationStore(Path(temporary))
            first.acquire(initial.operation_id)
            try:
                first.prepare_candidate(prepared_candidate(initial))
            finally:
                first.release(initial.operation_id)

            contender = operation(
                "installer-release-0002",
                candidate_manifest_digest="sha256:" + "6" * 64,
            )
            second = InstallerReleaseOperationStore(Path(temporary))
            second.acquire(contender.operation_id)
            try:
                with self.assertRaisesRegex(InstallerReleaseOperationError, "sequence is already reserved"):
                    second.prepare_candidate(prepared_candidate(contender))
            finally:
                second.release(contender.operation_id)

    def test_release_sequence_is_monotonic_and_direct_save_cannot_skip_preparation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            expected = operation("installer-release-0001", release_sequence=100)
            store = InstallerReleaseOperationStore(Path(temporary))
            store.acquire(expected.operation_id)
            try:
                with self.assertRaisesRegex(InstallerReleaseOperationError, "requires an immutable PREPARED"):
                    store.save(expected)
                self.assertIsNone(store.load(expected.operation_id))
                self.assertFalse(store._sequence_path(expected.release_sequence).exists())
                store.prepare_candidate(prepared_candidate(expected))
            finally:
                store.release(expected.operation_id)

            lower = operation("installer-release-0002", release_sequence=99)
            contender = InstallerReleaseOperationStore(Path(temporary))
            contender.acquire(lower.operation_id)
            try:
                with self.assertRaisesRegex(InstallerReleaseOperationError, "strictly higher"):
                    contender.prepare_candidate(prepared_candidate(lower))
                self.assertFalse(contender._sequence_path(lower.release_sequence).exists())
            finally:
                contender.release(lower.operation_id)

    def test_unsafe_sequence_reservation_directory_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            expected = operation()
            (root / "sequences").write_text("not a directory", encoding="utf-8")
            store = InstallerReleaseOperationStore(root)
            store.acquire(expected.operation_id)
            try:
                with self.assertRaisesRegex(InstallerReleaseOperationError, "directory is unsafe"):
                    store.prepare_candidate(prepared_candidate(expected))
            finally:
                store.release(expected.operation_id)

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            expected = operation()
            target = root / "outside-sequences"
            target.mkdir()
            (root / "sequences").symlink_to(target, target_is_directory=True)
            store = InstallerReleaseOperationStore(root)
            store.acquire(expected.operation_id)
            try:
                with self.assertRaisesRegex(InstallerReleaseOperationError, "directory is unsafe"):
                    store.prepare_candidate(prepared_candidate(expected))
            finally:
                store.release(expected.operation_id)

    def test_malformed_highest_sequence_reservation_fails_closed_not_as_a_frontier(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            reservations = root / "sequences"
            reservations.mkdir()
            (reservations / "999.json").write_text('{"release_sequence":999}', encoding="utf-8")
            expected = operation(release_sequence=1000)
            store = InstallerReleaseOperationStore(root)
            store.acquire(expected.operation_id)
            try:
                with self.assertRaisesRegex(InstallerReleaseOperationError, "sequence reservation is unreadable"):
                    store.prepare_candidate(prepared_candidate(expected))
                self.assertFalse(store._sequence_path(expected.release_sequence).exists())
            finally:
                store.release(expected.operation_id)

    def test_a_resumed_lower_sequence_cannot_qualify_or_publish_after_a_higher_reservation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            lower = operation("installer-release-0001", version="1.0.0", release_sequence=7)
            first = InstallerReleaseOperationStore(root)
            first.acquire(lower.operation_id)
            try:
                first.prepare_candidate(prepared_candidate(lower))
            finally:
                first.release(lower.operation_id)

            higher = operation("installer-release-0002", version="1.1.0", release_sequence=8)
            second = InstallerReleaseOperationStore(root)
            second.acquire(higher.operation_id)
            try:
                second.prepare_candidate(prepared_candidate(higher))
                second.mark_published(second.prepare_qualified(higher), evidence=publication(higher))
            finally:
                second.release(higher.operation_id)

            resumed = InstallerReleaseOperationStore(root)
            resumed.acquire(lower.operation_id)
            try:
                with self.assertRaisesRegex(InstallerReleaseOperationError, "reservation frontier"):
                    resumed.prepare_qualified(lower)
                self.assertIsNone(resumed.load(lower.operation_id))
            finally:
                resumed.release(lower.operation_id)

    def test_verified_lost_answer_recovery_can_record_a_historic_publication_after_a_higher_reservation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            historical = operation(
                "installer-release-0001",
                version="1.0.0",
                release_sequence=7,
            )
            externally_published = historical.transition("PUBLISHED", evidence=publication(historical))
            higher = operation("installer-release-0002", version="1.1.0", release_sequence=8)
            allocator = InstallerReleaseOperationStore(root)
            allocator.acquire(higher.operation_id)
            try:
                allocator.prepare_candidate(prepared_candidate(higher))
            finally:
                allocator.release(higher.operation_id)

            recovered = InstallerReleaseOperationStore(root)
            recovered.acquire(externally_published.operation_id)
            try:
                self.assertEqual(recovered.recover_published(externally_published).state, "PUBLISHED")
                self.assertTrue(recovered._sequence_path(7).exists())
            finally:
                recovered.release(externally_published.operation_id)

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

    def test_release_lock_symlink_fails_closed_without_writing_its_target(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            outside = root / "unrelated-same-user-file"
            outside.write_text("must remain unchanged\n", encoding="utf-8")
            (root / "installer-release-operation.lock").symlink_to(outside)
            store = InstallerReleaseOperationStore(root)

            with self.assertRaisesRegex(InstallerReleaseOperationError, "lock is unsafe or unavailable"):
                store.acquire("installer-release-0001")

            self.assertEqual(outside.read_text(encoding="utf-8"), "must remain unchanged\n")

    def test_store_root_symlink_or_writable_mode_fails_closed_before_lock_creation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary)
            outside = workspace / "outside-root"
            outside.mkdir()
            redirected = workspace / "redirected-root"
            redirected.symlink_to(outside, target_is_directory=True)

            with self.assertRaisesRegex(InstallerReleaseOperationError, "store root is unsafe"):
                InstallerReleaseOperationStore(redirected).acquire("installer-release-0001")

            self.assertFalse((outside / "installer-release-operation.lock").exists())

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "writable-root"
            root.mkdir()
            os.chmod(root, 0o777)
            try:
                with self.assertRaisesRegex(InstallerReleaseOperationError, "store root is unsafe"):
                    InstallerReleaseOperationStore(root).acquire("installer-release-0001")
                self.assertFalse((root / "installer-release-operation.lock").exists())
            finally:
                os.chmod(root, 0o700)

    def test_journal_child_directory_symlinks_fail_closed_without_writing_targets(self) -> None:
        for directory in ("operations", "preparations", "sequences", "published"):
            with self.subTest(directory=directory), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary) / "journal"
                root.mkdir()
                outside = Path(temporary) / f"outside-{directory}"
                outside.mkdir()
                (root / directory).symlink_to(outside, target_is_directory=True)
                expected = operation()
                store = InstallerReleaseOperationStore(root)
                store.acquire(expected.operation_id)
                try:
                    with self.assertRaises(InstallerReleaseOperationError):
                        if directory == "preparations" or directory == "sequences":
                            store.prepare_candidate(prepared_candidate(expected))
                        elif directory == "operations":
                            store.prepare_candidate(prepared_candidate(expected))
                            store.prepare_qualified(expected)
                        else:
                            store.prepare_candidate(prepared_candidate(expected))
                            qualified = store.prepare_qualified(expected)
                            store.mark_published(qualified, evidence=publication(expected))
                    self.assertEqual(list(outside.iterdir()), [])
                finally:
                    store.release(expected.operation_id)

    def test_operation_record_symlink_or_writable_mode_is_not_a_recovery_input(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "journal"
            expected = operation()
            store = InstallerReleaseOperationStore(root)
            store.acquire(expected.operation_id)
            try:
                store.prepare_candidate(prepared_candidate(expected))
                store.prepare_qualified(expected)
            finally:
                store.release(expected.operation_id)

            record = store._path(expected.operation_id)
            outside = Path(temporary) / "outside-operation.json"
            outside.write_bytes(record.read_bytes())
            record.unlink()
            record.symlink_to(outside)
            with self.assertRaisesRegex(InstallerReleaseOperationError, "record is unreadable"):
                store.load(expected.operation_id)

            record.unlink()
            record.write_bytes(outside.read_bytes())
            os.chmod(record, 0o666)
            try:
                with self.assertRaisesRegex(InstallerReleaseOperationError, "record is unreadable"):
                    store.load(expected.operation_id)
            finally:
                os.chmod(record, 0o600)

            record.write_bytes(b"x" * ((512 * 1024) + 1))
            with self.assertRaisesRegex(InstallerReleaseOperationError, "record is unreadable"):
                store.load(expected.operation_id)

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
        with self.assertRaisesRegex(InstallerReleaseOperationError, "UInt64"):
            operation(release_sequence=(1 << 64))
        with self.assertRaisesRegex(InstallerReleaseOperationError, "exactly one arm64"):
            InstallerPreparationEvidence(
                candidate_manifest_digest=CANDIDATE_MANIFEST_DIGEST,
                candidate_archives={"x86_64": ARM64_CANDIDATE_DIGEST},
                preparation_receipt_reference="receipt:installer-preparation-001",
            )
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
            release_sequence=expected.release_sequence,
            provenance_sha256=expected.provenance_sha256,
            release_trust_configuration_sha256=expected.release_identity.release_trust_configuration_sha256,
            descriptor_asset_name=expected.release_identity.release_descriptor_asset_name,
            descriptor_digest=expected.descriptor_digest,
            descriptor_readback_digest=expected.descriptor_digest,
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
            release_sequence=expected.release_sequence,
            provenance_sha256=expected.provenance_sha256,
            release_trust_configuration_sha256=expected.release_identity.release_trust_configuration_sha256,
            descriptor_asset_name=expected.release_identity.release_descriptor_asset_name,
            descriptor_digest=expected.descriptor_digest,
            descriptor_readback_digest=expected.descriptor_digest,
            archives=expected.archives,
            publication_receipt_reference="receipt:publication-001",
            readback_receipt_reference="receipt:readback-001",
        )
        with self.assertRaisesRegex(InstallerReleaseOperationError, "canonical release identity"):
            expected.transition("PUBLISHED", evidence=wrong_repository_publication)
        wrong_descriptor_asset = replace(
            publication(expected),
            descriptor_asset_name="OtherInstallerReleaseDescriptor.json",
        )
        with self.assertRaisesRegex(InstallerReleaseOperationError, "canonical release identity"):
            expected.transition("PUBLISHED", evidence=wrong_descriptor_asset)
        wrong_descriptor_readback = replace(
            publication(expected),
            descriptor_readback_digest="sha256:" + "f" * 64,
        )
        with self.assertRaisesRegex(InstallerReleaseOperationError, "canonical release identity"):
            expected.transition("PUBLISHED", evidence=wrong_descriptor_readback)

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
