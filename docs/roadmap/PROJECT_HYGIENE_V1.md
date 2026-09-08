# Forge Platform repository-hygiene composition roadmap

Increment: `PROJECT_HYGIENE_AND_REPOSITORY_RECONCILIATION_V1`.
Owning design: [Repository hygiene at release/installation boundaries](../architecture/REPOSITORY_HYGIENE_RELEASE_BOUNDARY.md).
Parent: [Forge Platform roadmap](README.md).
Coordinated [documentary DAG](https://github.com/pcvantol/forge/blob/main/docs/roadmap/project-hygiene-v1.json).

`HY-P` is PLANNED composition qualification after the relevant Forge/EP `HY-Q`
contracts are qualified. It is not a new package, scanner, release gate for every
artifact, or prerequisite to the first serial autonomy canary. Workspace UI and
general Agent fleet support are not prerequisites for a bounded composition.

Acceptance: bind applicable assessment to selected source/repository/operation;
retain unrelated branches without blocking release; block genuine relevant stale
conflicts; report partial optional scope; preserve artifact/rollback provenance;
keep installer state cleanup separate from project repository cleanup; enforce
actual supported capabilities and existing external CD authority.

An observation-only composition does not claim mutation support. Installation
must not enable automatic deletion or alter scopes/grants. Runtime activation
requires real owner-supported contracts, policy and operator authorization,
separate from this documentation delivery. Existing published component-manifest
and product-source/installer trust gates remain unchanged.
