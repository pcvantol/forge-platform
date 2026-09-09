#!/usr/bin/env python3
"""Create one deterministic, unsigned macOS ``.app`` candidate bundle.

This helper is deliberately limited to bundle layout.  It does not invoke a
signer, query Keychain, submit to Apple, staple a ticket, or publish anything.
The output is therefore a *candidate* that a protected signing/notarization
stage must replace or qualify before it can be distributed.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
import json
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
_SEALED_RELEASE_TRUST_RESOURCE_NAME = "ForgePlatformInstallerReleaseTrust.json"
_SEALED_RELEASE_TRUST_MAXIMUM_BYTES = 16 * 1024
_SHA256 = re.compile(r"^[0-9a-f]{64}$")
_OPAQUE_REFERENCE = re.compile(r"^[A-Za-z0-9._:-]{1,255}$")


@dataclass(frozen=True)
class SealedReleaseTrustResource:
    """Validated, non-secret bytes for the released application's trust file.

    The source is retained only for local diagnostics/tests.  Packaging writes
    ``contents`` captured during validation rather than reopening the caller's
    path, so a later source-file change cannot turn a validated descriptor into
    different bundled bytes.
    """

    source: Path
    contents: bytes


def _strict_json_object(pairs: list[tuple[object, object]]) -> dict[str, object]:
    value: dict[str, object] = {}
    for key, member in pairs:
        if not isinstance(key, str) or key in value:
            raise ValueError("sealed release trust resource has duplicate or invalid JSON keys")
        value[key] = member
    return value


def _reject_json_constant(value: str) -> None:
    raise ValueError(f"sealed release trust resource contains unsupported JSON constant {value}")


def _canonical_release_trust_digest(*, schema_version: int, trust_key_reference: str) -> str:
    canonical_payload = "\0".join(
        (
            "forge-platform-installer-release-trust-v1",
            str(schema_version),
            trust_key_reference,
        )
    )
    return hashlib.sha256(canonical_payload.encode("utf-8")).hexdigest()


def _read_regular_non_symlink_file(value: str, *, description: str, maximum_bytes: int) -> tuple[Path, bytes]:
    """Read one bounded regular file without following a leaf symlink.

    Ancestor symlinks are normalized to their physical path.  This preserves
    normal macOS paths such as ``/tmp`` while refusing a caller-selected file
    symlink and retaining the exact bytes that were validated.
    """

    supplied = Path(value).expanduser()
    if supplied.is_symlink():
        raise ValueError(f"{description} must not be selected through a symlink")
    try:
        source = supplied.resolve(strict=True)
    except FileNotFoundError as error:
        raise ValueError(f"{description} does not exist") from error
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(source, flags)
    except FileNotFoundError as error:
        raise ValueError(f"{description} does not exist") from error
    except OSError as error:
        raise ValueError(f"{description} cannot be opened safely") from error
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode):
            raise ValueError(f"{description} must be a regular non-symlink file")
        if before.st_size > maximum_bytes:
            raise ValueError(f"{description} exceeds its maximum size")
        with os.fdopen(descriptor, "rb", closefd=False) as stream:
            contents = stream.read(maximum_bytes + 1)
        if len(contents) > maximum_bytes:
            raise ValueError(f"{description} exceeds its maximum size")
        # A descriptor written while it is being read is not a stable trust
        # input.  Reject it rather than copying a partially observed resource.
        after = os.fstat(descriptor)
        if (
            before.st_dev != after.st_dev
            or before.st_ino != after.st_ino
            or before.st_size != after.st_size
            or before.st_mtime_ns != after.st_mtime_ns
        ):
            raise ValueError(f"{description} changed while it was being read")
        return source, contents
    finally:
        if descriptor >= 0:
            os.close(descriptor)


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


def _sealed_release_trust_resource(value: str) -> SealedReleaseTrustResource:
    """Validate the exact non-secret descriptor consumed by the native loader."""

    supplied = Path(value).expanduser()
    if supplied.suffix != ".json":
        raise ValueError("sealed release trust resource must have a .json filename")
    source, contents = _read_regular_non_symlink_file(
        value,
        description="sealed release trust resource",
        maximum_bytes=_SEALED_RELEASE_TRUST_MAXIMUM_BYTES,
    )
    try:
        parsed = json.loads(
            contents.decode("utf-8"),
            object_pairs_hook=_strict_json_object,
            parse_constant=_reject_json_constant,
        )
    except (UnicodeDecodeError, ValueError, json.JSONDecodeError) as error:
        raise ValueError("sealed release trust resource is not strict UTF-8 JSON") from error
    expected_fields = {"schema_version", "configuration_sha256", "trust_key_reference"}
    if not isinstance(parsed, dict) or set(parsed) != expected_fields:
        # Exact fields deliberately reject private keys, public-key payloads,
        # repository identities, URLs, and every other implicit trust input.
        raise ValueError("sealed release trust resource has unsupported or missing fields")
    schema_version = parsed["schema_version"]
    configuration_sha256 = parsed["configuration_sha256"]
    trust_key_reference = parsed["trust_key_reference"]
    if type(schema_version) is not int or schema_version != 1:
        raise ValueError("sealed release trust resource schema version is unsupported")
    if not isinstance(configuration_sha256, str) or _SHA256.fullmatch(configuration_sha256) is None:
        raise ValueError("sealed release trust resource configuration digest is invalid")
    if not isinstance(trust_key_reference, str) or _OPAQUE_REFERENCE.fullmatch(trust_key_reference) is None:
        raise ValueError("sealed release trust resource trust-key reference is invalid")
    expected_digest = _canonical_release_trust_digest(
        schema_version=schema_version,
        trust_key_reference=trust_key_reference,
    )
    if configuration_sha256 != expected_digest:
        raise ValueError("sealed release trust resource configuration digest does not match its fields")
    return SealedReleaseTrustResource(source=source, contents=contents)


def _output_bundle(value: str) -> Path:
    supplied = Path(value).expanduser()
    if supplied.is_symlink():
        raise ValueError("installer app bundle output must not be selected through a symlink")
    candidate = supplied.resolve(strict=False)
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


def package(
    *,
    executable: Path,
    output: Path,
    bundle_identifier: str,
    sealed_release_trust: SealedReleaseTrustResource | None = None,
) -> None:
    """Lay out an unsigned app bundle without replacing an existing target."""

    manifest = load_manifest()
    version = manifest["version"]
    if not isinstance(version, str):  # The manifest validator establishes this.
        raise RuntimeError("installer version manifest returned an invalid version")

    contents = output / "Contents"
    macos = contents / "MacOS"
    resources = contents / "Resources"
    destination = macos / "ForgePlatformInstaller"
    info_plist = contents / "Info.plist"
    output_owned = False
    try:
        output.parent.mkdir(parents=True, exist_ok=True)
        try:
            output.mkdir(mode=0o755)
        except FileExistsError as error:
            raise ValueError("installer app bundle output must not already exist") from error
        output_owned = True
        contents.mkdir(mode=0o755)
        macos.mkdir(mode=0o755)
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
        if sealed_release_trust is not None:
            resources.mkdir(mode=0o755)
            trust_destination = resources / _SEALED_RELEASE_TRUST_RESOURCE_NAME
            with trust_destination.open("xb") as stream:
                stream.write(sealed_release_trust.contents)
            trust_destination.chmod(0o644)
    except BaseException:
        # The output path was required to be new and is therefore the sole
        # operation-owned cleanup target on failure.
        if output_owned:
            shutil.rmtree(output, ignore_errors=True)
        raise


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--executable", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--bundle-identifier", required=True)
    parser.add_argument(
        "--sealed-release-trust-resource",
        help=(
            "explicit non-secret JSON trust descriptor to copy verbatim to "
            f"Contents/Resources/{_SEALED_RELEASE_TRUST_RESOURCE_NAME}"
        ),
    )
    args = parser.parse_args()
    try:
        executable = _source_executable(args.executable)
        output = _output_bundle(args.output)
        bundle_identifier = _bundle_identifier(args.bundle_identifier)
        sealed_release_trust = (
            _sealed_release_trust_resource(args.sealed_release_trust_resource)
            if args.sealed_release_trust_resource is not None
            else None
        )
        package(
            executable=executable,
            output=output,
            bundle_identifier=bundle_identifier,
            sealed_release_trust=sealed_release_trust,
        )
        print(
            "INSTALLER_APP_BUNDLE=PASS"
            f" version={load_manifest()['version']}"
            f" bundle_identifier={bundle_identifier}"
            f" sealed_release_trust={'PACKAGED' if sealed_release_trust is not None else 'ABSENT_FAIL_CLOSED'}"
            " signing=UNSIGNED_CANDIDATE"
        )
    except (OSError, RuntimeError, ValueError) as error:
        print(f"INSTALLER_APP_BUNDLE=FAIL reason={error}", file=sys.stderr)
        raise SystemExit(1) from error


if __name__ == "__main__":
    main()
