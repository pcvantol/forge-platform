# Repository hygiene at release and installation boundaries

## Decision and owner

Increment: `PROJECT_HYGIENE_AND_REPOSITORY_RECONCILIATION_V1`.
Documentation/roadmap target only; no installer behavior, source scanner, registry
policy or cleanup permission is activated here.

Forge owns project-wide [hygiene/reconciliation](https://github.com/pcvantol/forge/blob/main/docs/architecture/PROJECT_HYGIENE_AND_REPOSITORY_RECONCILIATION.md);
EP owns repository observation and admitted cleanup. Forge Platform remains the
qualified artifact composer/installer, under the [ownership matrix](OWNERSHIP_MATRIX.md),
[evidence-gated composition](EVIDENCE_GATED_COMPONENT_COMPOSITION.md) and
[existing delivery authority](DELIVERY_AUTHORITY_AND_PROMOTION_GATES.md).

## Scope-specific input, not a universal release veto

A repository-hygiene assessment is an input bound to a selected repository,
source revision, release/composition operation, observation scope/freshness,
case/decision references and relevant unresolved conflicts. It is not evidence
that an artifact exists, that its bytes match, or that an external CD gate passed.

Only applicable source/operation risks block: for example an active conflicting
writer on the selected source, unexplained candidate changes or unavailable
mandatory evidence. An old retained branch unrelated to the chosen artifact
does not prohibit a release. A closed case for one branch is not proof that the
whole repository contains no unexplained work. Partial/unknown scope stays
visible rather than converted into a blanket healthy signal.

Full native hygiene scanning is not a new prerequisite for first Forge/EP
canary or every existing package install. If policy requires an assessment,
validate its exact supported contract and required coverage. Unknown or stale
required evidence blocks the dependent operation; missing optional evidence is
a warning, not fabricated success or a global halt.

## Artifact and repository lifecycles remain separate

Deleting a source branch must not delete an installed wheel, publication receipt,
release provenance, rollback artifact or archive needed to recover old work.
Published component pins continue to bind actual artifact digest, source revision
and qualification. A later branch state does not silently retarget those pins.

Conversely, installing/updating/uninstalling Forge, EP or Workspace must not prune
project refs/worktrees, erase cases/receipts, reset grants/budgets or activate a
cleanup profile. Product-owned data-root backup/migration and installer cache
retention are different contracts. No installer recursive-clean command is a
substitute for EP repository cleanup.

If repository cleanup affects a source/recovery object referenced by an active
release, retain it until the owning release/retention requirements are resolved.
Forge Platform can report such dependencies through authenticated owner contracts;
it cannot write a Forge ledger or EP CENTRAL record directly.

## Capability composition and external authority

Distributions declare only genuinely implemented/qualified observation,
reconciliation, command/readback and UI contracts. Installing a newer product
version does not itself grant repository write/delete scope. Observe-only profiles
may operate without mutation capability; unsupported mutation stays unavailable.
No full Agent fleet, Workspace UI or native Forge releaseplanner is smuggled in
as a requirement for a single-host read-only slice.

Existing project/organization CD retains approval, deployment credentials and
rollback. A hygiene report, Workspace confirmation or version match cannot
satisfy that separate authority. No duplicate CD approval or direct deploy path
is introduced by this increment.

## Qualification and roadmap

The [scoped roadmap](../roadmap/PROJECT_HYGIENE_V1.md) joins after qualified producer/consumer
facts and cleanup semantics where those are actually composed. Required tests:
exact source/operation/digest binding; unrelated retained branch does not block;
relevant stale conflict does; optional unavailable scan remains a warning;
source-ref cleanup preserves artifact/rollback provenance; install/uninstall
cannot delete project data; unsupported peer contract is explicit; external CD
gates remain enforced. No implementation or installed qualification is claimed.
