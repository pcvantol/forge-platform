#!/usr/bin/env python3
"""Offline checks for the repository foundation; no installer behavior is tested."""

from __future__ import annotations

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]

REQUIRED = (
    "README.md",
    "SECURITY.md",
    ".github/workflows/foundation-validation.yml",
    "docs/architecture/README.md",
    "docs/architecture/COMPONENT_MANIFEST_CONTRACT.md",
    "docs/architecture/COMPATIBILITY.md",
    "docs/architecture/ROLES_AND_PRESETS.md",
    "docs/roadmap/README.md",
    "docs/development/AI_DEVELOPMENT_PROFILE_STATUS.md",
    "docs/development/FORGE_PLATFORM_DEVELOPMENT_EXTENSION.md",
    "docs/development/TDE_INTEGRATION.md",
    "docs/governance/FAMILY_MIGRATION_HANDOFF.md",
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
    print("Foundation validation: PASS")


if __name__ == "__main__":
    main()
