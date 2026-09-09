# ADR-0006 — Installed servers, explicit discovery, and pairing

**Status:** Accepted

## Decision

Forge Server, EP Server and Workspace Server are independently installable, headless services. Each has a product-owned central runtime-storage root outside Git/source checkouts, a SQL database plus owned files/artifacts/logs/backups/cache, a stable installation identity, a versioned HTTP API over application services and a macOS launchd service contract. They may be co-located or distributed, but never share a database or use direct cross-product SQL.

On macOS, the server contract means a root-authorized system-domain `LaunchDaemon`, not a per-user `LaunchAgent`/`gui/<uid>` service. `launchd` is the system service manager; “system service but not launchd” is not a possible macOS implementation. EP Project Agent and interactive provider credentials remain user/host scoped and may not be absorbed by a server daemon. The [Universal macOS Installer contract](../UNIVERSAL_MACOS_INSTALLER_CONTRACT.md) defines how Forge Platform presents this product-owned contract without registering a service itself.

Servers use the shared [instance discovery and pairing contract](../INSTANCE_DISCOVERY_AND_PAIRING_CONTRACT.md): DNS-SD/mDNS is a candidate locator; configured/unicast/tailnet endpoints are equivalent bootstrap routes; explicit authenticated pairing creates product-owned durable bindings. Discovery is not authorization and an existing binding cannot silently move to a new discovered instance.

Forge Platform owns component choice, verified artifact acquisition, lifecycle choreography and discovery-driven topology bootstrap. It invokes each product's public API to pair/bind and never writes a product database. For Engineering Platform installation, update, repair, migration, runtime activation, verification and cleanup it invokes the EP-owned installation provisioner rather than reimplementing those transitions. Its runtime is not needed after installation. Workspace Client and EP Project Agent remain independently installable local roles with separate client/session, agent/server and server-peer trust domains.

## Consequences

The installer can compose EP-only, Forge+EP, Workspace+EP, all-server and remote-peer deployments without inventing a shared control plane or a second EP installation engine. Products must define their own storage migration/relocation, backup/recovery and pairing credentials. The first Forge→EP→Forge canary remains bounded to Forge/EP minimum service seams; Workspace UI and full installer/discovery productization are not predecessors.
