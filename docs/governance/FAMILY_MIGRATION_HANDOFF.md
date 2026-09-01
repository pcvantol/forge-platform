# Repository-family authority migration handoff

## New canonical repository

`pcvantol/forge-platform` is the future canonical authority for universal multi-product installer UX, component selection, cross-product compatibility declarations, release composition, installation topology, update/repair/uninstall orchestration, diagnostics, and deployment receipts.

## Boundary retained by product repositories

- Engineering Platform owns the EP Server artifact, EP Project Agent artifact, EP-specific packaging, clean-store bootstrap, and service-installation contract.
- Workspace owns Workspace Server, Workspace Clients, and Workspace product UX.
- Forge owns planning, architecture, and orchestration product behavior.

Forge Platform may install those artifacts but does not implement them.

## Migration candidates for family audit

The ongoing duplicate/authority audit must include this repository. Read-only discovery identified the following inputs, which remain in their source repositories until separately governed migration:

| Repository | Material | Classification |
| --- | --- | --- |
| `pcvantol/engineering-platform` | `docs/adr/0019-engineering-platform-central-installation-store.md` | `PRODUCT_LOCAL_ARTIFACT_CONTRACT` |
| `pcvantol/djconnect` | `docs/adr/0018-platform-device-distribution-and-provisioning.md` | `HISTORICAL` |
| `pcvantol/djconnect` | `docs/release/DEPLOYMENT_ARCHITECTURE.md` and release-manifest material | `MIXED` |
| `pcvantol/forge` | No universal-installer/distribution implementation lineage found | `UNRESOLVED` |
| `pcvantol/workspace` | No universal-installer/distribution implementation lineage found | `UNRESOLVED` |

Future cross-product installer/composition documentation is `FORGE_PLATFORM_FUTURE_AUTHORITY`; no source document is moved or deleted by this foundation.
