#!/usr/bin/env python3
"""Direct contract checks for the public V1 catalog-trust resource parser."""

from __future__ import annotations

import base64
import json
from pathlib import Path
import sys
import unittest


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from forge_platform.composition_catalog_trust import (  # noqa: E402
    COMPOSITION_CATALOG_TRUST_MAXIMUM_BYTES,
    canonical_composition_catalog_trust_configuration_sha256,
    parse_composition_catalog_trust_bytes,
)


INSTALLER_RELEASE_TRUST_CONFIGURATION_SHA256 = "a" * 64
PUBLIC_KEYS = (
    ("catalog-key-a", base64.b64encode(bytes(range(32))).decode("ascii")),
    ("catalog-key-b", base64.b64encode(bytes(range(32, 64))).decode("ascii")),
)
PUBLIC_DIGEST = "029134bfeafb6d804ed86c94a9845deec4881d2497e3bbcf85c6a611eaa690d7"


class CompositionCatalogTrustTests(unittest.TestCase):
    def test_parses_the_public_cross_language_canonical_vector(self) -> None:
        payload = self._payload()
        self.assertEqual(payload["configuration_sha256"], PUBLIC_DIGEST)
        trust = parse_composition_catalog_trust_bytes(self._encoded(payload))
        self.assertEqual(trust.configuration_sha256, PUBLIC_DIGEST)
        self.assertEqual(
            trust.installer_release_trust_configuration_sha256,
            INSTALLER_RELEASE_TRUST_CONFIGURATION_SHA256,
        )
        self.assertEqual(trust.signature_key_ids, ("catalog-key-a", "catalog-key-b"))
        self.assertEqual(trust.signature_threshold, 2)

    def test_rejects_noncanonical_keys_threshold_and_digest(self) -> None:
        malformed_payloads: list[tuple[str, dict[str, object], str]] = []

        malformed_payloads.append((
            "key order",
            self._payload(ed25519_public_keys=tuple(reversed(PUBLIC_KEYS))),
            "public keys must be strictly ordered",
        ))
        malformed_payloads.append((
            "duplicate key id",
            self._payload(ed25519_public_keys=(PUBLIC_KEYS[0], ("catalog-key-a", PUBLIC_KEYS[1][1]))),
            "public keys must be unique",
        ))
        malformed_payloads.append((
            "duplicate public key",
            self._payload(ed25519_public_keys=(PUBLIC_KEYS[0], ("catalog-key-b", PUBLIC_KEYS[0][1]))),
            "public keys must be unique",
        ))
        malformed_payloads.append((
            "threshold",
            self._payload(ed25519_public_keys=PUBLIC_KEYS[:1], signature_threshold=2),
            "signature threshold exceeds public keys",
        ))
        digest_mismatch = self._payload()
        digest_mismatch["configuration_sha256"] = "b" * 64
        malformed_payloads.append(("digest", digest_mismatch, "configuration digest does not match"))

        for label, payload, message in malformed_payloads:
            with self.subTest(label=label):
                with self.assertRaisesRegex(ValueError, message):
                    parse_composition_catalog_trust_bytes(self._encoded(payload))

    def test_rejects_strict_json_violations_and_resource_bounds(self) -> None:
        payload = self._payload()
        raw = self._encoded(payload)
        duplicate_top_level = raw[:-1] + b',"signature_threshold":1}'
        duplicate_nested_key = raw.replace(
            b'{"key_id":"catalog-key-a","public_key_base64":',
            b'{"key_id":"catalog-key-a","key_id":"catalog-key-z","public_key_base64":',
            1,
        )
        nonfinite = raw.replace(b'"schema_version":1', b'"schema_version":NaN', 1)

        for label, malformed in (
            ("duplicate top level", duplicate_top_level),
            ("duplicate nested", duplicate_nested_key),
            ("nonfinite", nonfinite),
        ):
            with self.subTest(label=label):
                with self.assertRaisesRegex(ValueError, "strict UTF-8 JSON"):
                    parse_composition_catalog_trust_bytes(malformed)

        with self.assertRaisesRegex(ValueError, "contents are invalid"):
            parse_composition_catalog_trust_bytes(b" " * (COMPOSITION_CATALOG_TRUST_MAXIMUM_BYTES + 1))
        with self.assertRaisesRegex(ValueError, "exceeds the native JSON nesting limit"):
            parse_composition_catalog_trust_bytes(b"[" * 65 + b"0" + b"]" * 65)

    def test_rejects_unknown_fields_and_noninteger_schema_or_threshold(self) -> None:
        unknown = self._payload()
        unknown["catalog_url"] = "https://example.invalid/catalog.json"
        with self.assertRaisesRegex(ValueError, "unsupported or missing fields"):
            parse_composition_catalog_trust_bytes(self._encoded(unknown))

        schema_boolean = self._payload()
        schema_boolean["schema_version"] = True
        with self.assertRaisesRegex(ValueError, "schema version is unsupported"):
            parse_composition_catalog_trust_bytes(self._encoded(schema_boolean))

        threshold_float = self._payload()
        threshold_float["signature_threshold"] = 1.0
        with self.assertRaisesRegex(ValueError, "signature threshold is invalid"):
            parse_composition_catalog_trust_bytes(self._encoded(threshold_float))

    @staticmethod
    def _payload(
        *,
        installer_release_trust_configuration_sha256: str = INSTALLER_RELEASE_TRUST_CONFIGURATION_SHA256,
        signature_threshold: int = 2,
        ed25519_public_keys: tuple[tuple[str, str], ...] = PUBLIC_KEYS,
    ) -> dict[str, object]:
        return {
            "schema_version": 1,
            "configuration_sha256": canonical_composition_catalog_trust_configuration_sha256(
                installer_release_trust_configuration_sha256=installer_release_trust_configuration_sha256,
                signature_threshold=signature_threshold,
                ed25519_public_keys=ed25519_public_keys,
            ),
            "installer_release_trust_configuration_sha256": installer_release_trust_configuration_sha256,
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
