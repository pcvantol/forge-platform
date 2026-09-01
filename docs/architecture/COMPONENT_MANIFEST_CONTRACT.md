# Component-manifest contract

A future Forge Platform component manifest declares a tested release composition without embedding production endpoint choices in source control.

For each platform release and component, it must identify:

- Forge Platform release version;
- component identity and version;
- artifact URI or source reference;
- artifact digest;
- signature and provenance evidence;
- supported operating systems and architectures;
- protocol compatibility; and
- required and optional dependencies.

The accompanying [JSON Schema](../../schemas/component-manifest.schema.json) is a structural contract, not a production manifest. Artifact locations and credentials are resolved only by future qualified release processes.
