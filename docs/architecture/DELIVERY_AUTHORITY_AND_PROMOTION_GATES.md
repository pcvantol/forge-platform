# Delivery authority and promotion gates

Increment: `GOVERNED_PROGRESSION_AND_DELIVERY_AUTHORITY_V1`.
Documentation target only; canonical on owning main after merge, otherwise
PENDING_PR. No installer, manifest schema, pipeline, runtime or policy activation
is implemented here. This elaborates [policy-aware composition](POLICY_AWARE_COMPOSITION.md)
and the [ownership matrix](OWNERSHIP_MATRIX.md).
Shared contract:
`pcvantol/forge:docs/architecture/GOVERNED_PROGRESSION_AND_DELIVERY_AUTHORITY.md`.
Local sequencing: [governed progression roadmap](../roadmap/GOVERNED_PROGRESSION_V1.md).

## Scope of universal deployment ownership

Forge Platform's ownership of installation/deployment composition means its own
qualified product distribution and explicitly delegated target operations. It
does NOT mean ownership of every customer's CD/release system. Existing project
or organization pipelines keep production approval, deployment/publication,
credentials and rollback. Co-location, installing an Agent/Server, or selecting
a preset transfers none of those rights.

Forge owns planning, Mission cadence and requirement resolution; EP owns bounded
engineering execution and assurance; Workspace owns the human view/interaction.
A declared delivery authority owns the actual target operation. The universal
installer does not become a second gate engine, release allocator or CD runner.
No direct peer SQL or bypass of product-owned migration/installation contracts.

## Target and authority declaration

Consume a project-owned Delivery Control Contract that declares stable target,
environment class (TST/ACC/PROD/custom), account/resource/audience, supported
operations, request/trigger authority, approval authority and deployment authority
separately. Include pipeline/entrypoint/configuration revision, artifact input,
compatibility, decision/evidence readback and rollback/cancellation ownership.
The external owner's actual configuration remains authoritative; detected drift
must be reconciled rather than hidden by a stale project declaration.

A policy may automatically allow TST/ACC progression while requiring a PROD or
store-submission decision. Another target may be stricter. Environment labels
alone confer no permission; actual endpoint/account/artifact binding must agree.
App upload, submission for review and public release are different operations;
one does not prove or authorize the next. Generic publish/deploy names may not
collapse these boundaries.

## Preserve an existing gate instead of duplicating it

For a logical approval requirement, resolve the existing authoritative gate and
verify equivalent semantics and exact candidate/target coverage. A configured
mapping is not a satisfied approval. Workspace shows externally pending status
and trusted details/deep-link, not another Approve button. The installer cannot
silently substitute its own confirmation dialog for an organization CD approval.

Separate business release and SRE production approvals may both be required by
explicit policy. Keep their identities and scopes distinct. Do not duplicate
one requirement and do not collapse genuine separation of duties by matching
labels. Unknown authority/evidence blocks the dependent operation rather than
creating a new local gate or permitting a direct deployment fallback.

`OBSERVE_ONLY` is the default for external delivery. An explicitly authorized
`REQUEST_AND_WAIT` path may invoke the existing entrypoint through its permitted
actor/adapter. Direct trigger permission is a separately bounded capability
inside that mode, not deployment or approval permission. A pipeline can be
requested before its own human gate exists if that external pipeline enforces
the gate before the protected side effect. If trigger itself publishes/deploys,
the approval must precede trigger. Never demand a circular approval dependency.

No general production/cloud/store credentials are copied into Forge/Workspace
or an installer simply to request a pipeline. Required secrets remain with their
owning execution system. An external outage never authorizes a fallback writer.

## Exact promotion and composition evidence

Keep product/component version, qualified source revision, exact artifact digest,
policy/contract revision, release/operation identity, target/environment and
pipeline/run/approval references separate. Approval binds the relevant values;
changed artifact, target, pipeline or material policy invalidates old evidence.
A source merge, identical version label or successful trigger is not proof that
a target deployed the approved artifact. Promotion should reuse qualified bytes;
any rebuild with different bytes is a new candidate requiring qualification.

Final component manifests still require real published producer artifacts and
qualification/provenance. No future checksum or source SHA may be guessed.
External decision evidence supplements artifact integrity; neither replaces the
other. Native Forge release planning consumes these authority bindings; this
document does not implement that capability or the repository SemVer helpers.

At protected install/update/publish/deploy operations, the actual owner verifies
current scope, credentials, expiry/revocation, compatible policy and exact decision.
Persist intent before an authorized request and reconcile lost responses using
the same operation identity. Do not re-trigger or claim success from cached
approval. Authenticated callbacks/readback must bind run, target and artifact;
duplicates and out-of-order observations cannot unlock twice. Inadequate external
evidence stays unsupported/unverified, not converted into a fabricated receipt.

Installer selection, request accepted, approval granted, deployment performed,
health/verification passed and public release are separate facts in receipts.
Partial compositions remain visible. Failure of a later component, cleanup or
rollback does not erase an earlier proven delivery. Retry/rollback follows the
owning contract without resetting grants, review history or consumed budgets.
A Forge review pause does not cancel an already running pipeline.

## Independent installation modes

EP-only, Forge+EP, Workspace+EP, all-server and remote-peer installations retain
their independent product authorities. A machine without an external pipeline
can use a qualified product-owned installation route when explicitly authorized;
absence of CD is not permission to invent one. A target that is CD-owned must
continue through that system even when an installer could technically write it.

GP-P concerns the external-delivery-aware composition extension, not all existing
local installations. Existing POL-P/VR-Q/artifact/installed qualification stays
applicable where used. Full Workspace policy UI, external CD adapters and general
discovery are not new prerequisites for the first no-deployment Mission canary.

## Future acceptance

Qualify: selected automatic TST/ACC and externally gated PROD; no duplicate gate;
separate business/SRE obligations; wrong account/target/environment; changed
artifact/config after approval; authorized request before external gate; rejected
or unavailable external gate; lost request/restart; authenticated wrong-run
receipt; replay/out-of-order evidence; store submission not public release;
installed target retains external authority; no production credentials/SQL bypass;
state/grant/history preservation. All implementation remains PLANNED.
