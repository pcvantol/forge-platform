#!/usr/bin/env python3
"""Behavioural checks for the deterministic unsigned macOS app bundler."""

from __future__ import annotations

import base64
import hashlib
import json
import plistlib
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "package_macos_installer_app.py"
_PUBLIC_V2_DIGEST = "5988f1dd473caef0a2963f3a6cec06099007e740eced84e3a03fc0e04f343b19"


class PackageMacOSInstallerAppTests(unittest.TestCase):
    def test_builds_a_minimal_unsigned_app_bundle_with_version_projection(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary)
            executable = self._executable(workspace)
            app_bundle = workspace / "ForgePlatformInstaller.app"

            result = self._run(executable, app_bundle)

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("INSTALLER_APP_BUNDLE=PASS", result.stdout)
            self.assertIn("sealed_release_trust=ABSENT_FAIL_CLOSED", result.stdout)
            self.assertEqual(
                (app_bundle / "Contents" / "MacOS" / "ForgePlatformInstaller").read_bytes(),
                executable.read_bytes(),
            )
            self.assertTrue(
                (app_bundle / "Contents" / "MacOS" / "ForgePlatformInstaller").stat().st_mode
                & stat.S_IXUSR
            )
            with (app_bundle / "Contents" / "Info.plist").open("rb") as stream:
                info = plistlib.load(stream)
            self.assertEqual(info["CFBundleExecutable"], "ForgePlatformInstaller")
            self.assertEqual(info["CFBundleIdentifier"], "com.example.forge-platform-installer")
            self.assertEqual(info["CFBundleShortVersionString"], "0.1.0")
            self.assertEqual(info["CFBundleVersion"], "0.1.0")
            self.assertEqual(info["CFBundlePackageType"], "APPL")
            self.assertFalse(
                (app_bundle / "Contents" / "Resources" / "ForgePlatformInstallerReleaseTrust.json").exists()
            )

    def test_copies_an_explicit_validated_v2_resource_verbatim_from_paths_with_spaces(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary)
            executable = self._executable(workspace)
            trust_resource, trust_bytes = self._release_trust_resource(workspace)
            app_bundle = workspace / "Forge Platform Installer.app"

            result = self._run(executable, app_bundle, trust_resource=trust_resource)

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("sealed_release_trust=PACKAGED_V2", result.stdout)
            self.assertEqual(
                (app_bundle / "Contents" / "Resources" / "ForgePlatformInstallerReleaseTrust.json").read_bytes(),
                trust_bytes,
            )

    def test_v2_canonical_digest_matches_the_public_cross_language_vector(self) -> None:
        self.assertEqual(
            self._release_trust_digest(self._public_keys(), signature_threshold=2),
            _PUBLIC_V2_DIGEST,
        )

    def test_rejects_missing_malformed_duplicate_or_nonfinite_resources_before_writing_output(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary)
            executable = self._executable(workspace)

            missing_output = workspace / "missing.app"
            missing = self._run(
                executable,
                missing_output,
                trust_resource=workspace / "does-not-exist.json",
            )
            self.assertNotEqual(missing.returncode, 0)
            self.assertIn("does not exist", missing.stderr)
            self.assertFalse(missing_output.exists())

            malformed_resource = workspace / "malformed.json"
            malformed_resource.write_bytes(b'{"schema_version": 2')
            malformed_output = workspace / "malformed.app"
            malformed = self._run(executable, malformed_output, trust_resource=malformed_resource)
            self.assertNotEqual(malformed.returncode, 0)
            self.assertIn("strict UTF-8 JSON", malformed.stderr)
            self.assertFalse(malformed_output.exists())

            invalid_utf8_resource = workspace / "invalid-utf8.json"
            invalid_utf8_resource.write_bytes(b"\xff")
            invalid_utf8_output = workspace / "invalid-utf8.app"
            invalid_utf8 = self._run(executable, invalid_utf8_output, trust_resource=invalid_utf8_resource)
            self.assertNotEqual(invalid_utf8.returncode, 0)
            self.assertIn("strict UTF-8 JSON", invalid_utf8.stderr)
            self.assertFalse(invalid_utf8_output.exists())

            oversized_resource = workspace / "oversized.json"
            oversized_resource.write_bytes(b" " * ((32 * 1024) + 1))
            oversized_output = workspace / "oversized.app"
            oversized = self._run(executable, oversized_output, trust_resource=oversized_resource)
            self.assertNotEqual(oversized.returncode, 0)
            self.assertIn("exceeds its maximum size", oversized.stderr)
            self.assertFalse(oversized_output.exists())

            duplicate_resource = workspace / "duplicate-fields.json"
            duplicate_resource.write_text(
                self._duplicate_field_json(self._release_trust_payload()),
                encoding="utf-8",
            )
            duplicate_output = workspace / "duplicate.app"
            duplicate = self._run(executable, duplicate_output, trust_resource=duplicate_resource)
            self.assertNotEqual(duplicate.returncode, 0)
            self.assertIn("strict UTF-8 JSON", duplicate.stderr)
            self.assertFalse(duplicate_output.exists())

            nonfinite_resource = workspace / "nonfinite.json"
            nonfinite_resource.write_text('{"signature_threshold":NaN}', encoding="utf-8")
            nonfinite_output = workspace / "nonfinite.app"
            nonfinite = self._run(executable, nonfinite_output, trust_resource=nonfinite_resource)
            self.assertNotEqual(nonfinite.returncode, 0)
            self.assertIn("strict UTF-8 JSON", nonfinite.stderr)
            self.assertFalse(nonfinite_output.exists())

    def test_rejects_private_fields_and_symlinked_resources(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary)
            executable = self._executable(workspace)
            valid_resource, _ = self._release_trust_resource(workspace)

            private_resource = workspace / "unexpected-private-key.json"
            payload = self._release_trust_payload()
            payload["private_key"] = "never-accepted"
            self._write_payload(private_resource, payload)
            private_output = workspace / "private-key.app"
            private_result = self._run(executable, private_output, trust_resource=private_resource)
            self.assertNotEqual(private_result.returncode, 0)
            self.assertIn("unsupported or missing fields", private_result.stderr)
            self.assertFalse(private_output.exists())

            symlink = workspace / "symlinked-release-trust.json"
            symlink.symlink_to(valid_resource)
            symlink_output = workspace / "symlink.app"
            symlink_result = self._run(executable, symlink_output, trust_resource=symlink)
            self.assertNotEqual(symlink_result.returncode, 0)
            self.assertIn("must not be selected through a symlink", symlink_result.stderr)
            self.assertFalse(symlink_output.exists())

    def test_rejects_noncanonical_key_ids_public_keys_order_and_threshold(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary)
            executable = self._executable(workspace)
            public_keys = self._public_keys()

            uppercase_id = [("Descriptor-key-a", public_keys[0][1]), public_keys[1]]
            uppercase_resource = workspace / "uppercase-key-id.json"
            self._write_payload(uppercase_resource, self._release_trust_payload(keys=uppercase_id))
            uppercase = self._run(executable, workspace / "uppercase.app", trust_resource=uppercase_resource)
            self.assertNotEqual(uppercase.returncode, 0)
            self.assertIn("public key ID is invalid", uppercase.stderr)

            unordered_resource = workspace / "unordered-key-ids.json"
            self._write_payload(unordered_resource, self._release_trust_payload(keys=list(reversed(public_keys))))
            unordered = self._run(executable, workspace / "unordered.app", trust_resource=unordered_resource)
            self.assertNotEqual(unordered.returncode, 0)
            self.assertIn("strictly ordered", unordered.stderr)

            duplicate_resource = workspace / "duplicate-key-id.json"
            duplicate_keys = [(public_keys[0][0], public_keys[0][1]), (public_keys[0][0], public_keys[1][1])]
            self._write_payload(duplicate_resource, self._release_trust_payload(keys=duplicate_keys))
            duplicate = self._run(executable, workspace / "duplicate-key.app", trust_resource=duplicate_resource)
            self.assertNotEqual(duplicate.returncode, 0)
            self.assertIn("public keys must be unique", duplicate.stderr)

            invalid_base64_resource = workspace / "noncanonical-public-key.json"
            noncanonical_keys = [(public_keys[0][0], public_keys[0][1] + "\n"), public_keys[1]]
            self._write_payload(invalid_base64_resource, self._release_trust_payload(keys=noncanonical_keys))
            invalid_base64 = self._run(
                executable,
                workspace / "noncanonical-key.app",
                trust_resource=invalid_base64_resource,
            )
            self.assertNotEqual(invalid_base64.returncode, 0)
            self.assertIn("public key is invalid", invalid_base64.stderr)

            threshold_resource = workspace / "threshold-too-large.json"
            self._write_payload(
                threshold_resource,
                self._release_trust_payload(keys=public_keys, signature_threshold=3),
            )
            threshold = self._run(executable, workspace / "threshold.app", trust_resource=threshold_resource)
            self.assertNotEqual(threshold.returncode, 0)
            self.assertIn("threshold exceeds public keys", threshold.stderr)

    def test_refuses_to_overwrite_an_existing_output_bundle(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary)
            executable = self._executable(workspace)
            trust_resource, _ = self._release_trust_resource(workspace)
            app_bundle = workspace / "ForgePlatformInstaller.app"
            app_bundle.mkdir()
            sentinel = app_bundle / "must-not-change"
            sentinel.write_bytes(b"existing output must be preserved")

            result = self._run(executable, app_bundle, trust_resource=trust_resource)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("must not already exist", result.stderr)
            self.assertEqual(sentinel.read_bytes(), b"existing output must be preserved")

    def test_bundle_metadata_is_deterministic_for_the_same_version_and_binary(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary)
            executable = self._executable(workspace)
            first = workspace / "first" / "ForgePlatformInstaller.app"
            second = workspace / "second" / "ForgePlatformInstaller.app"

            self.assertEqual(self._run(executable, first).returncode, 0)
            self.assertEqual(self._run(executable, second).returncode, 0)

            self.assertEqual(
                (first / "Contents" / "Info.plist").read_bytes(),
                (second / "Contents" / "Info.plist").read_bytes(),
            )
            self.assertEqual(
                (first / "Contents" / "MacOS" / "ForgePlatformInstaller").read_bytes(),
                (second / "Contents" / "MacOS" / "ForgePlatformInstaller").read_bytes(),
            )

    def test_rejects_a_non_bundle_identifier_before_writing(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary)
            executable = self._executable(workspace)
            app_bundle = workspace / "ForgePlatformInstaller.app"

            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--executable",
                    str(executable),
                    "--output",
                    str(app_bundle),
                    "--bundle-identifier",
                    "not a bundle identifier",
                ],
                cwd=ROOT,
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("bundle identifier", result.stderr)
            self.assertFalse(app_bundle.exists())

    @staticmethod
    def _executable(workspace: Path) -> Path:
        executable = workspace / "ForgePlatformInstaller"
        executable.write_bytes(b"native installer candidate bytes\n")
        executable.chmod(0o755)
        return executable

    @staticmethod
    def _public_keys() -> list[tuple[str, str]]:
        return [
            ("descriptor-key-a", base64.b64encode(bytes(range(32))).decode("ascii")),
            ("descriptor-key-b", base64.b64encode(bytes(range(32, 64))).decode("ascii")),
        ]

    @classmethod
    def _release_trust_payload(
        cls,
        *,
        keys: list[tuple[str, str]] | None = None,
        signature_threshold: int = 2,
    ) -> dict[str, object]:
        selected_keys = keys if keys is not None else cls._public_keys()
        return {
            "schema_version": 2,
            "configuration_sha256": cls._release_trust_digest(
                selected_keys,
                signature_threshold=signature_threshold,
            ),
            "repository": "example-owner/example-installer",
            "release_descriptor_locator": "github-release-asset-v1",
            "release_descriptor_asset_name": "ForgePlatformInstallerReleaseDescriptor.json",
            "expected_bundle_identifier": "com.example.forge-platform-installer",
            "expected_team_identifier": "AB12CD34EF",
            "signature_threshold": signature_threshold,
            "ed25519_public_keys": [
                {"key_id": key_id, "public_key_base64": public_key_base64}
                for key_id, public_key_base64 in selected_keys
            ],
        }

    @classmethod
    def _release_trust_resource(cls, workspace: Path) -> tuple[Path, bytes]:
        contents = (json.dumps(cls._release_trust_payload(), sort_keys=True, indent=2) + "\n").encode("utf-8")
        resource = workspace / "caller supplied trust" / "release trust.json"
        resource.parent.mkdir()
        resource.write_bytes(contents)
        return resource, contents

    @staticmethod
    def _write_payload(resource: Path, payload: dict[str, object]) -> None:
        resource.write_text(json.dumps(payload, sort_keys=True), encoding="utf-8")

    @staticmethod
    def _duplicate_field_json(payload: dict[str, object]) -> str:
        canonical = json.dumps(payload, separators=(",", ":"))
        return canonical[:-1] + ',"repository":"example-owner/example-installer"}'

    @staticmethod
    def _release_trust_digest(
        keys: list[tuple[str, str]],
        *,
        signature_threshold: int,
    ) -> str:
        fields = [
            "forge-platform-installer-release-trust-v2",
            "schema_version=2",
            "repository=example-owner/example-installer",
            "release_descriptor_locator=github-release-asset-v1",
            "release_descriptor_asset_name=ForgePlatformInstallerReleaseDescriptor.json",
            "expected_bundle_identifier=com.example.forge-platform-installer",
            "expected_team_identifier=AB12CD34EF",
            f"signature_threshold={signature_threshold}",
            f"ed25519_public_key_count={len(keys)}",
        ]
        for key_id, public_key_base64 in keys:
            fields.append(f"ed25519_public_key_id={key_id}")
            fields.append(f"ed25519_public_key_base64={public_key_base64}")
        return hashlib.sha256("\0".join(fields).encode("utf-8")).hexdigest()

    @staticmethod
    def _run(
        executable: Path,
        app_bundle: Path,
        *,
        trust_resource: Path | None = None,
    ) -> subprocess.CompletedProcess[str]:
        command = [
            sys.executable,
            str(SCRIPT),
            "--executable",
            str(executable),
            "--output",
            str(app_bundle),
            "--bundle-identifier",
            "com.example.forge-platform-installer",
        ]
        if trust_resource is not None:
            command.extend(("--sealed-release-trust-resource", str(trust_resource)))
        return subprocess.run(
            command,
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=False,
        )


if __name__ == "__main__":
    unittest.main()
