# Canonical product versioning

**Status:** Adopted cross-product policy v1

Forge Platform owns this policy as the composition authority. Each product
repository remains authoritative for its own committed `product-version.json`;
Forge Platform does not rewrite another product's version.

The approved implementation baseline for the four repositories is `2.3.0`;
it is not evidence that any product was published. Each product can advance
independently. The product-local helper validates its only version source and
can apply an explicit patch/minor or exact release target with a stale-baseline
guard; it never decides compatibility, publication, or a major release.

- First qualifying feature-branch lineage events are allocated one patch, and
  qualifying non-versioning main source events one minor with patch reset.
  `release-X.Y.Z` is an explicit exact target; major requires an explicit
  applicable release/architecture decision. Candidate numbering is not a
  compatibility or release-GO decision.
- The current workflow is deliberately a read-only guard. A protected delivery
  route invokes `scripts/advance_product_version.py --plan` and then `--apply`
  with an explicit operation ID, event lineage and expected source HEAD. Apply
  persists a repository-local operation receipt with policy revision, baseline,
  target, allowed projection path and before/after manifest digests before a
  delivery commit is made. The same ID and inputs recover the same target;
  changed inputs conflict; a new operation at a stale HEAD fails closed.
  The receipt and the one changed projection must be committed together and the
  resulting commit recorded by the authorized delivery system once available.
  Per-ref Actions concurrency and a commit subject are not that authority.
- A build reads the committed version and never allocates it. Publication binds
  approved exact source, target version, artifact bytes/digest and qualification;
  a repeated identity with different bytes is a conflict.

The policy governs Forge, Workspace and Forge Platform. Engineering Platform
uses the same event semantics with its richer multi-file package-version
projection. A Forge Platform release remains a separately qualified
composition of those independently versioned artifacts.

`--check` and `--plan` write nothing. `--apply` is interruption-safe only at
the per-file level: it records the allocation before atomically replacing the
single manifest, so a retry can complete or refuse the same operation without
allocating another version. It is not a multi-file Git transaction and it never
pushes, publishes, or turns a candidate number into release approval.

Engineering Platform PR [#105](https://github.com/pcvantol/engineering-platform/pull/105)
is the pending source-level bounded adapter for product-owned prepared
operations. It verifies declared helper identity, an isolated allowlisted
candidate and exact-head qualification evidence. It does not establish an
installed writer, an active authorization grant, merge authority, artifact
publication or universal-installer readiness.

## Candidate qualification and release boundary

This repository has protected-main pull-request gates but no authorized release
delivery API, GitHub App, or publication route. A delivery operator therefore
creates a dedicated version-preparation candidate from the recorded expected
source revision, commits only `product-version.json` and its receipt, and opens
that candidate for the ordinary protected route. The canonical-version workflow
checks out the exact PR head (never GitHub's synthetic merge ref) and runs
`--verify-operation --candidate-head <sha>`. It rejects a receipt whose parent,
projection digest, target, or changed paths differ. Thus the new candidate gets
its own qualification evidence; an older review/check cannot be repurposed.

`release-X.Y.Z` is parsed only as an explicit exact target by the helper; it is
not a branch authorization. No release workflow is configured here. Until an
authorized route can bind an approved exact candidate, compatibility decision,
artifact bytes/digest and publication identity, release preparation and
publication remain unsupported and fail closed by absence rather than a bypass.
