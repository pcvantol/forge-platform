# Historical roadmap and platform-document migration register

**Purpose:** preserve auditable provenance while making `docs/roadmap/` the canonical Forge Platform roadmap entrypoint. This register classifies read-only discovery in `pcvantol/djconnect`; it does not modify, delete, or retroactively relabel DJConnect documents.

## Classification key

| Code | Meaning |
| --- | --- |
| A | Migrated or canonically represented in Forge Platform. |
| B | Contains a bounded canonical input still needing a governed migration into its owning first-class repository. |
| C | Historical, audit, or design evidence only. |
| D | DJConnect-specific material that remains in DJConnect. |
| E | Superseded or obsolete; preserve as evidence and mark in its source only in a separately authorized change. |

## Examined material and disposition

| DJConnect material | Classification | Disposition / canonical destination |
| --- | --- | --- |
| `docs/ENGINEERING_PLATFORM_STATUS.md` | C | Snapshot of a former repository-local EP status. Current EP product and Forge Platform composition status must be established in their first-class repositories. |
| `docs/PRODUCT_DEVELOPMENT_TRANSITION.md` | C | Transition evidence; not a current Forge Platform product roadmap. |
| `docs/development/ENGINEERING_PLATFORM_ROADMAP.md` | C | Its product-boundary concepts are now represented by the Forge Platform architecture and MVP roadmap; phase names, schemas, ports, and completion claims remain historical evidence. |
| `docs/development/ENGINEERING_PLATFORM_EXTRACTION_AUDIT.md` | C | Extraction-readiness evidence for the former DJConnect location. |
| `docs/development/ENGINEERING_PLATFORM_EXTRACTION_MIGRATION_PLAN.md` | B | Supplies the clean-store/forensic-retention migration input for `MVP-MIG-001`; EP owns the future executable migration contract. Historical increment status remains evidence. |
| `docs/engineering/ENGINEERING_PLATFORM_ARCHITECTURE_HANDBOOK.md` | C | Authority, producer-neutral execution, Agent/Worker, and lock concepts are represented in Forge Platform architecture; implementation detail and old runtime claims remain historical. |
| `docs/engineering/EXECUTION_HOST_ARCHITECTURE.md`, `EXECUTION_LIFECYCLE_FLOW.md`, execution/receipt/report documents | B | Inputs for EP-owned installed-artifact qualification, recovery, and evidence. Do not migrate product implementation detail into Forge Platform. |
| `docs/engineering/FORGE_GOVERNANCE_HANDOFF.md` and consumer-contract material | B | Input for versioned Forge↔EP provenance and consumer contracts (`MVP-PROJ-001`, `MVP-FORGE-001`); canonical contract location belongs to the owning product repositories. |
| `docs/engineering/PROVIDER_USAGE_SEMANTICS.md` and provider/telemetry documents | B | Input for honest provider usage attribution (`MVP-OPS-001`). Exact Codex CLI semantics are historical/version-specific until requalified. |
| `docs/platform_evolution/PLATFORM_RELEASE_OBSERVATORY_DESIGN.md` | C | Valuable release-observability design evidence; it neither authorizes a Forge Platform observatory nor blocks MVP beyond required composition evidence. |
| `docs/release/PLATFORM_RELEASE_ROADMAP.md`, release manifests, deployment architecture/evidence | C | Historical release-system planning and evidence. Forge Platform owns future composition qualification, not a retroactive DJConnect release program. |
| `docs/release/MACOS_DEVELOPMENT_HOST_BOOTSTRAP.md` and runner/bootstrap material | D | DJConnect development-host and runner concerns remain DJConnect-specific. It is not the universal installer or a Forge Platform host requirement. |
| `docs/governance/`, `docs/implementation/`, `docs/research/`, `docs/meta/` material concerning DJConnect product delivery | D | Retain in DJConnect unless a separately audited item has cross-product authority. No bulk migration is implied. |
| `docs/history/`, including prompt and implementation history | C | Preserve as immutable forensic/audit evidence; never promote historical execution prompts or status reports into current requirements without a governed decision. |
| DJConnect-branded UX, Home Assistant, iCloud, runner, and product release content | D | Remains DJConnect product/development material. |
| Retired contaminated CENTRAL/LEGACY cutover projections | E | Superseded by the documented clean-slate/forensic-retention direction; retain as evidence. Any source-file status marking requires a separate DJConnect-governed change. |

## Information represented by this consolidation

- Cross-product authority, project/host/Agent topology, canonical APIs rather than filesystem shortcuts, artifact composition, manifest/compatibility, installer lifecycle, and knowledge-loop boundaries are represented in the Forge Platform architecture and [MVP roadmap](MVP_1_0.md).
- The remaining critical input is intentionally narrow: product-owned versioned artifact, consumer, Agent, storage/recovery, and migration contracts must be implemented and qualified in their owning repositories before Forge Platform may release a composition.
- No DJConnect file is asserted to have been changed by this register. A later DJConnect change may add reader pointers to Forge Platform after its own review, but must retain DJConnect-specific material and historical evidence.

## Non-transfer rules

Forge Platform does not inherit DJConnect's product authority, EP source implementation, Workspace UX authority, Forge planning authority, provider secrets, host readiness policy, release records, or CENTRAL/LEGACY stores. Historical documents never become canonical merely by being referenced here.

The family-wide authority audit should revisit this register whenever an EP, Forge, Workspace, or DJConnect document changes ownership or when a product contract becomes publishable.
