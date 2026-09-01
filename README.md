# Forge Platform

Forge Platform is the canonical, first-class repository for cross-product distribution, deployment, installation, update, repair, uninstall, component compatibility, and installation-topology orchestration across the Forge product family. It is a peer of [Forge](https://github.com/pcvantol/forge), [Workspace](https://github.com/pcvantol/workspace), [Engineering Platform](https://github.com/pcvantol/engineering-platform), and [Technical Debt Engine](https://github.com/pcvantol/technical-debt-engine); it is not a subdirectory of Forge or an Engineering Platform installer folder.

## Status

Repository foundation only. The universal installer is not implemented, and this repository does not publish production artifacts or change product runtime behavior.

## Boundary

Forge Platform consumes qualified, versioned artifacts published by product repositories and composes them into compatible installations. It does not rebuild their source or own Forge, Workspace, Engineering Platform, Project Agent, TDE, generic AI-development governance, or Knowledge Base behavior.

## Entrypoints

- [Architecture](docs/architecture/README.md)
- [Roadmap](docs/roadmap/README.md)
- [Development and bootstrap](docs/development/README.md)
- [Governance](docs/governance/README.md)
- [TDE integration](docs/development/TDE_INTEGRATION.md)
