#!/usr/bin/env python3
"""Validate or advance Forge-family product semantic versions."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re

VERSION = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")


def version_file(root: Path) -> Path:
    return root.resolve() / "product-version.json"


def current(root: Path) -> tuple[Path, dict[str, object], tuple[int, int, int]]:
    target = version_file(root)
    try:
        payload = json.loads(target.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise RuntimeError("canonical product version manifest is unreadable") from error
    value = payload.get("version") if isinstance(payload, dict) else None
    if payload.get("schema_version") != 1 or not isinstance(payload.get("product"), str) or not isinstance(value, str):
        raise RuntimeError("canonical product version manifest is invalid")
    match = VERSION.fullmatch(value)
    if match is None:
        raise RuntimeError("canonical product version must be stable X.Y.Z")
    return target, payload, tuple(int(part) for part in match.groups())


def advance(root: Path, component: str) -> str:
    target, payload, (major, minor, patch) = current(root)
    if component == "patch":
        version = f"{major}.{minor}.{patch + 1}"
    elif component == "minor":
        version = f"{major}.{minor + 1}.0"
    else:
        raise RuntimeError("version component must be patch or minor")
    payload["version"] = version
    target.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return version


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", type=Path, default=Path.cwd())
    parser.add_argument("--bump", choices=("patch", "minor"))
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args(argv)
    if args.check == (args.bump is not None):
        parser.error("provide exactly one of --check or --bump")
    if args.check:
        _, payload, _ = current(args.source_root)
        print(f"PRODUCT_VERSION=PASS version={payload['version']}")
    else:
        print(f"PRODUCT_VERSION={advance(args.source_root, args.bump)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
