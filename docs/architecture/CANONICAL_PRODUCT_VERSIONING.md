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
- Current workflows are deliberately read-only guards. A protected
  version-preparation route must persist an operation ID, policy revision,
  event/lineage, expected head/baseline, requested and determined target, paths
  and resulting commit before it can enable allocation. Per-ref Actions
  concurrency and a commit subject are not that authority.
- A build reads the committed version and never allocates it. Publication binds
  approved exact source, target version, artifact bytes/digest and qualification;
  a repeated identity with different bytes is a conflict.

The policy governs Forge, Workspace and Forge Platform. Engineering Platform
uses the same event semantics with its richer multi-file package-version
projection. A Forge Platform release remains a separately qualified
composition of those independently versioned artifacts.
