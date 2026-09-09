# ADR-0004 — Universal installer and independently published artifact composition

**Status:** Accepted

## Decision

Forge Platform composes independently published Forge Runtime, Workspace Server, Workspace Client, Engineering Platform Server, and Engineering Platform Project Agent artifacts. It owns component selection, deployment presets, artifact acquisition and verification, validated compatibility/release composition, topology bootstrap, lifecycle choreography, and composition receipts.

Each product repository owns its own artifact build/publication, version, product behavior, protocol implementation, and product-specific installation provisioner. Forge Platform releases are tested compositions, not monorepo source versions. The installer provides independent Server and Local roles and the Complete Forge Platform, Server, Developer Workstation, and Custom conceptual presets.

For Engineering Platform, Forge Platform passes the exact selected artifact identity and requested role to the EP-owned installation provisioner and consumes its resulting installation record, health proof, and cleanup receipt. It must not create a second EP runtime chooser, service-registration path, migration engine, cleanup engine, or direct database writer. In particular, a Forge Platform PATH lookup is diagnostic evidence only and cannot select an EP operational runtime.

## Consequences

Forge Platform will verify trusted artifact digest and supported signature/provenance evidence, use least privilege, and avoid repository secrets. It does not compile, repackage, or install product source as a hidden monolith. The source-level component-operation delegation kernel binds an exact qualified artifact to a product-owned operation and preserves its receipt. Durable operation storage, inter-process locking, concrete product endpoints, privileged installation behavior, and platform-specific installers remain future work.
