#!/usr/bin/env python3
"""Offline checks for the repository foundation; no installer behavior is tested."""

from __future__ import annotations

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]

REQUIRED = (
    "README.md",
    "BOOTSTRAP.md",
    "HANDOFF.md",
    "SECURITY.md",
    ".github/workflows/foundation-validation.yml",
    "docs/architecture/README.md",
    "docs/architecture/FORGE_PLATFORM_ARCHITECTURE.md",
    "docs/architecture/OWNERSHIP_MATRIX.md",
    "docs/architecture/adr/README.md",
    "docs/architecture/adr/ADR-0001-first-class-product-boundaries.md",
    "docs/architecture/adr/ADR-0002-project-repository-host-agent-model.md",
    "docs/architecture/adr/ADR-0003-deployment-and-trust-boundaries.md",
    "docs/architecture/adr/ADR-0004-universal-installer-artifact-composition.md",
    "docs/architecture/COMPONENT_MANIFEST_CONTRACT.md",
    "docs/architecture/COMPATIBILITY.md",
    "docs/architecture/ROLES_AND_PRESETS.md",
    "docs/roadmap/README.md",
    "docs/development/AI_DEVELOPMENT_PROFILE_STATUS.md",
    "docs/development/FORGE_PLATFORM_DEVELOPMENT_EXTENSION.md",
    "docs/development/TDE_INTEGRATION.md",
    "docs/ai-development/GENERATED_PROJECTION.md",
    "docs/ai-development/projection-manifest.json",
    "docs/ai-development/validate_projection.py",
    "docs/governance/FAMILY_MIGRATION_HANDOFF.md",
    "docs/governance/AI_DEVELOPMENT_CONTRACT_SEMANTIC_EQUIVALENCE_RECEIPT.md",
    "scripts/validate.sh",
    "provenance/FOUNDATION_RECEIPT.md",
    "schemas/component-manifest.schema.json",
)


def main() -> None:
    missing = [path for path in REQUIRED if not (ROOT / path).is_file()]
    if missing:
        raise SystemExit(f"missing foundation files: {', '.join(missing)}")

    schema = json.loads((ROOT / "schemas/component-manifest.schema.json").read_text())
    if schema["title"] != "Forge Platform component manifest":
        raise SystemExit("component-manifest schema identity is invalid")
    identities = schema["$defs"]["component"]["properties"]["identity"]["enum"]
    if len(identities) != 5:
        raise SystemExit("component-manifest schema must identify five installable components")

    extension = (ROOT / "docs/development/FORGE_PLATFORM_DEVELOPMENT_EXTENSION.md").read_text()
    if "generic branch" not in extension:
        raise SystemExit("local extension must preserve the generic-contract boundary")
    architecture = (ROOT / "docs/architecture/FORGE_PLATFORM_ARCHITECTURE.md").read_text()
    for required_term in (
        "Canonical Project Authority Repository",
        "Engineering Platform Project Agent",
        "at most one mutating Execution Lane per Repository at a time",
        "source checkouts develop, test, and build; published/installed artifacts run",
    ):
        if required_term not in architecture:
            raise SystemExit(f"architecture is missing canonical term: {required_term}")
    manifest = json.loads((ROOT / "docs/ai-development/projection-manifest.json").read_text())
    if manifest["profile"] != "forge-platform":
        raise SystemExit("projection profile is invalid")
    if manifest["extension_identity"] != "FORGE_PLATFORM_DEVELOPMENT_EXTENSION":
        raise SystemExit("projection extension identity is invalid")
    if len(manifest["contracts"]) != 8:
        raise SystemExit("projection must contain all eight generic contracts")
    print("Foundation validation: PASS")


if __name__ == "__main__":
    main()
