# ADR-0006 — Installed servers, explicit discovery, and pairing

**Status:** Accepted

## Decision

Forge Server, EP Server and Workspace Server are independently installable, headless services. Each has a product-owned central runtime-storage root outside Git/source checkouts, a SQL database plus owned files/artifacts/logs/backups/cache, a stable installation identity, a versioned HTTP API over application services and a macOS launchd service contract. They may be co-located or distributed, but never share a database or use direct cross-product SQL.

Servers use the shared [instance discovery and pairing contract](../INSTANCE_DISCOVERY_AND_PAIRING_CONTRACT.md): DNS-SD/mDNS is a candidate locator; configured/unicast/tailnet endpoints are equivalent bootstrap routes; explicit authenticated pairing creates product-owned durable bindings. Discovery is not authorization and an existing binding cannot silently move to a new discovered instance.

Forge Platform owns component choice, verified artifact acquisition, installation/update/repair/uninstall, lifecycle choreography and discovery-driven topology bootstrap. It invokes each product's public API to pair/bind and never writes a product database. Its runtime is not needed after installation. Workspace Client and EP Project Agent remain independently installable local roles with separate client/session, agent/server and server-peer trust domains.

## Consequences

The installer can compose EP-only, Forge+EP, Workspace+EP, all-server and remote-peer deployments without inventing a shared control plane. Products must define their own storage migration/relocation, backup/recovery and pairing credentials. The first Forge→EP→Forge canary remains bounded to Forge/EP minimum service seams; Workspace UI and full installer/discovery productization are not predecessors.

