import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("composition", ROOT / "scripts/qualify_release_composition.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
SHA = "a" * 40
DIGEST = "sha256:" + "b" * 64


def valid():
    return {"forge_platform_version": "2.3.0", "components": [{"identity": "forge-runtime", "version": "2.3.2", "source_revision": SHA, "artifact": {"source": "https://example.invalid/forge.whl", "digest": DIGEST, "qualification": "https://example.invalid/receipt"}, "platforms": [{"os": "macos", "architecture": "arm64"}], "protocol_compatibility": {}, "dependencies": {"required": [], "optional": []}}]}


class ReleaseCompositionQualificationTests(unittest.TestCase):
    def write(self, payload):
        directory = tempfile.TemporaryDirectory()
        path = Path(directory.name) / "composition.json"
        path.write_text(json.dumps(payload))
        self.addCleanup(directory.cleanup)
        return path

    def test_qualifies_exact_evidence_bound_composition(self):
        self.assertTrue(MODULE.qualify(self.write(valid()), "2.3.0", SHA).startswith("sha256:"))

    def test_rejects_guessed_or_incomplete_artifact_identity(self):
        payload = valid()
        payload["components"][0]["artifact"]["digest"] = "sha256:unknown"
        with self.assertRaises(ValueError):
            MODULE.qualify(self.write(payload), "2.3.0", SHA)

    def test_rejects_version_or_source_mismatch(self):
        with self.assertRaises(ValueError):
            MODULE.qualify(self.write(valid()), "2.3.1", SHA)
        with self.assertRaises(ValueError):
            MODULE.qualify(self.write(valid()), "2.3.0", "not-a-sha")
