# Policy-aware artifact and deployment composition

## Decision and scope

Increment: `POLICY_GOVERNANCE_AND_EFFECTIVE_PROFILES_V1`.
This is the Forge Platform-owned architecture in a coordinated documentation and
roadmap increment. It is target authority on owning `main`, `PENDING_PR` otherwise.
It implements no installer, schema, version helper, workflow, policy service,
manifest migration or runtime activation. It grants no merge/publish/install rights.

Baseline observed 2026-09-08: Forge Platform main
`bbdb299ca06217b69220db02c4cc3e86df67a009`.
The [architecture](FORGE_PLATFORM_ARCHITECTURE.md),
[ownership matrix](OWNERSHIP_MATRIX.md), [compatibility contract](COMPATIBILITY.md)
and [discovery/pairing contract](INSTANCE_DISCOVERY_AND_PAIRING_CONTRACT.md)
retain their product boundaries. The [policy roadmap](../roadmap/POLICY_GOVERNANCE_V1.md)
extends the existing composition horizon.

Shared semantics: `pcvantol/forge:docs/architecture/POLICY_GOVERNANCE_AND_EFFECTIVE_PROFILES.md`,
proposal [Forge #50](https://github.com/pcvantol/forge/pull/50).
EP target: [EP #103](https://github.com/pcvantol/engineering-platform/pull/103).
Workspace consumer target: [Workspace #15](https://github.com/pcvantol/workspace/pull/15).
These are coordinated owner proposals, not installed capability evidence.

## One administration experience, independent policy owners

Forge owns native planning/progression/version-release policy and impact reasoning.
EP owns actual execution, admission, validation/assurance, provider constraints,
repair accounting, qualification and execution receipts. Workspace owns role-aware
human policy-management and historical projection. Forge Platform owns composition,
deployment presets, installer compatibility, updates and installation receipts.

Forge maintaining shared policy vocabulary does not give it a global policy
server. Forge Platform maintaining deployment compatibility does not give it
another product's rule evaluator or canonical version source. The installer must
not write peer SQL/files as a shortcut to policy activation.

## Existing baseline and migration concerns

| Concern | Source or proposal | Target disposition |
| --- | --- | --- |
| Product/component ownership | Main architecture and ownership matrix | Preserve independently owned Forge Runtime, EP Server/Agent and Workspace Server/Client artifacts |
| Deployment presets | Main architecture and deployment ADRs | Catalogue as Forge Platform-owned configuration constrained by artifact/host/trust compatibility |
| Policy discovery/management | No implemented generic policy service established by this documentation baseline | Future logical interfaces consumed through owner APIs; no implied availability from a diagram |
| Independent versions | Main compatibility contract | Preserve product/component versions separately from API/schema/policy versions and artifact digests |
| Canonical versioning | Pending #17 at `dee34d2685037ae8621ef878c19626fcc9723625` | Reconcile independent push-bump workflow with native Forge release operations; no approval or code change here |
| Artifact-gated composition | Pending #16 at `17b107b3ace6c5084b9731b9c5d2b6425d20b0aa` | Preserve its owning artifact dependency proposal; policy compatibility supplements, not replaces, release evidence |

Each owned rule must be classified as invariant, governed policy, operational
configuration, authorization grant, runtime fact or implementation limit. A preset
selection does not grant install/merge rights or turn unavailable runtime policy
features into supported ones.

## Version and release authority

`FORGE::VERSION_RELEASE_MANAGEMENT_V1` plans version/release operations for managed
products under their approved policy. Product repositories retain the exact
canonical version source and compatibility promise; EP executes authorized
repository/build/publish Actions. Forge Platform consumes their qualified published
artifacts and independently versions its own distribution product.

A repository can contain multiple independently releaseable components. The
owning contract decides shared versus independent series; the installer must not
assume repository = package = component = version. Equal initial numbers do not
prove compatibility, and this document selects no baseline or new product version.

The policy describes one source per product/component, which may be pyproject or
a dedicated version manifest. Different source formats are valid when explicitly
owned; all package/UI/runtime projections must be derived and checked. No second
allocator may run beside an active Forge-managed operation. Standalone EP retains
an explicit local operation policy when it is not Forge-managed.

Branch-event numbering can be a preference but is not semantic compatibility,
major approval or publication permission. Release decisions bind operation ID,
approved source, version, scope, actor/grant and immutable artifact evidence.
A branch name or matching commit subject alone cannot authorize publication or
establish exactly-once allocation.

Retain the reviewed acceptance requirements for future implementation:
field-specific projections, strict product/schema/type validation, interruption-safe
complete changes, expected-head/idempotent operations, version preparation before
final qualification, build without source/version mutation, separate source and
installed checks, qualified final bot-created head where one exists, and no
replacement of published identity with different artifact content. These address
the SemVer review findings; they are not claimed fixes to pending implementation.

## Required composition descriptor semantics

A future component entry must distinguish at least:

| Meaning | Required evidence |
| --- | --- |
| Product/component identity | Exact product and releaseable role; no filename-only inference |
| Product release | Explicit product version and publication identity |
| Source identity | Qualified source revision and candidate-to-delivery relationship |
| Installable bytes | Artifact name/URI, digest algorithm and exact digest |
| Artifact qualification | Producer qualification/provenance and supported platform/architecture |
| Runtime/API compatibility | Explicit supported contracts, not equality of product version numbers |
| Policy compatibility | Supported policy schema/evaluator/capability versions and required obligations |
| Activation/deployment | Selected policy references and owner acceptance/activation receipts for the target |

This table is a documentation contract, not a new implemented manifest schema.
Do not prematurely write invented checksums, active policies or future source SHAs
into a definitive manifest. Policy support advertised by an artifact requires
actual qualification; an unrecognized version or missing required policy blocks
that component combination rather than being silently ignored.

The composition can distribute verified policy definitions/presets where their
owner contract allows it, but selection and activation use the owner's API and
appropriate authority. No executable policy scripts or hidden rule interpreter
are shipped as a side channel. Secrets remain in their secure product/host stores.

## Cross-repository release dependency example

For a Mission to make EP Execution Agents installable:

```text
EP Agent/protocol implementation -> qualified version/build/publication --+
                                                                      |
Forge Platform Agent-role installer support ----------------------------+
                                                                      v
                     final component manifest + policy compatibility
                                      -> installer qualification
```

Forge decides the Action graph. Independent producer and installer work may be
eligible in parallel; EP owns actual execution/leases/capacity. The final manifest
waits for actual qualified published Server/Agent artifacts and applicable policy
contracts, not merely a merged source PR or a version string. The same rule later
applies to Forge Server and Workspace Server/Client. Forge Platform does not
invent or enforce a competing execution DAG.

## One, two or three server roles and partial availability

EP-only, Forge+EP, Workspace+EP, all-server and remote-peer configurations remain
valid. Optional Workspace UI is not required for policy enforcement. A server can
operate under its approved local policy while an optional peer is absent.

Installation/update flow: select verified component combination -> verify
artifact/runtime/policy compatibility -> establish authorized pinned identity ->
prepare owner-specific settings/activation -> read owner receipts -> qualify the
actual installation. Discovery produces candidates only; it grants neither policy
activation nor execution authority. Existing trusted identity is not silently
replaced by a newly discovered endpoint.

Cross-product activation is not an atomic SQL transaction. A changeset records
prepared/accepted/active revisions per owner. Missing/incompatible acceptance
leaves the dependent composition visibly incomplete; it does not silently choose
a weaker profile. Unrelated components need not be stopped. Retry uses the same
operation identity and reconciles existing owner receipts.

Runtime policy remains product-owned after installation; the installer is not a
required long-running policy service. Workspace may show effective status through
owner APIs but is not required to keep the services functioning.

## Update, rollback and authority preservation

Before update, validate policy/schema/runtime compatibility and preserve the
product's grants, run lineage, consumed budgets, historical snapshots and instance
identity according to its migration contract. The installer invokes product-owned
migrations and quiescence, not direct SQL. Do not reset failed or exhausted runs
because a new artifact or default profile is installed.

A new default does not retroactively rewrite active or historical policy. Explicit
in-flight migration requires owner authority and requalification. Rollback is a
new auditable deployment/activation of compatible known content; it cannot revive
revoked permissions or restore already consumed allowances. Expiry, revocation
and emergency stops are checked at protected side-effect boundaries.

If a required owner or fresh authorization is unavailable, follow its documented
fail-closed rule. Offline artifact verification does not itself prove current
permission to deploy or activate a policy. Cached read models never become grant
writers. No protection bypass is implied by installation ownership.

## Roadmap and future acceptance

POL-P is the local policy-aware composition capability. It requires cross-product
POL-Q (effective-policy qualification) and VR-Q (qualified version/release evidence)
for the production installer flow that consumes these capabilities. Work on static
manifest/API design may proceed earlier; implementation completion cannot be
inferred from the documentary graph.

Future tests: wrong product/component/policy version; unpublished/changed artifact
under reused version; valid hash but wrong source/operation; absent owner acceptance;
partial activation/retry; stale permissions; downgrade incompatibility; no shared
SQL; no secret disclosure; 1/2/3-role deployments; budget/identity/history preservation;
no competing version allocation; actual installed artifact/receipt binding.

Existing #16/#17 and peer implementation PRs remain separate. Before their relevant
changes are merged, reconcile target semantics; documentation does not close code
review findings or issue a release approval. Full policy administration UI, full
network discovery and generic workflow editing do not become first-canary gates.
