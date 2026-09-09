#!/usr/bin/env python3
"""Validate the separately owned Forge Platform Installer version projection.

``installer-version.json`` is intentionally independent from
``product-version.json``: the former versions the native updater while the
latter versions Forge Platform's composition/release product.  The native app
may only report the source-of-truth installer version after this check passes.
"""
from __future__ import annotations

import json
from pathlib import Path
import re
import sys
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "installer-version.json"
SWIFT_PROJECTION = ROOT / "macos" / "ForgePlatformInstaller" / "Sources" / "ForgePlatformInstaller" / "ForgePlatformInstallerApp.swift"
SCHEMA = "forge-platform.installer-version/v1"
PRODUCT = "forge-platform-installer"
CHANNELS = frozenset({"stable", "candidate"})
VERSION = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
CAPABILITY = re.compile(r"^[a-z0-9][a-z0-9./_-]{0,127}$")
SWIFT_VERSION = re.compile(r'static let currentVersion = try! InstallerVersion\("([^"]+)"\)')


def _pairs(pairs: list[tuple[object, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if not isinstance(key, str) or key in result:
            raise ValueError("installer version manifest has duplicate or invalid keys")
        result[key] = value
    return result


def load_manifest() -> dict[str, Any]:
    try:
        value = json.loads(MANIFEST.read_text(encoding="utf-8"), object_pairs_hook=_pairs)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        raise RuntimeError("installer version manifest is unreadable") from error
    if not isinstance(value, dict) or set(value) != {"schema", "product", "version", "channel", "capabilities"}:
        raise RuntimeError("installer version manifest fields are invalid")
    if value["schema"] != SCHEMA or value["product"] != PRODUCT:
        raise RuntimeError("installer version manifest identity is invalid")
    version = value["version"]
    if not isinstance(version, str) or VERSION.fullmatch(version) is None:
        raise RuntimeError("installer version must be stable X.Y.Z")
    if value["channel"] not in CHANNELS:
        raise RuntimeError("installer channel is unsupported")
    capabilities = value["capabilities"]
    if not isinstance(capabilities, list) or not capabilities:
        raise RuntimeError("installer capabilities must be a non-empty list")
    if any(not isinstance(capability, str) or CAPABILITY.fullmatch(capability) is None for capability in capabilities):
        raise RuntimeError("installer capability identity is invalid")
    if len(capabilities) != len(set(capabilities)):
        raise RuntimeError("installer capabilities must be unique")
    return value


def validate() -> None:
    manifest = load_manifest()
    try:
        swift = SWIFT_PROJECTION.read_text(encoding="utf-8")
    except OSError as error:
        raise RuntimeError("native installer version projection is unreadable") from error
    matches = SWIFT_VERSION.findall(swift)
    if matches != [manifest["version"]]:
        raise RuntimeError("native installer version projection does not match installer-version.json")
    print(
        "INSTALLER_VERSION=PASS"
        f" version={manifest['version']}"
        f" channel={manifest['channel']}"
        f" capabilities={','.join(manifest['capabilities'])}"
    )


if __name__ == "__main__":
    try:
        validate()
    except RuntimeError as error:
        print(f"INSTALLER_VERSION=FAIL reason={error}", file=sys.stderr)
        raise SystemExit(1) from error
