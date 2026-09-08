# Canonical product versioning

**Status:** Adopted cross-product policy v1

Forge Platform owns this policy as the composition authority. Each product
repository remains authoritative for its own committed `product-version.json`;
Forge Platform does not rewrite another product's version.

Every product begins with the stable SemVer baseline `0.1.0`. The product-local
`scripts/advance_product_version.py` validates the only version source and is
the only CI mutation mechanism.

- The first non-bot push to a non-`main`, non-`release-*` branch creates one
  patch bump commit.
- Every non-bot push to `main` creates one minor bump commit and resets patch
  to zero.
- Writes are serialized per Git ref. The bot never writes a protected branch
  unless repository policy explicitly permits its scoped `contents: write`
  token; denial fails visibly.
- The versioning workflow validates the resulting manifest before it commits.
  It does not publish, tag, deploy, or alter compatibility declarations.

The policy governs Forge, Workspace and Forge Platform. Engineering Platform
uses the same event semantics with its richer multi-file package-version
projection. A Forge Platform release remains a separately qualified
composition of those independently versioned artifacts.
