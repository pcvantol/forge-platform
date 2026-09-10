#!/usr/bin/env python3
"""Behavioural checks for installer release evidence structural validation."""

from __future__ import annotations

import base64
from dataclasses import asdict
from hashlib import sha256
import json
from pathlib import Path
import plistlib
import stat
import subprocess
import sys
import tempfile
import unittest
import zipfile


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from forge_platform.installer_release_operation import (  # noqa: E402
    InstallerPreparationEvidence,
    InstallerQualificationEvidence,
    InstallerReleaseIdentity,
    InstallerReleaseOperation,
)
from forge_platform.composition_catalog_trust import (  # noqa: E402
    COMPOSITION_CATALOG_TRUST_RESOURCE_NAME,
    canonical_composition_catalog_trust_configuration_sha256,
)
from forge_platform.installer_release_provenance import (  # noqa: E402
    canonical_release_provenance_sha256,
)
from forge_platform.installer_release_trust import (  # noqa: E402
    canonical_release_trust_configuration_sha256,
)
from forge_platform.macos_platform_contract import thin_arm64_macho_test_bytes  # noqa: E402


SCRIPT = ROOT / "scripts" / "verify_installer_release_evidence.py"
SOURCE_SHA = "a" * 40
CAPABILITIES = ["composition/v1", "provider-gate/v1", "system-launchdaemon/v1"]
POLICY_REVISION = "forge-platform-installer-release-v1"
RELEASE_SEQUENCE = 7
TRUST_PUBLIC_KEYS = (
    ("release-key-001", base64.b64encode(bytes(range(32))).decode("ascii")),
)
CATALOG_TRUST_PUBLIC_KEYS = (
    ("catalog-key-001", base64.b64encode(bytes(range(32, 64))).decode("ascii")),
)
RELEASE_TRUST_CONFIGURATION_SHA256 = canonical_release_trust_configuration_sha256(
    repository="example/forge-platform",
    release_descriptor_locator="github-release-asset-v1",
    release_descriptor_asset_name="ForgePlatformInstallerReleaseDescriptor.json",
    expected_bundle_identifier="com.example.forge-platform-installer",
    expected_team_identifier="ABCDE12345",
    signature_threshold=1,
    ed25519_public_keys=TRUST_PUBLIC_KEYS,
)
CODE_DIRECTORY_SHA256 = "e" * 64
NOTARIZATION_RECEIPT_REFERENCE = "receipt:protected-notarization-arm64-001"
CANDIDATE_MANIFEST_DIGEST = "sha256:" + "b" * 64
SIGNATURE_ENVELOPE = {
    "algorithm": "ed25519",
    "key_id": "release-key-001",
    "signature": "A" * 86,
}
IDENTITY = InstallerReleaseIdentity(
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
PROVENANCE_SHA256 = canonical_release_provenance_sha256(
    installer_version="0.1.0",
    channel="stable",
    release_sequence=RELEASE_SEQUENCE,
    source_revision=SOURCE_SHA,
    policy_revision=POLICY_REVISION,
    release_trust_configuration_sha256=RELEASE_TRUST_CONFIGURATION_SHA256,
    capabilities=tuple(CAPABILITIES),
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
            self.assertIn("signature_envelopes=STRUCTURALLY_BOUND", result.stdout)
            self.assertIn("threshold=1", result.stdout)
            self.assertIn("catalog_trust=ABSENT_FAIL_CLOSED", result.stdout)
            self.assertIn("cryptographic_signature_verification=NOT_PERFORMED", result.stdout)

    def test_binds_an_optional_catalog_trust_policy_to_the_archive_v2_scope(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary)
            operation_path, descriptor_path, archive = self._write_release_inputs(
                workspace,
                catalog_trust=self._catalog_trust_payload(),
            )

            result = self._run(operation_path, descriptor_path, archive)

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("catalog_trust=STRUCTURALLY_BOUND_V1", result.stdout)

    def test_rejects_a_self_consistent_catalog_policy_scoped_to_another_v2_trust_configuration(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary)
            operation_path, descriptor_path, archive = self._write_release_inputs(
                workspace,
                catalog_trust=self._catalog_trust_payload(
                    installer_release_trust_configuration_sha256="f" * 64
                ),
            )

            result = self._run(operation_path, descriptor_path, archive)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("catalog trust release trust configuration does not bind", result.stderr)

    def test_rejects_a_malformed_optional_catalog_policy_in_the_signed_archive(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary)
            catalog_trust = self._catalog_trust_payload()
            catalog_trust["catalog_url"] = "https://never-accepted.example.invalid/catalog.json"
            operation_path, descriptor_path, archive = self._write_release_inputs(
                workspace,
                catalog_trust=catalog_trust,
            )

            result = self._run(operation_path, descriptor_path, archive)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("unsupported or missing fields", result.stderr)

    def test_rejects_an_archive_with_changed_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary)
            operation_path, descriptor_path, archive = self._write_release_inputs(workspace)
            archive.write_bytes(b"changed candidate bytes")

            result = self._run(operation_path, descriptor_path, archive)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("archive digest", result.stderr)

    def test_rejects_a_digest_bound_archive_with_the_wrong_macho_architecture(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary)
            operation_path, descriptor_path, archive = self._write_release_inputs(workspace)
            x86_64_header = bytes.fromhex("cffaedfe070000010300000002000000") + bytes(16)
            self._replace_archive_provenance_and_rebind_archive_digest(
                operation_path,
                descriptor_path,
                archive,
                self._provenance_payload(),
                executable_bytes=x86_64_header,
            )

            result = self._run(operation_path, descriptor_path, archive)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("thin arm64 Mach-O executable", result.stderr)

    def test_rejects_descriptor_without_the_exact_macos_26_asset_identity(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary)
            operation_path, descriptor_path, archive = self._write_release_inputs(workspace)
            descriptor = json.loads(descriptor_path.read_text(encoding="utf-8"))
            descriptor["installer"]["assets"][0]["minimum_macos_version"] = "27.0.0"
            descriptor_path.write_text(json.dumps(descriptor), encoding="utf-8")

            result = self._run(operation_path, descriptor_path, archive)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("minimum macOS version", result.stderr)

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

    def test_rejects_github_release_and_asset_name_injection(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary)
            operation_path, descriptor_path, archive = self._write_release_inputs(workspace)
            descriptor = json.loads(descriptor_path.read_text(encoding="utf-8"))
            descriptor["github_release"]["tag"] = "other-release"
            descriptor_path.write_text(json.dumps(descriptor), encoding="utf-8")

            result = self._run(operation_path, descriptor_path, archive)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("GitHub release identity", result.stderr)

            descriptor["github_release"]["tag"] = "forge-platform-installer-v0.1.0"
            descriptor["installer"]["assets"][0]["asset_name"] = "../untrusted.zip"
            descriptor_path.write_text(json.dumps(descriptor), encoding="utf-8")
            result = self._run(operation_path, descriptor_path, archive)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("asset name", result.stderr)

    def test_rejects_a_descriptor_file_not_named_as_its_canonical_github_asset(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary)
            operation_path, descriptor_path, archive = self._write_release_inputs(workspace)
            wrong_name = workspace / "installer-release-descriptor.json"
            descriptor_path.rename(wrong_name)

            result = self._run(operation_path, wrong_name, archive)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("canonical GitHub descriptor asset name", result.stderr)

    def test_rejects_oversized_or_irregular_cli_evidence_before_parsing(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary)
            operation_path, descriptor_path, archive = self._write_release_inputs(workspace)
            descriptor_path.write_bytes(b"x" * ((128 * 1024) + 1))

            result = self._run(operation_path, descriptor_path, archive)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("installer release descriptor has an unsupported size", result.stderr)

            operation_path, descriptor_path, archive = self._write_release_inputs(workspace / "irregular")
            operation_path.unlink()
            operation_path.mkdir()
            result = self._run(operation_path, descriptor_path, archive)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("installer release operation must be a regular file", result.stderr)

    def test_rejects_trust_provenance_and_qualified_code_directory_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary)
            operation_path, descriptor_path, archive = self._write_release_inputs(workspace)
            descriptor = json.loads(descriptor_path.read_text(encoding="utf-8"))
            descriptor["installer"]["release_trust_configuration_sha256"] = "f" * 64
            descriptor_path.write_text(json.dumps(descriptor), encoding="utf-8")

            result = self._run(operation_path, descriptor_path, archive)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("release trust configuration", result.stderr)

            descriptor["installer"]["release_trust_configuration_sha256"] = RELEASE_TRUST_CONFIGURATION_SHA256
            descriptor["installer"]["provenance_sha256"] = "f" * 64
            descriptor_path.write_text(json.dumps(descriptor), encoding="utf-8")
            result = self._run(operation_path, descriptor_path, archive)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("provenance digest", result.stderr)

            descriptor["installer"]["provenance_sha256"] = PROVENANCE_SHA256
            descriptor["installer"]["assets"][0]["code_directory_sha256"] = "f" * 64
            descriptor_path.write_text(json.dumps(descriptor), encoding="utf-8")
            result = self._run(operation_path, descriptor_path, archive)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("CodeDirectory", result.stderr)

    def test_rejects_a_self_consistent_bundled_v2_trust_for_another_repository(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary)
            operation_path, descriptor_path, archive = self._write_release_inputs(workspace)
            self._replace_archive_provenance_and_rebind_archive_digest(
                operation_path,
                descriptor_path,
                archive,
                self._provenance_payload(),
                trust=self._trust_payload(repository="other/forge-platform"),
            )

            result = self._run(operation_path, descriptor_path, archive)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("archive trust configuration", result.stderr)

    def test_rejects_a_self_consistent_bundled_provenance_for_other_source_sequence_or_policy(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary)
            operation_path, descriptor_path, archive = self._write_release_inputs(workspace)
            self._replace_archive_provenance_and_rebind_archive_digest(
                operation_path,
                descriptor_path,
                archive,
                self._provenance_payload(source_revision="b" * 40),
            )

            result = self._run(operation_path, descriptor_path, archive)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("archive provenance digest", result.stderr)

    def test_rejects_a_symlinked_app_root_before_reading_bundled_provenance(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary)
            operation_path, descriptor_path, archive = self._write_release_inputs(workspace)
            self._replace_archive_provenance_and_rebind_archive_digest(
                operation_path,
                descriptor_path,
                archive,
                self._provenance_payload(),
                symlinked_app_root=True,
            )

            result = self._run(operation_path, descriptor_path, archive)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("ancestor must be a directory, never a symlink", result.stderr)

            operation_path, descriptor_path, archive = self._write_release_inputs(workspace / "other-sequence")
            self._replace_archive_provenance_and_rebind_archive_digest(
                operation_path,
                descriptor_path,
                archive,
                self._provenance_payload(release_sequence=RELEASE_SEQUENCE + 1),
            )
            result = self._run(operation_path, descriptor_path, archive)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("archive provenance digest", result.stderr)

            operation_path, descriptor_path, archive = self._write_release_inputs(workspace / "other-policy")
            self._replace_archive_provenance_and_rebind_archive_digest(
                operation_path,
                descriptor_path,
                archive,
                self._provenance_payload(policy_revision="forge-platform-installer-release-v2"),
            )
            result = self._run(operation_path, descriptor_path, archive)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("archive provenance digest", result.stderr)

    def test_rejects_opaque_or_untrusted_descriptor_signature_envelopes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary)
            operation_path, descriptor_path, archive = self._write_release_inputs(workspace)
            descriptor = json.loads(descriptor_path.read_text(encoding="utf-8"))
            descriptor["signatures"] = ["opaque-signature"]
            descriptor_path.write_text(json.dumps(descriptor), encoding="utf-8")

            result = self._run(operation_path, descriptor_path, archive)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("signature envelope", result.stderr)

            descriptor["signatures"] = [{
                "algorithm": "ed25519",
                "key_id": "untrusted-key-002",
                "signature": "A" * 86,
            }]
            descriptor_path.write_text(json.dumps(descriptor), encoding="utf-8")
            result = self._run(operation_path, descriptor_path, archive)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("not trusted by policy", result.stderr)

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
                "--release-sequence",
                str(RELEASE_SEQUENCE),
                "--policy-revision",
                expected_policy_revision,
                "--provenance-sha256",
                PROVENANCE_SHA256,
                "--release-trust-configuration-sha256",
                RELEASE_TRUST_CONFIGURATION_SHA256,
                "--github-repository",
                expected_github_repository,
                "--release-tag",
                expected_release_tag,
                "--descriptor-asset-name",
                IDENTITY.release_descriptor_asset_name,
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
    def _provenance_payload(
        *,
        installer_version: str = "0.1.0",
        channel: str = "stable",
        release_sequence: int = RELEASE_SEQUENCE,
        source_revision: str = SOURCE_SHA,
        policy_revision: str = POLICY_REVISION,
        release_trust_configuration_sha256: str = RELEASE_TRUST_CONFIGURATION_SHA256,
        capabilities: list[str] | None = None,
    ) -> dict[str, object]:
        selected_capabilities = CAPABILITIES if capabilities is None else capabilities
        return {
            "schema_version": 1,
            "provenance_sha256": canonical_release_provenance_sha256(
                installer_version=installer_version,
                channel=channel,
                release_sequence=release_sequence,
                source_revision=source_revision,
                policy_revision=policy_revision,
                release_trust_configuration_sha256=release_trust_configuration_sha256,
                capabilities=tuple(selected_capabilities),
            ),
            "installer_version": installer_version,
            "channel": channel,
            "release_sequence": release_sequence,
            "source_revision": source_revision,
            "policy_revision": policy_revision,
            "capabilities": selected_capabilities,
            "release_trust_configuration_sha256": release_trust_configuration_sha256,
        }

    @staticmethod
    def _trust_payload(
        *,
        repository: str = IDENTITY.github_repository,
        release_descriptor_asset_name: str = IDENTITY.release_descriptor_asset_name,
        expected_bundle_identifier: str = IDENTITY.bundle_identifier,
        expected_team_identifier: str = IDENTITY.team_identifier,
        signature_threshold: int = IDENTITY.signature_threshold,
        ed25519_public_keys: tuple[tuple[str, str], ...] = TRUST_PUBLIC_KEYS,
    ) -> dict[str, object]:
        return {
            "schema_version": 2,
            "configuration_sha256": canonical_release_trust_configuration_sha256(
                repository=repository,
                release_descriptor_locator="github-release-asset-v1",
                release_descriptor_asset_name=release_descriptor_asset_name,
                expected_bundle_identifier=expected_bundle_identifier,
                expected_team_identifier=expected_team_identifier,
                signature_threshold=signature_threshold,
                ed25519_public_keys=ed25519_public_keys,
            ),
            "repository": repository,
            "release_descriptor_locator": "github-release-asset-v1",
            "release_descriptor_asset_name": release_descriptor_asset_name,
            "expected_bundle_identifier": expected_bundle_identifier,
            "expected_team_identifier": expected_team_identifier,
            "signature_threshold": signature_threshold,
            "ed25519_public_keys": [
                {"key_id": key_id, "public_key_base64": public_key_base64}
                for key_id, public_key_base64 in ed25519_public_keys
            ],
        }

    @staticmethod
    def _catalog_trust_payload(
        *,
        installer_release_trust_configuration_sha256: str = RELEASE_TRUST_CONFIGURATION_SHA256,
        signature_threshold: int = 1,
        ed25519_public_keys: tuple[tuple[str, str], ...] = CATALOG_TRUST_PUBLIC_KEYS,
    ) -> dict[str, object]:
        return {
            "schema_version": 1,
            "configuration_sha256": canonical_composition_catalog_trust_configuration_sha256(
                installer_release_trust_configuration_sha256=(
                    installer_release_trust_configuration_sha256
                ),
                signature_threshold=signature_threshold,
                ed25519_public_keys=ed25519_public_keys,
            ),
            "installer_release_trust_configuration_sha256": (
                installer_release_trust_configuration_sha256
            ),
            "signature_threshold": signature_threshold,
            "ed25519_public_keys": [
                {"key_id": key_id, "public_key_base64": public_key_base64}
                for key_id, public_key_base64 in ed25519_public_keys
            ],
        }

    @staticmethod
    def _write_archive(
        archive: Path,
        provenance: dict[str, object],
        *,
        trust: dict[str, object] | None = None,
        catalog_trust: dict[str, object] | None = None,
        symlinked_app_root: bool = False,
        executable_bytes: bytes | None = None,
    ) -> None:
        archive.parent.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as bundle:
            if symlinked_app_root:
                app_root = zipfile.ZipInfo("ForgePlatformInstaller.app")
                app_root.create_system = 3
                app_root.external_attr = (0o120777 << 16)
                bundle.writestr(app_root, b"outside-app-root")
            info = zipfile.ZipInfo("ForgePlatformInstaller.app/Contents/Info.plist")
            info.create_system = 3
            info.external_attr = (stat.S_IFREG | 0o644) << 16
            bundle.writestr(info, plistlib.dumps({
                "CFBundleExecutable": "ForgePlatformInstaller",
                "LSMinimumSystemVersion": "26.0",
            }))
            executable = zipfile.ZipInfo(
                "ForgePlatformInstaller.app/Contents/MacOS/ForgePlatformInstaller"
            )
            executable.create_system = 3
            executable.external_attr = (stat.S_IFREG | 0o755) << 16
            bundle.writestr(
                executable,
                executable_bytes or thin_arm64_macho_test_bytes(b"signed fixture"),
            )
            bundle.writestr(
                "ForgePlatformInstaller.app/Contents/Resources/ForgePlatformInstallerReleaseTrust.json",
                json.dumps(
                    VerifyInstallerReleaseEvidenceTests._trust_payload() if trust is None else trust,
                    sort_keys=True,
                    separators=(",", ":"),
                    allow_nan=False,
                ).encode("utf-8"),
            )
            bundle.writestr(
                "ForgePlatformInstaller.app/Contents/Resources/ForgePlatformInstallerReleaseProvenance.json",
                json.dumps(provenance, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8"),
            )
            if catalog_trust is not None:
                bundle.writestr(
                    (
                        "ForgePlatformInstaller.app/Contents/Resources/"
                        + COMPOSITION_CATALOG_TRUST_RESOURCE_NAME
                    ),
                    json.dumps(
                        catalog_trust,
                        sort_keys=True,
                        separators=(",", ":"),
                        allow_nan=False,
                    ).encode("utf-8"),
                )

    @staticmethod
    def _replace_archive_provenance_and_rebind_archive_digest(
        operation_path: Path,
        descriptor_path: Path,
        archive: Path,
        provenance: dict[str, object],
        *,
        trust: dict[str, object] | None = None,
        catalog_trust: dict[str, object] | None = None,
        symlinked_app_root: bool = False,
        executable_bytes: bytes | None = None,
    ) -> None:
        """Keep archive bytes/evidence self-consistent except for V1 binding."""

        VerifyInstallerReleaseEvidenceTests._write_archive(
            archive,
            provenance,
            trust=trust,
            catalog_trust=catalog_trust,
            symlinked_app_root=symlinked_app_root,
            executable_bytes=executable_bytes,
        )
        archive_digest = "sha256:" + sha256(archive.read_bytes()).hexdigest()
        descriptor = json.loads(descriptor_path.read_text(encoding="utf-8"))
        descriptor["installer"]["assets"][0]["digest"] = archive_digest
        descriptor_raw = json.dumps(descriptor, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")
        descriptor_path.write_bytes(descriptor_raw)
        descriptor_digest = "sha256:" + sha256(descriptor_raw).hexdigest()
        operation = json.loads(operation_path.read_text(encoding="utf-8"))
        operation["preparation"]["candidate_archives"]["arm64"] = archive_digest
        operation["archives"]["arm64"] = archive_digest
        operation["descriptor_digest"] = descriptor_digest
        operation["qualification"]["candidate_archives"]["arm64"] = archive_digest
        operation["qualification"]["archives"]["arm64"] = archive_digest
        operation["qualification"]["descriptor_digest"] = descriptor_digest
        operation_path.write_text(
            json.dumps(operation, sort_keys=True, separators=(",", ":"), allow_nan=False),
            encoding="utf-8",
        )

    @staticmethod
    def _write_release_inputs(
        workspace: Path,
        *,
        catalog_trust: dict[str, object] | None = None,
    ) -> tuple[Path, Path, Path]:
        archive = workspace / "ForgePlatformInstaller-macos-arm64.zip"
        VerifyInstallerReleaseEvidenceTests._write_archive(
            archive,
            VerifyInstallerReleaseEvidenceTests._provenance_payload(),
            catalog_trust=catalog_trust,
        )
        archive_digest = "sha256:" + sha256(archive.read_bytes()).hexdigest()
        descriptor = {
            "schema": "forge-platform.installer-release/v1",
            "sequence": RELEASE_SEQUENCE,
            "channel": "stable",
            "published_at": "2026-09-09T00:00:00Z",
            "expires_at": "2026-10-09T00:00:00Z",
            "github_release": {
                "repository": IDENTITY.github_repository,
                "tag": "forge-platform-installer-v0.1.0",
                "descriptor_asset_name": IDENTITY.release_descriptor_asset_name,
            },
            "installer": {
                        "version": "0.1.0",
                        "source_revision": SOURCE_SHA,
                        "policy_revision": POLICY_REVISION,
                        "release_trust_configuration_sha256": RELEASE_TRUST_CONFIGURATION_SHA256,
                        "provenance_sha256": PROVENANCE_SHA256,
                        "capabilities": CAPABILITIES,
                "assets": [
                    {
                        "operating_system": "macos",
                        "architecture": "arm64",
                        "minimum_macos_version": "26.0.0",
                        "asset_name": "ForgePlatformInstaller-macos-arm64.zip",
                        "digest": archive_digest,
                        "bundle_identifier": IDENTITY.bundle_identifier,
                        "team_identifier": IDENTITY.team_identifier,
                        "code_directory_sha256": CODE_DIRECTORY_SHA256,
                        "notarization_receipt_reference": NOTARIZATION_RECEIPT_REFERENCE,
                    }
                ],
            },
            "composition_catalog": {
                "url": "https://github.com/pcvantol/forge-platform/releases/download/forge-platform-installer-v0.1.0/catalog.json"
            },
            "signatures": [dict(SIGNATURE_ENVELOPE)],
        }
        descriptor_path = workspace / IDENTITY.release_descriptor_asset_name
        descriptor_path.write_bytes(
            json.dumps(descriptor, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")
        )
        descriptor_digest = "sha256:" + sha256(descriptor_path.read_bytes()).hexdigest()
        qualification = InstallerQualificationEvidence(
            source_revision=SOURCE_SHA,
            policy_revision=POLICY_REVISION,
            release_sequence=RELEASE_SEQUENCE,
            provenance_sha256=PROVENANCE_SHA256,
            release_trust_configuration_sha256=RELEASE_TRUST_CONFIGURATION_SHA256,
            candidate_manifest_digest=CANDIDATE_MANIFEST_DIGEST,
            candidate_archives={"arm64": archive_digest},
            descriptor_digest=descriptor_digest,
            archives={"arm64": archive_digest},
            archive_code_directory_sha256={"arm64": CODE_DIRECTORY_SHA256},
            archive_notarization_receipt_references={"arm64": NOTARIZATION_RECEIPT_REFERENCE},
            qualification_receipt_reference="receipt:protected-signing-qualification-001",
        )
        operation = InstallerReleaseOperation.create(
            operation_id="installer-release-0001",
            installer_version="0.1.0",
            channel="stable",
            release_sequence=RELEASE_SEQUENCE,
            source_revision=SOURCE_SHA,
            policy_revision=POLICY_REVISION,
            provenance_sha256=PROVENANCE_SHA256,
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
