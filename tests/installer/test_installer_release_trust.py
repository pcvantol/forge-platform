#!/usr/bin/env python3
"""Direct contract checks for the shared public V2 trust-resource parser."""

from __future__ import annotations

import base64
import json
from pathlib import Path
import sys
import unittest


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from forge_platform.installer_release_trust import (  # noqa: E402
    canonical_release_trust_configuration_sha256,
    parse_installer_release_trust_bytes,
)


PUBLIC_KEYS = (
    ("descriptor-key-a", base64.b64encode(bytes(range(32))).decode("ascii")),
    ("descriptor-key-b", base64.b64encode(bytes(range(32, 64))).decode("ascii")),
)
PUBLIC_DIGEST = "5988f1dd473caef0a2963f3a6cec06099007e740eced84e3a03fc0e04f343b19"


class InstallerReleaseTrustTests(unittest.TestCase):
    def test_parses_the_public_cross_language_canonical_vector(self) -> None:
        payload = self._payload()
        self.assertEqual(payload["configuration_sha256"], PUBLIC_DIGEST)
        trust = parse_installer_release_trust_bytes(self._encoded(payload))
        self.assertEqual(trust.configuration_sha256, PUBLIC_DIGEST)
        self.assertEqual(trust.repository, "example-owner/example-installer")
        self.assertEqual(trust.release_descriptor_asset_name, "ForgePlatformInstallerReleaseDescriptor.json")
        self.assertEqual(trust.signature_key_ids, ("descriptor-key-a", "descriptor-key-b"))
        self.assertEqual(trust.signature_threshold, 2)

    def test_rejects_noncanonical_repository_descriptor_keys_and_threshold(self) -> None:
        malformed_payloads: list[tuple[str, dict[str, object], str]] = []

        invalid_repository = self._payload()
        invalid_repository["repository"] = "-owner/example-installer"
        malformed_payloads.append(("repository", invalid_repository, "repository is invalid"))

        invalid_descriptor = self._payload()
        invalid_descriptor["release_descriptor_asset_name"] = ".descriptor.json"
        malformed_payloads.append(("descriptor", invalid_descriptor, "descriptor asset name is invalid"))

        unordered_keys = tuple(reversed(PUBLIC_KEYS))
        malformed_payloads.append((
            "key order",
            self._payload(ed25519_public_keys=unordered_keys),
            "public keys must be strictly ordered",
        ))

        malformed_payloads.append((
            "threshold",
            self._payload(ed25519_public_keys=PUBLIC_KEYS[:1], signature_threshold=2),
            "signature threshold exceeds public keys",
        ))

        for label, payload, message in malformed_payloads:
            with self.subTest(label=label):
                with self.assertRaisesRegex(ValueError, message):
                    parse_installer_release_trust_bytes(self._encoded(payload))

    def test_rejects_duplicate_json_fields_before_digest_interpretation(self) -> None:
        payload = self._payload()
        raw = self._encoded(payload)
        duplicate = raw[:-1] + b',"repository":"other/example"}'
        with self.assertRaisesRegex(ValueError, "strict UTF-8 JSON"):
            parse_installer_release_trust_bytes(duplicate)

    @staticmethod
    def _payload(
        *,
        repository: str = "example-owner/example-installer",
        release_descriptor_asset_name: str = "ForgePlatformInstallerReleaseDescriptor.json",
        expected_bundle_identifier: str = "com.example.forge-platform-installer",
        expected_team_identifier: str = "AB12CD34EF",
        signature_threshold: int = 2,
        ed25519_public_keys: tuple[tuple[str, str], ...] = PUBLIC_KEYS,
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
    def _encoded(payload: dict[str, object]) -> bytes:
        return json.dumps(payload, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")


if __name__ == "__main__":
    unittest.main()
