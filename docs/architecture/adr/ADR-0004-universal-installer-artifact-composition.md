# ADR-0004 — Universal installer and independently published artifact composition

**Status:** Accepted

## Decision

Forge Platform composes independently published Forge Runtime, Workspace Server, Workspace Client, Engineering Platform Server, and Engineering Platform Project Agent artifacts. It owns component selection, deployment presets, artifact acquisition and verification, validated compatibility/release composition, topology bootstrap, lifecycle choreography, and composition receipts.

Each product repository owns its own artifact build/publication, version, product behavior, protocol implementation, and product-specific installation provisioner. Forge Platform releases are tested compositions, not monorepo source versions. The installer provides independent Server and Local roles and the Complete Forge Platform, Server, Developer Workstation, and Custom conceptual presets.

For Engineering Platform, Forge Platform passes the complete exact selected
artifact identity and requested role to the EP-owned installation provisioner
adapter and consumes its correlated installation readback, candidate update
assessment, health proof, and cleanup receipt. The EP resolver alone selects
the runtime, executable, server, and instance and determines machine-wide
inventory/conflict coverage. Forge Platform must not create a second EP
runtime chooser, service-registration path, migration engine, cleanup engine,
or direct database writer. In particular, a Forge Platform PATH lookup or an
HTTP-reachable response cannot select or verify an EP operational runtime.

## Consequences

Forge Platform will verify trusted artifact digest and supported signature/provenance evidence, use least privilege, and avoid repository secrets. It does not compile, repackage, or install product source as a hidden monolith. The source-level component-operation consumer contract binds an exact qualified artifact (including source locator) to product readback, update assessment, execute, and resume receipts; it retains non-secret preflight/postflight and pending-recovery evidence. A local target-dispatch lock prevents duplicate Forge Platform dispatch only. It does not replace the product installation lock or prove cross-account/machine uniqueness.

No concrete EP adapter endpoint, privileged installation behavior, artifact download, service action, migration, rollback, cleanup, or platform-specific installer is introduced by this decision. Those remain future work under the owning product contract; a future adapter must preserve the same product-operation identity through crash/reboot resume.
