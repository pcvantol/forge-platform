#!/usr/bin/env python3
"""Cross-language contract checks for bundled installer provenance V1."""

from __future__ import annotations

import json
from pathlib import Path
import sys
import unittest


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from forge_platform.installer_release_provenance import (  # noqa: E402
    canonical_release_provenance_sha256,
    parse_installer_release_provenance_bytes,
)


class InstallerReleaseProvenanceTests(unittest.TestCase):
    def test_matches_the_explicit_native_v1_canonical_vector(self) -> None:
        payload = self._payload()
        self.assertEqual(
            payload["provenance_sha256"],
            "729e5463b3be32799a97ab13109f38552b46cf8c56c17ce8595e58bc5d585159",
        )
        parsed = parse_installer_release_provenance_bytes(
            json.dumps(payload, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")
        )
        self.assertEqual(parsed.provenance_sha256, payload["provenance_sha256"])
        self.assertEqual(parsed.release_sequence, 42)
        self.assertEqual(parsed.capabilities, ("composition/v1", "provider-gate/v1"))

    def test_rejects_an_unsorted_capability_list_even_with_recomputed_digest(self) -> None:
        capabilities = ("provider-gate/v1", "composition/v1")
        payload = self._payload(capabilities=capabilities)
        with self.assertRaisesRegex(ValueError, "capabilities must be sorted, unique, and valid"):
            parse_installer_release_provenance_bytes(
                json.dumps(payload, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")
            )

    @staticmethod
    def _payload(
        *,
        capabilities: tuple[str, ...] = ("composition/v1", "provider-gate/v1"),
    ) -> dict[str, object]:
        values = {
            "installer_version": "1.2.3",
            "channel": "candidate",
            "release_sequence": 42,
            "source_revision": "0123456789abcdef0123456789abcdef01234567",
            "policy_revision": "forge-platform-installer-release-v1",
            "release_trust_configuration_sha256": (
                "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"
            ),
            "capabilities": capabilities,
        }
        return {
            "schema_version": 1,
            "provenance_sha256": canonical_release_provenance_sha256(**values),
            **values,
        }


if __name__ == "__main__":
    unittest.main()
