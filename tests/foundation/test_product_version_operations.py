#!/usr/bin/env python3
"""Regression checks for product-local version preparation."""
from __future__ import annotations
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("versioning", ROOT / "scripts/advance_product_version.py")
assert SPEC and SPEC.loader
versioning = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(versioning)

class OperationsTests(unittest.TestCase):
    def repo(self):
        temporary = tempfile.TemporaryDirectory(); root = Path(temporary.name)
        (root / "product-version.json").write_text('{"product":"forge-platform","schema_version":1,"version":"2.3.0"}\n')
        subprocess.run(["git", "init", "-q", str(root)], check=True)
        subprocess.run(["git", "-C", str(root), "add", "."], check=True)
        subprocess.run(["git", "-C", str(root), "-c", "user.name=t", "-c", "user.email=t@x", "commit", "-qm", "base"], check=True)
        return temporary, root, versioning._head(root)
    def test_plan_read_only_and_retry_idempotent(self):
        temporary, root, head = self.repo()
        with temporary:
            self.assertEqual(versioning.plan(root, "operation-0001", "feature@a", head, "patch", None)["target_version"], "2.3.1")
            self.assertFalse((root / versioning.OPERATIONS_DIRECTORY).exists())
            versioning.apply(root, "operation-0001", "feature@a", head, "patch", None)
            self.assertEqual(versioning.apply(root, "operation-0001", "feature@a", head, "patch", None)["target_version"], "2.3.1")
    def test_conflict_and_stale_head_fail_closed(self):
        temporary, root, head = self.repo()
        with temporary:
            with self.assertRaisesRegex(RuntimeError, "stale source head"):
                versioning.apply(root, "operation-0002", "feature@a", "stale", "patch", None)
            versioning.apply(root, "operation-0002", "feature@a", head, "patch", None)
            with self.assertRaisesRegex(RuntimeError, "operation ID conflict"):
                versioning.apply(root, "operation-0002", "feature@b", head, "patch", None)
    def test_exact_release_and_invalid_manifest(self):
        temporary, root, head = self.repo()
        with temporary:
            self.assertEqual(versioning.apply(root, "operation-0003", "release", head, None, "2.4.0")["target_version"], "2.4.0")
            (root / "product-version.json").write_text('{"product":"forge-platform","schema_version":true,"version":"02.4.0"}')
            with self.assertRaises(RuntimeError): versioning.current(root)
    def test_qualification_binds_the_exact_preparation_commit(self):
        temporary, root, head = self.repo()
        with temporary:
            versioning.apply(root, "operation-0004", "feature@a", head, "patch", None)
            subprocess.run(["git", "-C", str(root), "add", "."], check=True)
            subprocess.run(["git", "-C", str(root), "-c", "user.name=t", "-c", "user.email=t@x", "commit", "-qm", "prepare"], check=True)
            candidate = versioning._head(root)
            versioning.verify_operation(root, candidate)
            (root / "unrelated.txt").write_text("not a preparation candidate")
            subprocess.run(["git", "-C", str(root), "add", "."], check=True)
            subprocess.run(["git", "-C", str(root), "-c", "user.name=t", "-c", "user.email=t@x", "commit", "-qm", "extra"], check=True)
            with self.assertRaisesRegex(RuntimeError, "candidate parent"):
                versioning.verify_operation(root, versioning._head(root))

if __name__ == "__main__": unittest.main()
