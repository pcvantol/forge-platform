# Forge Platform

Forge Platform is the canonical, first-class repository for cross-product distribution, deployment, installation, update, repair, uninstall, component compatibility, and installation-topology orchestration across the Forge product family. It is a peer of [Forge](https://github.com/pcvantol/forge), [Workspace](https://github.com/pcvantol/workspace), [Engineering Platform](https://github.com/pcvantol/engineering-platform), and [Technical Debt Engine](https://github.com/pcvantol/technical-debt-engine); it is not a subdirectory of Forge or an Engineering Platform installer folder.

## Status

Repository foundation with bounded source-level component-operation and
release-composition evidence kernels. The component-operation contract consumes
product-owned runtime readback, exact-candidate update assessment, and
execute/resume evidence without selecting a runtime itself. A strict Universal
Installer policy kernel and native macOS SwiftUI wizard shell now exist for
self-update, signed composition selection, preflight, managed Git/Python
planning, provider gating, and read-only diffs. A signed/notarized installer
release, privileged bootstrapper, and concrete product adapters remain
unimplemented; this repository does not publish producer product artifacts or
change product runtime behavior.

## Boundary

Forge Platform consumes qualified, versioned artifacts published by product repositories and composes them into compatible installations. It does not rebuild their source or own Forge, Workspace, Engineering Platform, Project Agent, TDE, generic AI-development governance, or Knowledge Base behavior.

## Entrypoints

- [Architecture](docs/architecture/README.md)
- [System architecture](docs/architecture/FORGE_PLATFORM_ARCHITECTURE.md)
- [Governed Knowledge Learning Loop](docs/architecture/KNOWLEDGE_LEARNING_LOOP.md)
- [Architecture Decision Records](docs/architecture/adr/README.md)
- [Cross-repository ownership matrix](docs/architecture/OWNERSHIP_MATRIX.md)
- [Component-operation delegation contract](docs/architecture/COMPONENT_OPERATION_DELEGATION_CONTRACT.md)
- [Universal macOS Installer contract](docs/architecture/UNIVERSAL_MACOS_INSTALLER_CONTRACT.md)
- [Roadmap](docs/roadmap/README.md)
- [MVP 1.0 roadmap](docs/roadmap/MVP_1_0.md)
- [Development and bootstrap](docs/development/README.md)
- [Governance](docs/governance/README.md)
- [TDE integration](docs/development/TDE_INTEGRATION.md)
