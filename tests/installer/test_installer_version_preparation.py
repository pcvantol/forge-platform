#!/usr/bin/env python3
"""Behavioural coverage for the independent installer version authority."""
from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "installer_versioning", ROOT / "scripts/advance_installer_version.py"
)
assert SPEC and SPEC.loader
installer_versioning = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(installer_versioning)


class InstallerVersionPreparationTests(unittest.TestCase):
    def repo(self) -> tuple[tempfile.TemporaryDirectory[str], Path, str]:
        temporary = tempfile.TemporaryDirectory()
        root = Path(temporary.name)
        (root / "installer-version.json").write_text(
            json.dumps(
                {
                    "schema": "forge-platform.installer-version/v1",
                    "product": "forge-platform-installer",
                    "version": "0.1.0",
                    "channel": "stable",
                    "capabilities": ["composition/v1", "provider-gate/v1"],
                }
            )
            + "\n",
            encoding="utf-8",
        )
        projection = root / installer_versioning.SWIFT_PROJECTION_PATH
        projection.parent.mkdir(parents=True)
        projection.write_text(
            "enum InstallerBuild {\n"
            '    static let currentVersion = try! InstallerVersion("0.1.0")\n'
            "}\n",
            encoding="utf-8",
        )
        subprocess.run(["git", "init", "-q", str(root)], check=True)
        subprocess.run(["git", "-C", str(root), "add", "."], check=True)
        subprocess.run(
            [
                "git", "-C", str(root), "-c", "user.name=t", "-c", "user.email=t@x",
                "commit", "-qm", "base",
            ],
            check=True,
        )
        return temporary, root, installer_versioning._head(root)

    @staticmethod
    def commit(root: Path, subject: str) -> str:
        subprocess.run(["git", "-C", str(root), "add", "."], check=True)
        subprocess.run(
            [
                "git", "-C", str(root), "-c", "user.name=t", "-c", "user.email=t@x",
                "commit", "-qm", subject,
            ],
            check=True,
        )
        return installer_versioning._head(root)

    def test_plan_is_read_only_and_retry_repairs_partial_projection(self) -> None:
        temporary, root, head = self.repo()
        with temporary:
            operation_id = "installer-version-0001"
            planned = installer_versioning.plan(root, operation_id, "increment:self-update", head, "patch", None)
            self.assertEqual(planned["target_version"], "0.1.1")
            self.assertFalse((root / installer_versioning.OPERATIONS_DIRECTORY).exists())

            applied = installer_versioning.apply(root, operation_id, "increment:self-update", head, "patch", None)
            self.assertEqual(applied["state"], "APPLIED")
            self.assertEqual(installer_versioning.plan(root, operation_id, "increment:self-update", head, "patch", None)["target_version"], "0.1.1")

            projection = root / installer_versioning.SWIFT_PROJECTION_PATH
            projection.write_text(
                'static let currentVersion = try! InstallerVersion("0.1.0")\n', encoding="utf-8"
            )
            recovered = installer_versioning.apply(root, operation_id, "increment:self-update", head, "patch", None)
            self.assertEqual(recovered["target_version"], "0.1.1")
            self.assertIn('InstallerVersion("0.1.1")', projection.read_text(encoding="utf-8"))

    def test_stale_or_conflicting_preparation_fails_closed(self) -> None:
        temporary, root, head = self.repo()
        with temporary:
            with self.assertRaisesRegex(RuntimeError, "stale source head"):
                installer_versioning.apply(root, "installer-version-0002", "increment:self-update", "0" * 40, "patch", None)
            installer_versioning.apply(root, "installer-version-0002", "increment:self-update", head, "patch", None)
            with self.assertRaisesRegex(RuntimeError, "operation ID conflict"):
                installer_versioning.apply(root, "installer-version-0002", "increment:self-update", head, "minor", None)

    def test_qualification_binds_exact_changed_projection_set(self) -> None:
        temporary, root, head = self.repo()
        with temporary:
            installer_versioning.apply(root, "installer-version-0003", "increment:self-update", head, "patch", None)
            candidate = self.commit(root, "prepare installer version")
            installer_versioning.verify_operation(root, candidate)

            (root / "unrelated.txt").write_text("outside version preparation\n", encoding="utf-8")
            with self.assertRaisesRegex(RuntimeError, "candidate parent"):
                installer_versioning.verify_operation(root, self.commit(root, "unrelated"))

    def test_no_bump_receipt_has_no_phantom_projection_changes(self) -> None:
        temporary, root, head = self.repo()
        with temporary:
            installer_versioning.apply(root, "installer-version-0004", "increment:documentation", head, "none", None)
            candidate = self.commit(root, "record no-bump installer decision")
            installer_versioning.verify_operation(root, candidate)


if __name__ == "__main__":
    unittest.main()
