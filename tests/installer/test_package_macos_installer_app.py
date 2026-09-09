#!/usr/bin/env python3
"""Behavioural checks for the deterministic unsigned macOS app bundler."""

from __future__ import annotations

import hashlib
import plistlib
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "package_macos_installer_app.py"


class PackageMacOSInstallerAppTests(unittest.TestCase):
    def test_builds_a_minimal_unsigned_app_bundle_with_version_projection(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary)
            executable = workspace / "ForgePlatformInstaller"
            executable.write_bytes(b"native installer candidate bytes\n")
            executable.chmod(0o755)
            app_bundle = workspace / "ForgePlatformInstaller.app"

            result = self._run(executable, app_bundle)

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("INSTALLER_APP_BUNDLE=PASS", result.stdout)
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

    def test_copies_an_explicit_validated_release_trust_resource_verbatim(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary)
            executable = self._executable(workspace)
            trust_resource, trust_bytes = self._release_trust_resource(workspace)
            app_bundle = workspace / "Forge Platform Installer.app"

            result = self._run(executable, app_bundle, trust_resource=trust_resource)

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("sealed_release_trust=PACKAGED", result.stdout)
            self.assertEqual(
                (app_bundle / "Contents" / "Resources" / "ForgePlatformInstallerReleaseTrust.json").read_bytes(),
                trust_bytes,
            )

    def test_rejects_missing_or_malformed_release_trust_resource_before_writing_output(self) -> None:
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
            malformed_resource.write_bytes(b'{"schema_version": 1')
            malformed_output = workspace / "malformed.app"
            malformed = self._run(executable, malformed_output, trust_resource=malformed_resource)

            self.assertNotEqual(malformed.returncode, 0)
            self.assertIn("strict UTF-8 JSON", malformed.stderr)
            self.assertFalse(malformed_output.exists())

            duplicate_resource = workspace / "duplicate-fields.json"
            duplicate_resource.write_text(
                '{"schema_version":1,"schema_version":1}',
                encoding="utf-8",
            )
            duplicate_output = workspace / "duplicate.app"
            duplicate = self._run(executable, duplicate_output, trust_resource=duplicate_resource)

            self.assertNotEqual(duplicate.returncode, 0)
            self.assertIn("strict UTF-8 JSON", duplicate.stderr)
            self.assertFalse(duplicate_output.exists())

    def test_rejects_private_key_fields_and_symlinked_release_trust_resources(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary)
            executable = self._executable(workspace)
            valid_resource, _ = self._release_trust_resource(workspace)
            invalid_private_key_resource = workspace / "unexpected-private-key.json"
            invalid_private_key_resource.write_text(
                "{"
                '"schema_version":1,'
                '"configuration_sha256":"'
                + self._release_trust_digest("test-release-trust-key")
                + '",'
                '"trust_key_reference":"test-release-trust-key",'
                '"private_key":"never-accepted"'
                "}",
                encoding="utf-8",
            )
            private_key_output = workspace / "private-key.app"
            private_key = self._run(executable, private_key_output, trust_resource=invalid_private_key_resource)

            self.assertNotEqual(private_key.returncode, 0)
            self.assertIn("unsupported or missing fields", private_key.stderr)
            self.assertFalse(private_key_output.exists())

            symlink = workspace / "symlinked-release-trust.json"
            symlink.symlink_to(valid_resource)
            symlink_output = workspace / "symlink.app"
            symlinked = self._run(executable, symlink_output, trust_resource=symlink)

            self.assertNotEqual(symlinked.returncode, 0)
            self.assertIn("must not be selected through a symlink", symlinked.stderr)
            self.assertFalse(symlink_output.exists())

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
            executable = workspace / "ForgePlatformInstaller"
            executable.write_bytes(b"same candidate bytes")
            executable.chmod(0o755)
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
            executable = workspace / "ForgePlatformInstaller"
            executable.write_bytes(b"candidate")
            executable.chmod(0o755)
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

    @classmethod
    def _release_trust_resource(cls, workspace: Path) -> tuple[Path, bytes]:
        trust_key_reference = "test-release-trust-key"
        contents = (
            "{\n"
            '  "trust_key_reference": "' + trust_key_reference + '",\n'
            '  "configuration_sha256": "' + cls._release_trust_digest(trust_key_reference) + '",\n'
            '  "schema_version": 1\n'
            "}\n"
        ).encode("utf-8")
        resource = workspace / "caller supplied trust" / "release trust.json"
        resource.parent.mkdir()
        resource.write_bytes(contents)
        return resource, contents

    @staticmethod
    def _release_trust_digest(trust_key_reference: str) -> str:
        payload = "\0".join(
            (
                "forge-platform-installer-release-trust-v1",
                "1",
                trust_key_reference,
            )
        )
        return hashlib.sha256(payload.encode("utf-8")).hexdigest()

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
