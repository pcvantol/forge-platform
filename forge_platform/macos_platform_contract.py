"""Canonical platform contract for the native Forge Platform installer.

The installer itself is one thin arm64 Mach-O application for macOS 26 or
newer.  These read-only helpers keep release preparation, packaging, and
evidence verification on the same exact definition.  They never execute a
binary, extract an archive, mutate a host, or select anything through ``PATH``.
"""

from __future__ import annotations

import struct


INSTALLER_ARCHITECTURE = "arm64"
INSTALLER_ARCHITECTURES = frozenset({INSTALLER_ARCHITECTURE})
MINIMUM_MACOS_MAJOR = 26
MINIMUM_MACOS_VERSION = "26.0"
MINIMUM_MACOS_SEMANTIC_VERSION = "26.0.0"

_MACHO_64_HEADER_SIZE = 32
_MH_MAGIC_64 = 0xFEEDFACF
_CPU_TYPE_ARM64 = 0x0100000C
_MH_EXECUTE = 0x2


def require_thin_arm64_macho_header(header: bytes, label: str) -> None:
    """Require a thin little-endian arm64 Mach-O executable header.

    Universal/fat containers are intentionally rejected even if they contain
    an arm64 slice.  The released bytes must match the Apple-Silicon-only
    descriptor without relying on launch-time slice selection.
    """

    if not isinstance(header, bytes) or len(header) < _MACHO_64_HEADER_SIZE:
        raise ValueError(f"{label} is not a complete 64-bit Mach-O executable")
    try:
        magic, cpu_type, _cpu_subtype, file_type = struct.unpack_from("<IIII", header)
    except struct.error as error:
        raise ValueError(f"{label} has an invalid Mach-O header") from error
    if magic != _MH_MAGIC_64 or cpu_type != _CPU_TYPE_ARM64 or file_type != _MH_EXECUTE:
        raise ValueError(f"{label} must be a thin arm64 Mach-O executable")


def thin_arm64_macho_test_bytes(payload: bytes = b"") -> bytes:
    """Return a minimal non-runnable fixture header for repository tests."""

    return struct.pack(
        "<IIIIIIII",
        _MH_MAGIC_64,
        _CPU_TYPE_ARM64,
        0,
        _MH_EXECUTE,
        0,
        0,
        0,
        0,
    ) + payload
