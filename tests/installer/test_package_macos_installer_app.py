#!/usr/bin/env python3
"""Behavioural checks for the deterministic unsigned macOS app bundler."""

from __future__ import annotations

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

    def test_refuses_to_overwrite_an_existing_output_bundle(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary)
            executable = workspace / "ForgePlatformInstaller"
            executable.write_bytes(b"candidate")
            executable.chmod(0o755)
            app_bundle = workspace / "ForgePlatformInstaller.app"
            app_bundle.mkdir()

            result = self._run(executable, app_bundle)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("must not already exist", result.stderr)

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
    def _run(executable: Path, app_bundle: Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--executable",
                str(executable),
                "--output",
                str(app_bundle),
                "--bundle-identifier",
                "com.example.forge-platform-installer",
            ],
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=False,
        )


if __name__ == "__main__":
    unittest.main()
