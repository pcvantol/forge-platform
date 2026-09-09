#!/usr/bin/env python3
"""Behavioural checks for immutable installer candidate preparation."""

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
    INSTALLER_RELEASE_POLICY_REVISION,
    InstallerReleaseOperationStore,
    InstallerReleasePreparation,
)


SCRIPT = ROOT / "scripts" / "prepare_installer_release_candidate.py"
SOURCE_SHA = "a" * 40
VERSION = "0.1.0"
CHANNEL = "stable"
OPERATION_ID = "installer-release-0001"
ASSET_NAME = "ForgePlatformInstaller-macos-arm64.zip"


class PrepareInstallerReleaseCandidateTests(unittest.TestCase):
    def test_persists_exact_candidate_before_qualification_and_resumes_only_identically(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary) / "candidate with spaces"
            workspace.mkdir()
            inputs = self._write_inputs(workspace)

            first = self._run(inputs)

            self.assertEqual(first.returncode, 0, first.stderr)
            self.assertIn("INSTALLER_RELEASE_PREPARATION=PREPARED", first.stdout)
            preparation = InstallerReleasePreparation.parse(
                json.loads(inputs["output"].read_text(encoding="utf-8"))
            )
            self.assertEqual(preparation.operation_id, OPERATION_ID)
            self.assertEqual(preparation.preparation.candidate_archives["arm64"], inputs["archive_digest"])
            self.assertEqual(
                InstallerReleaseOperationStore(inputs["journal_root"]).load_preparation(OPERATION_ID),
                preparation,
            )
            self.assertEqual(self._run(inputs).returncode, 0)

            inputs["archive"].write_bytes(b"different unsigned candidate bytes")
            self._rewrite_candidate_manifest(inputs)
            changed = self._run(inputs)

            self.assertNotEqual(changed.returncode, 0)
            self.assertIn("different candidate bytes or provenance", changed.stderr)
            self.assertEqual(
                InstallerReleasePreparation.parse(json.loads(inputs["output"].read_text(encoding="utf-8"))),
                preparation,
            )

    def test_rejects_symlinked_archive_or_candidate_context_mismatch_before_preparation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary)
            inputs = self._write_inputs(workspace)
            linked_archive = workspace / "linked archive.zip"
            linked_archive.symlink_to(inputs["archive"])
            result = self._run(inputs, archive=linked_archive)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("must not be selected through a symlink", result.stderr)
            self.assertFalse(inputs["output"].exists())

            manifest = json.loads(inputs["manifest"].read_text(encoding="utf-8"))
            manifest["bundle_identifier"] = "com.example.other"
            inputs["manifest"].write_text(json.dumps(manifest), encoding="utf-8")
            mismatch = self._run(inputs)
            self.assertNotEqual(mismatch.returncode, 0)
            self.assertIn("bundle_identifier", mismatch.stderr)
            self.assertFalse(inputs["output"].exists())

    def test_requires_a_ready_reviewed_release_identity(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary)
            inputs = self._write_inputs(workspace)
            inputs["identity"].write_text(
                json.dumps(
                    {
                        "schema": "forge-platform.installer-release-identity/v1",
                        "status": "UNCONFIGURED",
                        "identity": None,
                        "signing_key_policy": None,
                    }
                ),
                encoding="utf-8",
            )

            result = self._run(inputs)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("publication is blocked", result.stderr)
            self.assertFalse(inputs["output"].exists())

    @staticmethod
    def _write_inputs(workspace: Path) -> dict[str, object]:
        workspace.mkdir(parents=True, exist_ok=True)
        archive = workspace / ASSET_NAME
        archive.write_bytes(b"exact unsigned macOS installer candidate")
        identity = workspace / "reviewed-identity.json"
        identity.write_text(
            json.dumps(
                {
                    "schema": "forge-platform.installer-release-identity/v1",
                    "status": "READY",
                    "identity": {
                        "github_repository": "example/forge-platform",
                        "bundle_identifier": "com.example.forge-platform-installer",
                        "team_identifier": "ABCDE12345",
                        "release_tag_prefix": "forge-platform-installer-v",
                        "asset_prefix": "ForgePlatformInstaller-macos-",
                    },
                    "signing_key_policy": {
                        "algorithm": "ed25519",
                        "key_ids": ["release-key-001"],
                        "threshold": 1,
                    },
                },
                sort_keys=True,
            ),
            encoding="utf-8",
        )
        result: dict[str, object] = {
            "archive": archive,
            "identity": identity,
            "manifest": workspace / "installer-candidate.json",
            "journal_root": workspace / "journal",
            "output": workspace / "handoff" / "installer-release-preparation.json",
        }
        PrepareInstallerReleaseCandidateTests._rewrite_candidate_manifest(result)
        return result

    @staticmethod
    def _rewrite_candidate_manifest(inputs: dict[str, object]) -> None:
        archive = inputs["archive"]
        assert isinstance(archive, Path)
        digest = "sha256:" + sha256(archive.read_bytes()).hexdigest()
        manifest = inputs["manifest"]
        assert isinstance(manifest, Path)
        manifest.write_text(
            json.dumps(
                {
                    "schema": "forge-platform.installer-candidate/v1",
                    "product": "forge-platform-installer",
                    "source_revision": SOURCE_SHA,
                    "version": VERSION,
                    "channel": CHANNEL,
                    "policy_revision": INSTALLER_RELEASE_POLICY_REVISION,
                    "bundle_identifier": "com.example.forge-platform-installer",
                    "capabilities": ["composition/v1", "provider-gate/v1"],
                    "archives": {
                        "arm64": {
                            "name": ASSET_NAME,
                            "digest": digest,
                            "packaging": "UNSIGNED_APP_CANDIDATE",
                        }
                    },
                },
                sort_keys=True,
                separators=(",", ":"),
            ) + "\n",
            encoding="utf-8",
        )
        inputs["archive_digest"] = digest

    @staticmethod
    def _run(
        inputs: dict[str, object],
        *,
        archive: Path | None = None,
    ) -> subprocess.CompletedProcess[str]:
        candidate_archive = archive or inputs["archive"]
        assert isinstance(candidate_archive, Path)
        manifest = inputs["manifest"]
        identity = inputs["identity"]
        journal_root = inputs["journal_root"]
        output = inputs["output"]
        assert isinstance(manifest, Path)
        assert isinstance(identity, Path)
        assert isinstance(journal_root, Path)
        assert isinstance(output, Path)
        return subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--candidate-manifest", str(manifest),
                "--archive", f"arm64={candidate_archive}",
                "--source-sha", SOURCE_SHA,
                "--operation-id", OPERATION_ID,
                "--installer-version", VERSION,
                "--channel", CHANNEL,
                "--policy-revision", INSTALLER_RELEASE_POLICY_REVISION,
                "--release-identity", str(identity),
                "--journal-root", str(journal_root),
                "--output", str(output),
                "--preparation-receipt-reference", "receipt:installer-preparation-001",
            ],
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=False,
        )


if __name__ == "__main__":
    unittest.main()
