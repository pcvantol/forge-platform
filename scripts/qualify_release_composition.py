#!/usr/bin/env python3
"""Fail-closed qualification for a Forge Platform release composition."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import sys

SHA256 = re.compile(r"^sha256:[0-9a-f]{64}$")
REVISION = re.compile(r"^[0-9a-f]{40,64}$")
IDENTITIES = {
    "forge-runtime", "workspace-server", "workspace-client",
    "engineering-platform-server", "engineering-platform-project-agent",
}


def pairs(values: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in values:
        if key in result:
            raise ValueError(f"duplicate key: {key}")
        result[key] = value
    return result


def fail(message: str) -> None:
    raise ValueError(message)


def qualify(path: Path, version: str, source_sha: str) -> str:
    if not path.is_file() or path.is_symlink():
        fail("composition manifest must be a regular committed file")
    if REVISION.fullmatch(source_sha) is None:
        fail("release source SHA must be an immutable Git revision")
    try:
        payload = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=pairs)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        raise ValueError("composition manifest is not valid unique-key JSON") from error
    if not isinstance(payload, dict) or set(payload) != {"forge_platform_version", "components"}:
        fail("composition manifest has unsupported fields")
    if payload["forge_platform_version"] != version:
        fail("composition manifest version does not match the canonical product version")
    components = payload["components"]
    if not isinstance(components, list) or not components:
        fail("composition manifest requires at least one component")
    seen: set[str] = set()
    for component in components:
        if not isinstance(component, dict):
            fail("component must be an object")
        required = {"identity", "version", "source_revision", "artifact", "platforms", "protocol_compatibility", "dependencies"}
        if not required.issubset(component) or set(component) - required - {"version_operation_id", "supported_contract_versions"}:
            fail("component fields are incomplete or unsupported")
        identity = component["identity"]
        if identity not in IDENTITIES or identity in seen:
            fail("component identity must be known and unique")
        seen.add(identity)
        if not isinstance(component["version"], str) or not component["version"]:
            fail("component version is required")
        if not isinstance(component["source_revision"], str) or REVISION.fullmatch(component["source_revision"]) is None:
            fail("component source revision must be immutable")
        artifact = component["artifact"]
        if not isinstance(artifact, dict) or set(artifact) - {"name", "source", "digest", "signature", "provenance", "qualification"}:
            fail("artifact fields are unsupported")
        if not {"source", "digest", "qualification"}.issubset(artifact):
            fail("artifact source, digest and qualification are required")
        if not all(isinstance(artifact[key], str) and artifact[key] for key in ("source", "qualification")) or not isinstance(artifact["digest"], str) or SHA256.fullmatch(artifact["digest"]) is None:
            fail("artifact evidence must use a source, qualification and sha256 digest")
        platforms = component["platforms"]
        if not isinstance(platforms, list) or not platforms or any(not isinstance(item, dict) or set(item) != {"os", "architecture"} or not all(isinstance(item[key], str) and item[key] for key in item) for item in platforms):
            fail("component platforms are incomplete")
        dependencies = component["dependencies"]
        if not isinstance(dependencies, dict) or set(dependencies) != {"required", "optional"} or any(not isinstance(dependencies[key], list) or any(not isinstance(value, str) for value in dependencies[key]) for key in dependencies):
            fail("component dependencies are incomplete")
    return "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--source-sha", required=True)
    args = parser.parse_args()
    try:
        digest = qualify(Path(args.manifest), args.version, args.source_sha)
    except ValueError as error:
        print(f"COMPOSITION_QUALIFICATION=FAIL {error}", file=sys.stderr)
        raise SystemExit(1)
    print(f"COMPOSITION_QUALIFICATION=PASS manifest_digest={digest}")


if __name__ == "__main__":
    main()
