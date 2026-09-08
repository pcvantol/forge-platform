# Compatibility and release composition

Forge Platform owns cross-product compatibility declarations: Forge version, Workspace version, Engineering Platform version, Agent version, and supported protocol versions. Product repositories remain authoritative for their own protocol implementation and compatibility guarantees.

A Forge Platform release is a tested composition of independently versioned artifacts, not a source-monorepo release. A future release may pair one qualified Forge Runtime version with independently qualified Workspace and Engineering Platform versions. Product version mutation is governed by [Canonical product versioning](CANONICAL_PRODUCT_VERSIONING.md); compatibility declarations remain a separate, explicit composition decision.
