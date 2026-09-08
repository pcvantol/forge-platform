# Component-manifest contract

A future Forge Platform component manifest declares a tested release composition without embedding production endpoint choices in source control.

For each platform release and component, it must identify:

- Forge Platform release version;
- component identity and version;
- qualified source revision and version-preparation operation identity where
  applicable;
- artifact URI or source reference;
- artifact name, SHA-256 digest and exact-byte identity;
- signature and provenance evidence;
- supported operating systems and architectures;
- protocol compatibility; and
- required and optional dependencies.

The accompanying [JSON Schema](../../schemas/component-manifest.schema.json) is a
structural descriptor boundary, not a production manifest or installer input.
It carries no invented artifact URL, SHA, qualification, or component pin.
Artifact locations and credentials are resolved only by future qualified release
processes. Product version, API/protocol version, policy version, source revision
and artifact digest are separate identities; equality of version strings is not
compatibility or publication evidence.
