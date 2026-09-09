#!/usr/bin/env python3
"""Behavioural checks for installer release evidence structural validation."""

from __future__ import annotations

from dataclasses import asdict
from hashlib import sha256
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from forge_platform.installer_release_operation import (  # noqa: E402
    InstallerPreparationEvidence,
    InstallerQualificationEvidence,
    InstallerReleaseIdentity,
    InstallerReleaseOperation,
)


SCRIPT = ROOT / "scripts" / "verify_installer_release_evidence.py"
SOURCE_SHA = "a" * 40
CAPABILITIES = ["composition/v1", "provider-gate/v1", "system-launchdaemon/v1"]
POLICY_REVISION = "forge-platform-installer-release-v1"
CANDIDATE_MANIFEST_DIGEST = "sha256:" + "b" * 64
IDENTITY = InstallerReleaseIdentity(
    github_repository="example/forge-platform",
    bundle_identifier="com.example.forge-platform-installer",
    team_identifier="ABCDE12345",
    release_tag_prefix="forge-platform-installer-v",
    asset_prefix="ForgePlatformInstaller-macos-",
    signature_algorithm="ed25519",
    signature_key_ids=("release-key-001",),
    signature_threshold=1,
)


class VerifyInstallerReleaseEvidenceTests(unittest.TestCase):
    def test_binds_exact_descriptor_archive_and_qualified_operation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary)
            operation_path, descriptor_path, archive = self._write_release_inputs(workspace)

            result = self._run(operation_path, descriptor_path, archive)

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("INSTALLER_RELEASE_EVIDENCE_STRUCTURE=PASS", result.stdout)
            self.assertIn("tag=forge-platform-installer-v0.1.0", result.stdout)
            self.assertIn("cryptographic_signature_verification=NOT_PERFORMED", result.stdout)

    def test_rejects_an_archive_with_changed_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary)
            operation_path, descriptor_path, archive = self._write_release_inputs(workspace)
            archive.write_bytes(b"changed candidate bytes")

            result = self._run(operation_path, descriptor_path, archive)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("archive digest", result.stderr)

    def test_rejects_descriptor_source_or_version_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary)
            operation_path, descriptor_path, archive = self._write_release_inputs(workspace)
            descriptor = json.loads(descriptor_path.read_text(encoding="utf-8"))
            descriptor["installer"]["source_revision"] = "b" * 40
            descriptor_path.write_text(json.dumps(descriptor), encoding="utf-8")

            result = self._run(operation_path, descriptor_path, archive)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("descriptor source revision", result.stderr)

    def test_rejects_a_durable_operation_with_a_different_reviewed_identity(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary)
            operation_path, descriptor_path, archive = self._write_release_inputs(workspace)

            result = self._run(
                operation_path,
                descriptor_path,
                archive,
                expected_github_repository="other/forge-platform",
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("reviewed installer release identity", result.stderr)

    def test_rejects_a_durable_operation_with_a_different_policy_revision(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary)
            operation_path, descriptor_path, archive = self._write_release_inputs(workspace)

            result = self._run(
                operation_path,
                descriptor_path,
                archive,
                expected_policy_revision="forge-platform-installer-release-v2",
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("requested installer release context", result.stderr)

    def test_rejects_an_unsigned_or_unrecognized_descriptor_shape(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary)
            operation_path, descriptor_path, archive = self._write_release_inputs(workspace)
            descriptor = json.loads(descriptor_path.read_text(encoding="utf-8"))
            descriptor["signatures"] = []
            descriptor_path.write_text(json.dumps(descriptor), encoding="utf-8")

            result = self._run(operation_path, descriptor_path, archive)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("signatures", result.stderr)

    @staticmethod
    def _run(
        operation_path: Path,
        descriptor_path: Path,
        archive: Path,
        *,
        expected_github_repository: str = IDENTITY.github_repository,
        expected_policy_revision: str = POLICY_REVISION,
        expected_release_tag: str = "forge-platform-installer-v0.1.0",
        expected_bundle_identifier: str = IDENTITY.bundle_identifier,
        expected_team_identifier: str = IDENTITY.team_identifier,
        expected_asset_prefix: str = IDENTITY.asset_prefix,
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--operation",
                str(operation_path),
                "--descriptor",
                str(descriptor_path),
                "--archive",
                f"arm64={archive}",
                "--source-sha",
                SOURCE_SHA,
                "--operation-id",
                "installer-release-0001",
                "--installer-version",
                "0.1.0",
                "--channel",
                "stable",
                "--policy-revision",
                expected_policy_revision,
                "--github-repository",
                expected_github_repository,
                "--release-tag",
                expected_release_tag,
                "--bundle-identifier",
                expected_bundle_identifier,
                "--team-identifier",
                expected_team_identifier,
                "--asset-prefix",
                expected_asset_prefix,
            ],
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=False,
        )

    @staticmethod
    def _write_release_inputs(workspace: Path) -> tuple[Path, Path, Path]:
        archive = workspace / "ForgePlatformInstaller-macos-arm64.zip"
        archive.write_bytes(b"exact macOS installer app archive")
        archive_digest = "sha256:" + sha256(archive.read_bytes()).hexdigest()
        descriptor = {
            "schema": "forge-platform.installer-release/v1",
            "sequence": 1,
            "channel": "stable",
            "published_at": "2026-09-09T00:00:00Z",
            "expires_at": "2026-10-09T00:00:00Z",
            "installer": {
                        "version": "0.1.0",
                        "source_revision": SOURCE_SHA,
                        "policy_revision": POLICY_REVISION,
                        "capabilities": CAPABILITIES,
                "assets": [
                    {
                        "operating_system": "macos",
                        "architecture": "arm64",
                        "url": "https://github.com/example/forge-platform/releases/download/forge-platform-installer-v0.1.0/ForgePlatformInstaller-macos-arm64.zip",
                        "digest": archive_digest,
                        "bundle_identifier": IDENTITY.bundle_identifier,
                        "team_identifier": IDENTITY.team_identifier,
                        "notarization_evidence": "notarization-reference",
                    }
                ],
            },
            "composition_catalog": {
                "url": "https://github.com/pcvantol/forge-platform/releases/download/forge-platform-installer-v0.1.0/catalog.json"
            },
            "signatures": ["opaque-signature"],
        }
        descriptor_path = workspace / "installer-release-descriptor.json"
        descriptor_path.write_bytes(
            json.dumps(descriptor, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")
        )
        descriptor_digest = "sha256:" + sha256(descriptor_path.read_bytes()).hexdigest()
        qualification = InstallerQualificationEvidence(
            source_revision=SOURCE_SHA,
            policy_revision=POLICY_REVISION,
            candidate_manifest_digest=CANDIDATE_MANIFEST_DIGEST,
            candidate_archives={"arm64": archive_digest},
            descriptor_digest=descriptor_digest,
            archives={"arm64": archive_digest},
            qualification_receipt_reference="receipt:protected-signing-qualification-001",
        )
        operation = InstallerReleaseOperation.create(
            operation_id="installer-release-0001",
            installer_version="0.1.0",
            channel="stable",
            source_revision=SOURCE_SHA,
            policy_revision=POLICY_REVISION,
            release_identity=IDENTITY,
            capabilities=CAPABILITIES,
            preparation=InstallerPreparationEvidence(
                candidate_manifest_digest=CANDIDATE_MANIFEST_DIGEST,
                candidate_archives={"arm64": archive_digest},
                preparation_receipt_reference="receipt:installer-preparation-001",
            ),
            archives={"arm64": archive_digest},
            descriptor_digest=descriptor_digest,
            qualification=qualification,
        )
        operation_path = workspace / "installer-release-operation.json"
        operation_path.write_text(
            json.dumps(asdict(operation), sort_keys=True, separators=(",", ":"), allow_nan=False),
            encoding="utf-8",
        )
        return operation_path, descriptor_path, archive


if __name__ == "__main__":
    unittest.main()
