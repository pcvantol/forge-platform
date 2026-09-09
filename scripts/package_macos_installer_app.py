#!/usr/bin/env python3
"""Create one deterministic, unsigned macOS ``.app`` candidate bundle.

This helper is deliberately limited to bundle layout.  It does not invoke a
signer, query Keychain, submit to Apple, staple a ticket, or publish anything.
The output is therefore a *candidate* that a protected signing/notarization
stage must replace or qualify before it can be distributed.
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import sys

from validate_installer_version import load_manifest


_BUNDLE_IDENTIFIER = re.compile(r"^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$")
_MINIMUM_MACOS = "14.0"


def _source_executable(value: str) -> Path:
    supplied = Path(value).expanduser()
    if supplied.is_symlink():
        raise ValueError("installer executable must not be selected through a symlink")
    candidate = supplied.resolve(strict=True)
    if not candidate.is_file():
        raise ValueError("installer executable must be a regular non-symlink file")
    if not os.access(candidate, os.X_OK):
        raise ValueError("installer executable must be executable")
    return candidate


def _output_bundle(value: str) -> Path:
    candidate = Path(value).expanduser().resolve(strict=False)
    if candidate.suffix != ".app":
        raise ValueError("installer app bundle output must end in .app")
    if candidate.exists():
        raise ValueError("installer app bundle output must not already exist")
    if candidate.parent.exists() and not candidate.parent.is_dir():
        raise ValueError("installer app bundle parent is not a directory")
    return candidate


def _bundle_identifier(value: str) -> str:
    if _BUNDLE_IDENTIFIER.fullmatch(value) is None:
        raise ValueError("installer bundle identifier is invalid")
    return value


def package(*, executable: Path, output: Path, bundle_identifier: str) -> None:
    """Lay out an unsigned app bundle without replacing an existing target."""

    manifest = load_manifest()
    version = manifest["version"]
    if not isinstance(version, str):  # The manifest validator establishes this.
        raise RuntimeError("installer version manifest returned an invalid version")

    contents = output / "Contents"
    macos = contents / "MacOS"
    destination = macos / "ForgePlatformInstaller"
    info_plist = contents / "Info.plist"
    try:
        macos.mkdir(parents=True, mode=0o755)
        shutil.copyfile(executable, destination, follow_symlinks=False)
        source_mode = stat.S_IMODE(executable.stat().st_mode)
        destination.chmod(source_mode | stat.S_IXUSR)
        metadata = {
            "CFBundleDevelopmentRegion": "en",
            "CFBundleExecutable": "ForgePlatformInstaller",
            "CFBundleIdentifier": bundle_identifier,
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": "Forge Platform Installer",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": version,
            "LSMinimumSystemVersion": _MINIMUM_MACOS,
            "NSHighResolutionCapable": True,
        }
        with info_plist.open("wb") as stream:
            plistlib.dump(metadata, stream, fmt=plistlib.FMT_XML, sort_keys=True)
        info_plist.chmod(0o644)
    except BaseException:
        # The output path was required to be new and is therefore the sole
        # operation-owned cleanup target on failure.
        shutil.rmtree(output, ignore_errors=True)
        raise


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--executable", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--bundle-identifier", required=True)
    args = parser.parse_args()
    try:
        executable = _source_executable(args.executable)
        output = _output_bundle(args.output)
        bundle_identifier = _bundle_identifier(args.bundle_identifier)
        package(executable=executable, output=output, bundle_identifier=bundle_identifier)
        print(
            "INSTALLER_APP_BUNDLE=PASS"
            f" version={load_manifest()['version']}"
            f" bundle_identifier={bundle_identifier}"
            " signing=UNSIGNED_CANDIDATE"
        )
    except (OSError, RuntimeError, ValueError) as error:
        print(f"INSTALLER_APP_BUNDLE=FAIL reason={error}", file=sys.stderr)
        raise SystemExit(1) from error


if __name__ == "__main__":
    main()
