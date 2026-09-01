# ADR-0004 — Universal installer and independently published artifact composition

**Status:** Accepted

## Decision

Forge Platform installs and composes independently published Forge Runtime, Workspace Server, Workspace Client, Engineering Platform Server, and Engineering Platform Project Agent artifacts. It owns component selection, deployment presets, artifact acquisition and verification, validated compatibility/release composition, topology bootstrap, update, repair, uninstall, diagnostics, and receipts.

Each product repository owns its own artifact build/publication, version, product behavior, and protocol implementation. Forge Platform releases are tested compositions, not monorepo source versions. The installer provides independent Server and Local roles and the Complete Forge Platform, Server, Developer Workstation, and Custom conceptual presets.

## Consequences

Forge Platform will verify trusted artifact digest and supported signature/provenance evidence, use least privilege, and avoid repository secrets. It does not compile, repackage, or install product source as a hidden monolith. Concrete manifests, endpoints, privileged installation behavior, and platform-specific installers remain future work.
