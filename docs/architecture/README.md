# Architecture

Forge Platform is the distribution and deployment composition boundary for the Forge product family. It consumes published product artifacts; it does not rebuild product source or take ownership of product behavior. The complete system composition is defined in the [Forge Platform Architecture](FORGE_PLATFORM_ARCHITECTURE.md).

## Intended composition

| Product repository | Published conceptual artifact | Forge Platform responsibility |
| --- | --- | --- |
| `pcvantol/forge` | Forge Runtime | Select, verify, install, and compose |
| `pcvantol/workspace` | Workspace Server and Workspace Client | Select, verify, install, and compose |
| `pcvantol/engineering-platform` | Engineering Platform Server and EP Project Agent | Select, verify, install, and compose |

Each product retains ownership of its artifact build, protocol implementation, and product-specific compatibility guarantees. Forge Platform owns the validated cross-product release composition and compatibility declarations.

## Same-machine boundary

Components remain separately owned products even when installed on one machine. They communicate through their canonical APIs and protocols; no hidden in-process shortcut or direct repository-filesystem access is introduced. For example, Engineering Platform Server reaches a local EP Project Agent through the canonical agent protocol.

## Execution-lane boundary

Forge plans dependency DAGs; Engineering Platform Server remains the durable execution and admission authority. After `STANDALONE_EP_VERIFIED`, its first parallelism capability is bounded mutation across different repositories: an Agent may serve `0..N` repositories and advertise bounded capacity, while EP enforces one mutating lock/lease holder per repository, admission, backpressure, fairness, evidence, and finalization. Workspace only presents or issues permitted control intent. See the [system architecture](FORGE_PLATFORM_ARCHITECTURE.md), [ownership matrix](OWNERSHIP_MATRIX.md), and [MVP roadmap](../roadmap/MVP_1_0.md).

## Lifecycle boundary

The future platform manages install, role add/remove, upgrade, repair, uninstall, health diagnostics, and deployment receipts. Privileged installer logic is intentionally not implemented in this foundation.

Read the [system architecture](FORGE_PLATFORM_ARCHITECTURE.md), [governed knowledge learning loop](KNOWLEDGE_LEARNING_LOOP.md), [ADRs](adr/README.md), [cross-repository ownership matrix](OWNERSHIP_MATRIX.md), [component-manifest contract](COMPONENT_MANIFEST_CONTRACT.md), [compatibility model](COMPATIBILITY.md), [roles and presets](ROLES_AND_PRESETS.md), and [security boundary](SECURITY.md).
