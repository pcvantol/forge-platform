#!/usr/bin/env python3
"""Behavioral checks for published component-combination catalog selection."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from hashlib import sha256
import json
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from forge_platform.composition_catalog import (  # noqa: E402
    AcceptedComponentCombinationCatalogIdentity,
    CATALOG_COMPONENT_SELECTION_CAPABILITY,
    COMPONENT_COMBINATION_CATALOG_SCHEMA,
    CatalogInstallerContext,
    CatalogPublicationBinding,
    ComponentCombinationCatalog,
    ComponentCombinationRequest,
    MAXIMUM_COMPONENT_COMBINATION_CATALOG_BYTES,
    MAXIMUM_COMPONENT_COMBINATION_CATALOG_JSON_NESTING_DEPTH,
    MAXIMUM_COMPONENT_COMBINATION_CATALOG_JSON_NODES,
    MAXIMUM_COMPONENT_COMBINATION_CATALOG_UINT64,
    select_component_combination,
)
from forge_platform.universal_installer import (  # noqa: E402
    AcceptedCatalogIdentity,
    CatalogAcceptanceScope,
    COMPOSITION_CATALOG_SCHEMA,
    CompositionCatalog,
    DownloadIdentity,
    InstallerCapabilitySet,
    PublicSignatureEnvelope,
    SemanticVersion,
    SignatureThresholdPolicy,
    UniversalInstallerError,
    canonical_rfc3339_utc_timestamp,
)


NOW = datetime(2026, 9, 9, 12, 0, tzinfo=timezone.utc)
CATALOG_URL = "https://catalog.example.invalid/forge-platform/stable/component-combinations.json"
OUTER_CATALOG_FEED_URL = "https://catalog.example.invalid/forge-platform/stable/composition-catalog.json"
OUTER_CATALOG_SCOPE = CatalogAcceptanceScope(
    "a" * 64,
    "stable",
    OUTER_CATALOG_FEED_URL,
)
CORE_CAPABILITIES = frozenset({
    CATALOG_COMPONENT_SELECTION_CAPABILITY,
    "component-provisioner/forge-runtime/v1",
    "component-provisioner/engineering-platform-server/v1",
})
EXECUTION_AGENT_CAPABILITY = "component-provisioner/engineering-platform-execution-agent/v1"
OUTER_CATALOG_SIGNATURE_ENVELOPE = {
    "algorithm": "ed25519",
    "key_id": "component-catalog-fixture-key",
    "signature": "A" * 86,
}
OUTER_CATALOG_SIGNATURE = PublicSignatureEnvelope.from_mapping(OUTER_CATALOG_SIGNATURE_ENVELOPE)
OUTER_CATALOG_SIGNATURE_POLICY = SignatureThresholdPolicy(
    algorithm="ed25519",
    trusted_key_ids=frozenset({"component-catalog-fixture-key"}),
    threshold=1,
)


class OuterCatalogFixtureVerifier:
    def verify(
        self,
        canonical_payload: bytes,
        signatures: tuple[PublicSignatureEnvelope, ...],
        *,
        policy: SignatureThresholdPolicy,
    ) -> bool:
        del canonical_payload
        return policy == OUTER_CATALOG_SIGNATURE_POLICY and signatures == (OUTER_CATALOG_SIGNATURE,)


def component(identity: str, *capabilities: str) -> dict[str, object]:
    return {
        "identity": identity,
        "requires_capabilities": list(capabilities),
    }


def entry(
    composition_id: str,
    selection_sequence: int,
    components: list[dict[str, object]],
    *,
    minimum_version: str = "1.0.0",
    extra_capabilities: tuple[str, ...] = (),
    upgrade_from: tuple[str, ...] = (),
) -> dict[str, object]:
    component_capabilities = {
        capability
        for selected in components
        for capability in selected["requires_capabilities"]  # type: ignore[index]
    }
    capabilities = sorted({CATALOG_COMPONENT_SELECTION_CAPABILITY, *component_capabilities, *extra_capabilities})
    return {
        "composition_id": composition_id,
        "selection_sequence": selection_sequence,
        "channel": "stable",
        "manifest": {
            "url": f"https://manifest.example.invalid/{composition_id}.json",
            "digest": "sha256:" + (str(selection_sequence % 10) * 64),
        },
        "components": components,
        "requires_installer": {
            "minimum_version": minimum_version,
            "capabilities": capabilities,
        },
        "upgrade_from": list(upgrade_from),
    }


def catalog_raw(
    entries: list[dict[str, object]],
    *,
    sequence: int = 4,
    published_at: str = "2026-09-01T00:00:00Z",
    expires_at: datetime | str | None = None,
) -> bytes:
    expiration = expires_at or (NOW + timedelta(days=30))
    expiration_value = (
        expiration.isoformat().replace("+00:00", "Z")
        if isinstance(expiration, datetime)
        else expiration
    )
    payload = {
        "schema": COMPONENT_COMBINATION_CATALOG_SCHEMA,
        "sequence": sequence,
        "channel": "stable",
        "published_at": published_at,
        "expires_at": expiration_value,
        "compositions": entries,
    }
    return json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")


def catalog(
    entries: list[dict[str, object]],
    *,
    sequence: int = 4,
    published_at: str = "2026-09-01T00:00:00Z",
    expires_at: datetime | str | None = None,
    outer_published_at: str = "2026-09-01T00:00:00Z",
    outer_expires_at: str = "2026-10-01T00:00:00Z",
) -> ComponentCombinationCatalog:
    raw = catalog_raw(
        entries,
        sequence=sequence,
        published_at=published_at,
        expires_at=expires_at,
    )
    outer = verified_outer_catalog(
        raw,
        published_at=outer_published_at,
        expires_at=outer_expires_at,
    )
    return ComponentCombinationCatalog.from_verified_composition_catalog_bytes(
        outer,
        raw,
        outer_catalog_acceptance=outer_catalog_acceptance(outer),
    )


def verified_outer_catalog(
    index_raw: bytes,
    *,
    index_digest: str | None = None,
    published_at: str = "2026-09-01T00:00:00Z",
    expires_at: str = "2026-10-01T00:00:00Z",
) -> CompositionCatalog:
    payload = {
        "schema": COMPOSITION_CATALOG_SCHEMA,
        "sequence": 7,
        "channel": "stable",
        "published_at": published_at,
        "expires_at": expires_at,
        "approved_python_runtime_identity": "sha256:" + "c" * 64,
        "compositions": [{
            "composition_id": "outer-catalog-fixture",
            "channel": "stable",
            "url": "https://manifest.example.invalid/outer-catalog-fixture.json",
            "digest": "sha256:" + "f" * 64,
            "requires_installer": {
                "minimum_version": "1.0.0",
                "capabilities": ["composition/v1"],
            },
        }],
        "component_combination_catalog": {
            "url": CATALOG_URL,
            "digest": index_digest or ("sha256:" + sha256(index_raw).hexdigest()),
        },
        "signatures": [dict(OUTER_CATALOG_SIGNATURE_ENVELOPE)],
    }
    raw = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return CompositionCatalog.from_signed_bytes(
        raw,
        OuterCatalogFixtureVerifier(),
        signature_policy=OUTER_CATALOG_SIGNATURE_POLICY,
    )


def outer_catalog_acceptance(catalog: CompositionCatalog) -> AcceptedCatalogIdentity:
    return AcceptedCatalogIdentity(
        OUTER_CATALOG_SCOPE,
        catalog.sequence,
        catalog.catalog_digest,
    )


def installer(*, version: str = "1.1.0", capabilities: frozenset[str] = CORE_CAPABILITIES) -> CatalogInstallerContext:
    return CatalogInstallerContext(
        OUTER_CATALOG_SCOPE,
        InstallerCapabilitySet(SemanticVersion.parse(version), capabilities),
    )


FORGE_EP_COMPONENTS = [
    component("forge-runtime", "component-provisioner/forge-runtime/v1"),
    component(
        "engineering-platform-server",
        "component-provisioner/engineering-platform-server/v1",
    ),
]


class ComponentCombinationCatalogTests(unittest.TestCase):
    def test_index_can_be_fetched_only_through_a_verified_signed_outer_catalog(self) -> None:
        raw_index = catalog_raw([entry("forge-ep-stable-001", 1, FORGE_EP_COMPONENTS)])
        outer_catalog = verified_outer_catalog(raw_index)
        acceptance = outer_catalog_acceptance(outer_catalog)

        parsed = ComponentCombinationCatalog.from_verified_composition_catalog_bytes(
            outer_catalog,
            raw_index,
            outer_catalog_acceptance=acceptance,
        )
        self.assertEqual(parsed.sequence, 4)
        self.assertEqual(parsed.catalog_digest, "sha256:" + sha256(raw_index).hexdigest())
        with self.assertRaisesRegex(UniversalInstallerError, "do not match the trusted catalog digest"):
            ComponentCombinationCatalog.from_verified_composition_catalog_bytes(
                outer_catalog,
                raw_index + b" ",
                outer_catalog_acceptance=acceptance,
            )
        with self.assertRaisesRegex(ValueError, "verified CompositionCatalog"):
            ComponentCombinationCatalog.from_verified_composition_catalog_bytes(
                object(),
                raw_index,
                outer_catalog_acceptance=acceptance,
            )

    def test_selects_newest_exact_compatible_combination_without_a_new_installer_bundle(self) -> None:
        parsed = catalog([
            entry("forge-ep-stable-001", 1, FORGE_EP_COMPONENTS),
            entry("forge-ep-stable-002", 2, FORGE_EP_COMPONENTS, upgrade_from=("forge-ep-stable-001",)),
        ])

        selection = select_component_combination(
            parsed,
            installer(),
            ComponentCombinationRequest(frozenset({"forge-runtime", "engineering-platform-server"})),
            now=NOW,
        )

        self.assertEqual(selection.state, "SELECTED")
        self.assertTrue(selection.permits_composition_fetch)
        self.assertEqual(selection.entry.composition_id, "forge-ep-stable-002")  # type: ignore[union-attr]
        self.assertEqual(selection.catalog_identity.sequence, 4)

    def test_future_execution_agent_requires_installer_capability_before_selection(self) -> None:
        execution_agent_components = [
            *FORGE_EP_COMPONENTS,
            component(
                "engineering-platform-execution-agent",
                EXECUTION_AGENT_CAPABILITY,
            ),
        ]
        parsed = catalog([
            entry(
                "forge-ep-execution-agent-001",
                3,
                execution_agent_components,
                minimum_version="1.2.0",
            ),
        ])
        request = ComponentCombinationRequest(frozenset({
            "forge-runtime",
            "engineering-platform-server",
            "engineering-platform-execution-agent",
        }))

        old_installer = select_component_combination(parsed, installer(), request, now=NOW)
        self.assertEqual(old_installer.state, "INSTALLER_UPDATE_REQUIRED")
        self.assertFalse(old_installer.permits_composition_fetch)
        self.assertIn("installer version 1.2.0 or newer", old_installer.unmet_installer_requirements)
        self.assertIn(
            f"installer capability {EXECUTION_AGENT_CAPABILITY}",
            old_installer.unmet_installer_requirements,
        )

        newer_installer = select_component_combination(
            parsed,
            installer(
                version="1.2.0",
                capabilities=frozenset({*CORE_CAPABILITIES, EXECUTION_AGENT_CAPABILITY}),
            ),
            request,
            now=NOW,
        )
        self.assertEqual(newer_installer.state, "SELECTED")
        self.assertEqual(newer_installer.entry.composition_id, "forge-ep-execution-agent-001")  # type: ignore[union-attr]

    def test_never_selects_a_component_superset_or_an_unpublished_upgrade_route(self) -> None:
        parsed = catalog([
            entry("forge-ep-stable-002", 2, FORGE_EP_COMPONENTS, upgrade_from=("forge-ep-stable-001",)),
        ])
        subset = select_component_combination(
            parsed,
            installer(),
            ComponentCombinationRequest(frozenset({"engineering-platform-server"})),
            now=NOW,
        )
        self.assertEqual(subset.state, "UNAVAILABLE")
        self.assertIn("exactly", subset.reason)

        unapproved_route = select_component_combination(
            parsed,
            installer(),
            ComponentCombinationRequest(
                frozenset({"forge-runtime", "engineering-platform-server"}),
                installed_composition_id="other-composition",
            ),
            now=NOW,
        )
        self.assertEqual(unapproved_route.state, "UPGRADE_ROUTE_BLOCKED")
        self.assertFalse(unapproved_route.permits_composition_fetch)

    def test_index_entries_and_installed_identity_use_the_catalog_composition_grammar(self) -> None:
        for invalid in (
            "forge ep stable 001",
            "forge\u0085ep-stable-001",
            "forge\u00A0ep-stable-001",
            "forge\u0001ep-stable-001",
            "forge\ud800ep-stable-001",
            "x" * 257,
        ):
            with self.subTest(invalid=invalid):
                with self.assertRaisesRegex(ValueError, "bounded whitespace-free identity"):
                    catalog([entry(invalid, 1, FORGE_EP_COMPONENTS)])

        with self.assertRaisesRegex(ValueError, "bounded whitespace-free identity"):
            catalog([
                entry(
                    "forge-ep-stable-002",
                    2,
                    FORGE_EP_COMPONENTS,
                    upgrade_from=("forge\u0085ep-stable-001",),
                ),
            ])
        with self.assertRaisesRegex(ValueError, "bounded whitespace-free identity"):
            ComponentCombinationRequest(
                frozenset({"forge-runtime", "engineering-platform-server"}),
                installed_composition_id="forge\u0085ep-stable-001",
        )

        zero_width_identity = "forge\uFEFFep-stable-001"
        zero_width_entry = entry(zero_width_identity, 1, FORGE_EP_COMPONENTS)
        zero_width_entry["manifest"]["url"] = "https://manifest.example.invalid/zero-width-identity.json"  # type: ignore[index]
        parsed = catalog([zero_width_entry])
        selection = select_component_combination(
            parsed,
            installer(),
            ComponentCombinationRequest(frozenset({"forge-runtime", "engineering-platform-server"})),
            now=NOW,
        )
        self.assertEqual(selection.entry.composition_id, zero_width_identity)  # type: ignore[union-attr]

    def test_higher_unknown_capability_is_not_silently_bypassed_for_an_older_combination(self) -> None:
        parsed = catalog([
            entry("forge-ep-stable-001", 1, FORGE_EP_COMPONENTS),
            entry(
                "forge-ep-stable-002",
                2,
                FORGE_EP_COMPONENTS,
                extra_capabilities=("component-ui/advanced-migration/v1",),
                upgrade_from=("forge-ep-stable-001",),
            ),
        ])
        selection = select_component_combination(
            parsed,
            installer(),
            ComponentCombinationRequest(frozenset({"forge-runtime", "engineering-platform-server"})),
            now=NOW,
        )

        self.assertEqual(selection.state, "INSTALLER_UPDATE_REQUIRED")
        self.assertEqual(selection.entry.composition_id, "forge-ep-stable-002")  # type: ignore[union-attr]
        self.assertIn(
            "installer capability component-ui/advanced-migration/v1",
            selection.unmet_installer_requirements,
        )

    def test_catalog_requires_exact_trusted_bytes_and_rejects_replayed_or_conflicting_sequence(self) -> None:
        entries = [entry("forge-ep-stable-001", 1, FORGE_EP_COMPONENTS)]
        raw = catalog_raw(entries, sequence=4)
        wrong_digest_outer = verified_outer_catalog(raw, index_digest="sha256:" + "0" * 64)
        with self.assertRaisesRegex(UniversalInstallerError, "do not match the trusted catalog digest"):
            ComponentCombinationCatalog.from_verified_composition_catalog_bytes(
                wrong_digest_outer,
                raw,
                outer_catalog_acceptance=outer_catalog_acceptance(wrong_digest_outer),
            )
        with self.assertRaisesRegex(TypeError, "derived from a verified CompositionCatalog"):
            CatalogPublicationBinding(
                AcceptedCatalogIdentity(OUTER_CATALOG_SCOPE, 1, "sha256:" + "0" * 64),
                DownloadIdentity(CATALOG_URL, "sha256:" + "0" * 64),
                NOW,
                NOW + timedelta(days=1),
            )

        accepted = catalog(entries, sequence=4)
        accepted_identity = AcceptedComponentCombinationCatalogIdentity(
            OUTER_CATALOG_SCOPE, accepted.sequence, accepted.catalog_digest,
        )
        replayed = catalog(entries, sequence=3)
        with self.assertRaisesRegex(UniversalInstallerError, "regresses accepted"):
            select_component_combination(
                replayed,
                installer(),
                ComponentCombinationRequest(frozenset({"forge-runtime", "engineering-platform-server"})),
                now=NOW,
                accepted_catalog=accepted_identity,
            )

        conflicting = catalog([
            entry("forge-ep-stable-001", 1, FORGE_EP_COMPONENTS, minimum_version="1.1.0"),
        ], sequence=4)
        with self.assertRaisesRegex(UniversalInstallerError, "conflicting immutable bytes"):
            select_component_combination(
                conflicting,
                installer(),
                ComponentCombinationRequest(frozenset({"forge-runtime", "engineering-platform-server"})),
                now=NOW,
                accepted_catalog=accepted_identity,
            )

    def test_catalog_rejects_component_capabilities_that_are_not_bound_by_its_installer_requirement(self) -> None:
        invalid = entry("forge-ep-stable-001", 1, FORGE_EP_COMPONENTS)
        invalid["requires_installer"] = {
            "minimum_version": "1.0.0",
            "capabilities": [CATALOG_COMPONENT_SELECTION_CAPABILITY],
        }
        raw = catalog_raw([invalid])
        outer = verified_outer_catalog(raw)
        with self.assertRaisesRegex(ValueError, "component capabilities"):
            ComponentCombinationCatalog.from_verified_composition_catalog_bytes(
                outer,
                raw,
                outer_catalog_acceptance=outer_catalog_acceptance(outer),
            )

    def test_expired_catalog_cannot_be_selected(self) -> None:
        parsed = catalog(
            [entry("forge-ep-stable-001", 1, FORGE_EP_COMPONENTS)],
            expires_at=NOW - timedelta(seconds=1),
        )
        with self.assertRaisesRegex(UniversalInstallerError, "not currently valid"):
            select_component_combination(
                parsed,
                installer(),
                ComponentCombinationRequest(frozenset({"forge-runtime", "engineering-platform-server"})),
                now=NOW,
            )

    def test_outer_catalog_freshness_is_retained_and_rechecked(self) -> None:
        request = ComponentCombinationRequest(
            frozenset({"forge-runtime", "engineering-platform-server"})
        )
        expired_outer = catalog(
            [entry("forge-ep-stable-001", 1, FORGE_EP_COMPONENTS)],
            outer_expires_at="2026-09-09T11:59:59Z",
        )
        with self.assertRaisesRegex(UniversalInstallerError, "not currently valid"):
            select_component_combination(expired_outer, installer(), request, now=NOW)

        not_yet_published_outer = catalog(
            [entry("forge-ep-stable-001", 1, FORGE_EP_COMPONENTS)],
            outer_published_at="2026-09-09T12:00:01Z",
        )
        with self.assertRaisesRegex(UniversalInstallerError, "not currently valid"):
            select_component_combination(not_yet_published_outer, installer(), request, now=NOW)

    def test_component_index_anchor_cannot_cross_trust_or_feed_scope(self) -> None:
        parsed = catalog([entry("forge-ep-stable-001", 1, FORGE_EP_COMPONENTS)])
        request = ComponentCombinationRequest(
            frozenset({"forge-runtime", "engineering-platform-server"})
        )
        rotated_scopes = (
            CatalogAcceptanceScope("b" * 64, "stable", OUTER_CATALOG_FEED_URL),
            CatalogAcceptanceScope(
                "a" * 64,
                "stable",
                "https://catalog.example.invalid/forge-platform/stable/composition-catalog-v2.json",
            ),
        )
        for rotated_scope in rotated_scopes:
            with self.subTest(scope=rotated_scope):
                with self.assertRaisesRegex(UniversalInstallerError, "scope does not match"):
                    select_component_combination(
                        parsed,
                        CatalogInstallerContext(rotated_scope, installer().capabilities),
                        request,
                        now=NOW,
                    )
                with self.assertRaisesRegex(UniversalInstallerError, "anchor scope does not match"):
                    select_component_combination(
                        parsed,
                        installer(),
                        request,
                        now=NOW,
                        accepted_catalog=AcceptedComponentCombinationCatalogIdentity(
                            rotated_scope,
                            parsed.sequence,
                            parsed.catalog_digest,
                        ),
                    )

    def test_index_sequences_match_the_native_uint64_boundary(self) -> None:
        maximum = MAXIMUM_COMPONENT_COMBINATION_CATALOG_UINT64
        schema_expectations = (
            ("schemas/universal-installer-release.schema.json", ("properties", "sequence")),
            ("schemas/universal-installer-composition-catalog.schema.json", ("properties", "sequence")),
            ("schemas/universal-installer-component-combination-catalog.schema.json", ("properties", "sequence")),
            (
                "schemas/universal-installer-component-combination-catalog.schema.json",
                ("$defs", "composition", "properties", "selection_sequence"),
            ),
        )
        for relative_path, keys in schema_expectations:
            value: object = json.loads((ROOT / relative_path).read_text(encoding="utf-8"))
            for key in keys:
                value = value[key]  # type: ignore[index]
            self.assertEqual(value["maximum"], maximum)  # type: ignore[index]
        accepted = catalog(
            [entry("forge-ep-stable-maximum", maximum, FORGE_EP_COMPONENTS)],
            sequence=maximum,
        )
        self.assertEqual(accepted.sequence, maximum)
        self.assertEqual(accepted.entries[0].selection_sequence, maximum)

        overflow_catalog = catalog_raw(
            [entry("forge-ep-stable-001", 1, FORGE_EP_COMPONENTS)],
            sequence=maximum + 1,
        )
        overflow_entry = catalog_raw(
            [entry("forge-ep-stable-001", maximum + 1, FORGE_EP_COMPONENTS)],
        )
        for raw in (overflow_catalog, overflow_entry):
            outer = verified_outer_catalog(raw)
            with self.subTest(raw=raw):
                with self.assertRaisesRegex(ValueError, "positive UInt64"):
                    ComponentCombinationCatalog.from_verified_composition_catalog_bytes(
                        outer,
                        raw,
                        outer_catalog_acceptance=outer_catalog_acceptance(outer),
                    )
        with self.assertRaisesRegex(ValueError, "positive UInt64"):
            AcceptedComponentCombinationCatalogIdentity(
                OUTER_CATALOG_SCOPE,
                maximum + 1,
                "sha256:" + "0" * 64,
            )

    def test_canonical_rfc3339_timestamp_profile_matches_the_native_selector(self) -> None:
        accepted = (
            "2026-09-10T12:00:00Z",
            "2024-02-29T23:59:59Z",
            "0001-01-01T00:00:00Z",
            "9999-12-31T23:59:59Z",
        )
        rejected = (
            "2026-09-10t12:00:00Z",
            "2026-09-10T12:00:00z",
            "2026-09-10 12:00:00Z",
            "2026-09-10🐍12:00:00Z",
            "2026-09-10T12:00:00+00:00",
            "2026-09-10T12:00:00+0000",
            "2026-09-10T12:00:00+00",
            "2026-09-10T12:00:00Z ",
            "2026-09-10T12:00:00.1Z",
            "2026-09-10T12:00:00,1Z",
            "2026-02-29T12:00:00Z",
            "2026-04-31T12:00:00Z",
            "2026-09-10T24:00:00Z",
            "2026-09-10T12:00:60Z",
            "0000-01-01T00:00:00Z",
        )
        for value in accepted:
            with self.subTest(accepted=value):
                self.assertEqual(canonical_rfc3339_utc_timestamp(value, "timestamp").tzinfo, timezone.utc)
        for value in rejected:
            with self.subTest(rejected=value):
                with self.assertRaisesRegex(ValueError, "canonical RFC3339 UTC"):
                    canonical_rfc3339_utc_timestamp(value, "timestamp")

        raw = catalog_raw(
            [entry("forge-ep-stable-001", 1, FORGE_EP_COMPONENTS)],
            published_at="2026-09-01 00:00:00Z",
        )
        outer = verified_outer_catalog(raw)
        with self.assertRaisesRegex(ValueError, "canonical RFC3339 UTC"):
            ComponentCombinationCatalog.from_verified_composition_catalog_bytes(
                outer,
                raw,
                outer_catalog_acceptance=outer_catalog_acceptance(outer),
            )

    def test_index_parser_matches_native_byte_depth_and_node_limits(self) -> None:
        oversized = b" " * (MAXIMUM_COMPONENT_COMBINATION_CATALOG_BYTES + 1)
        deep = (
            b'{"nested":'
            + b"[" * MAXIMUM_COMPONENT_COMBINATION_CATALOG_JSON_NESTING_DEPTH
            + b"0"
            + b"]" * MAXIMUM_COMPONENT_COMBINATION_CATALOG_JSON_NESTING_DEPTH
            + b"}"
        )
        many_nodes = json.dumps(
            {
                "schema": COMPONENT_COMBINATION_CATALOG_SCHEMA,
                "sequence": 4,
                "channel": "stable",
                "published_at": "2026-09-01T00:00:00Z",
                "expires_at": "2026-10-01T00:00:00Z",
                "compositions": [0]
                * MAXIMUM_COMPONENT_COMBINATION_CATALOG_JSON_NODES,
            },
            separators=(",", ":"),
        ).encode("utf-8")
        for raw in (oversized, deep, many_nodes):
            outer = verified_outer_catalog(raw)
            with self.subTest(size=len(raw)):
                with self.assertRaisesRegex(UniversalInstallerError, "native admission|native JSON"):
                    ComponentCombinationCatalog.from_verified_composition_catalog_bytes(
                        outer,
                        raw,
                        outer_catalog_acceptance=outer_catalog_acceptance(outer),
                    )


if __name__ == "__main__":
    unittest.main()
