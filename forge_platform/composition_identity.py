"""One exact composition-identity grammar for installer policy surfaces.

A composition identity is signed/public correlation data, not a display label,
path, URL, or shell fragment. Keep its Unicode-scalar grammar independent from
component identifiers so an immutable composition can retain a meaningful
non-ASCII identity without whitespace or controls becoming ambiguous across
the outer catalog, manifest, selection index, journal, and native session
envelope.
"""

from __future__ import annotations


def require_composition_identity(value: object, label: str) -> str:
    """Return one bounded, whitespace-free sequence of Unicode scalars.

    The checks intentionally mirror the native macOS admission grammar:
    1--256 Unicode scalars; no C0/DEL controls, Unicode whitespace, or lone
    UTF-16 surrogate. Python otherwise permits a lone surrogate in ``str``
    even though it cannot represent a Swift Unicode scalar or a valid UTF-8
    signed identity.
    """

    if not isinstance(value, str) or not value or len(value) > 256:
        raise ValueError(f"{label} must be a bounded whitespace-free identity")
    for scalar in value:
        codepoint = ord(scalar)
        if (
            codepoint < 0x20
            or codepoint == 0x7F
            or 0xD800 <= codepoint <= 0xDFFF
            or scalar.isspace()
        ):
            raise ValueError(f"{label} must be a bounded whitespace-free identity")
    return value
