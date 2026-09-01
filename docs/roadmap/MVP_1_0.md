# Forge Platform MVP 1.0

**Status:** canonical implementation-oriented roadmap; no capability is authorized for implementation by this document alone.

## Product definition

Forge Platform MVP 1.0 is a qualified, independently usable engineering-platform composition: a user can select a supported profile, install a compatible set of independently published Forge, Workspace, and Engineering Platform artifacts on a clean supported macOS machine, connect through canonical authenticated contracts, execute and observe governed engineering work for an attached project, and upgrade, diagnose, repair, or remove that composition with retained deployment and execution evidence.

It is not a source monorepo release and it does not turn Forge Platform into the owner of Forge planning, Workspace product UX, EP execution behavior, Project Agent behavior, TDE, or Knowledge Base behavior. The system architecture and ADRs remain the authority for those boundaries.

## Scope boundary

### In scope for MVP 1.0

- A versioned component-manifest and compatibility declaration for one qualified composition of the five defined installable components.
- Independently published, provenance-verifiable artifacts for Forge Runtime, Workspace Server, Workspace Client, Engineering Platform Server, and Engineering Platform Project Agent.
- A supported macOS complete and headless/server deployment path with explicit role selection, credentials, service registration, receipts, diagnostics, upgrade, repair, and uninstall.
- One coherent project flow: Forge-owned intent reaches EP through the versioned consumer contract; Workspace presents server-authoritative project state and permitted control intent; EP owns admission through finalization and evidence; the Agent owns the local repository/host edge.
- Durable EP execution semantics required for usable engineering work: project scoping, queue/admission, repository serialization, validation, PR/finalization observation, failure/recovery, and immutable execution evidence.
- Operational visibility sufficient to run the composition safely: component health/version, host/Agent availability, queue/run status, Prompt History and execution evidence, bounded logs, and provider/machine/model usage attribution where the provider exposes it.
- Security and qualification evidence: artifact digest/provenance checks, explicit authenticated consumers and Agents, no localhost or co-location bypass, least privilege, release-composition qualification, and TDE evidence where an applicable product contract exists.
- A documented, qualified transition from the historical DJConnect-hosted EP: the legacy-to-standalone transition is clean-slate, with a fresh official Schema 41 CENTRAL database, new standalone identities, and no legacy database migration. The explicitly retained legacy store is immutable forensic history only and never becomes standalone runtime authority.

### Explicitly post-MVP

- Windows/Linux installer support for Agents and Clients, and native installers beyond the supported macOS path.
- General distributed/team deployment: multi-host scheduling, automatic host assignment, cross-network recovery, and operational fleet management. The architecture already permits them; MVP does not claim them qualified.
- Same-repository parallel mutation with worktrees or declared disjoint scopes.
- Full mobile/remote Workspace experience, remote desktop control, and consumer UX breadth beyond the supported local/remote contract.
- Arbitrary remote-provider and local-model orchestration, automatic model optimization, pricing policy, or exact cost allocation. MVP requires honest attribution only where emitted.
- Knowledge Base productization, autonomous learning, KB installation as a component, or automatic promotion/self-modification.
- A generalized release-observatory product and family-wide rollout automation.

### Deferred architecture decisions

The following need later ADRs or versioned product contracts; they do not block defining MVP, but may block their own implementation wave: Workspace-to-local-Agent IPC, durable scheduling API, project-topology manifest schema, multi-host discovery, the precise legacy-EP forensic-retention contract, and the CENTRAL logical-identity versus physical-installation/host-identity decision required before standalone CENTRAL relocation is implemented.

## Capability map and dependency order

`Current maturity` is a repository-level assessment, not a claim that another product implementation has been requalified by this roadmap. `MVP blocker` means the capability must meet its target state before release.

| Wave / capability | Owner and likely repository | Purpose, current maturity, and MVP target | Dependencies | Acceptance and qualification evidence | MVP blocker |
| --- | --- | --- | --- | --- | --- |
| W0 `MVP-FOUND-001` Composition contract baseline | Forge Platform: architecture, schemas, governance | **Current:** architecture, roles, security principles, component-manifest concept, compatibility concept, AI projection, and TDE integration are documented. **Target:** versioned manifest/compatibility schemas and an auditable release-composition record with no ownership conflict. | Architecture/ADRs; product version and protocol declarations. | Schema and reference validation; signed-off ownership/compatibility review; manifest provenance record. | Yes |
| W0 `MVP-PROJ-001` Project and trust contract alignment | Forge, Workspace, EP; contract owners remain their product repositories | **Current:** logical/physical topology, authority, project identity, and no-bypass rules are canonical architecture. **Target:** versioned consumer, project-scope, Agent, and credential contracts that implement those rules without direct filesystem shortcuts. | `MVP-FOUND-001`; product-owned protocols. | Interoperability contract tests; negative auth/scope tests; topology and trust qualification. | Yes |
| W1 `MVP-ART-001` Published artifact readiness | Forge, Workspace, EP publish; Forge Platform consumes | **Current:** artifacts are conceptual; Forge Platform does not build them. **Target:** five versioned supported artifacts with digest, signature/provenance where supported, OS/architecture metadata, and release-channel identity. | `MVP-FOUND-001`; product packaging/release work. | Reproducible acquisition; digest/provenance verification; supported-platform artifact qualification. | Yes |
| W1 `MVP-COMP-001` Qualified release composition | Forge Platform | **Current:** composition is architecture-only. **Target:** one tested component set, protocol matrix, dependency resolution, and compatibility decision that can be consumed by installer lifecycle work. | `MVP-ART-001`; `MVP-PROJ-001`. | Manifest/matrix validation; end-to-end compatibility evidence; TDE evidence if supported. | Yes |
| W2 `MVP-EXEC-001` Governed engineering execution | Engineering Platform Server and Project Agent | **Current:** historical EP evidence describes mature repository-local execution semantics; standalone artifacts and cross-product qualification must not be inferred. **Target:** an installed EP Server/Agent pair executes a project-scoped Engineering Action through admission, durable queue/lease, provider invocation, validation, PR/finalization observation, receipt, and bounded recovery. | `MVP-PROJ-001`; `MVP-ART-001`. | Lifecycle, failure/recovery, locking, and evidence tests against installed artifacts; no direct server-repository access. | Yes |
| W2 `MVP-FORGE-001` Intent-to-execution integration | Forge Runtime with EP consumer contract | **Current:** Forge owns planning and dependencies; it is not execution authority. **Target:** a Forge engineering action carries immutable intent/provenance to EP and reads execution evidence without rewriting EP lifecycle state. | `MVP-PROJ-001`; `MVP-EXEC-001`. | Contract and provenance tests; forbidden-authority negative tests; observed completion/blocked paths. | Yes |
| W2 `MVP-WORK-001` Shared Workspace interaction | Workspace Server and Workspace Client | **Current:** Workspace boundary is canonical, but product integration maturity is not established here. **Target:** a user can view server-authoritative project/run state and issue permitted control intent without the client becoming authority or directly executing work. | `MVP-PROJ-001`; `MVP-EXEC-001`; `MVP-FORGE-001`. | Multi-client state/permission tests; remote-action and local-Agent boundary tests. | Yes |
| W3 `MVP-OPS-001` Operations, evidence, and honest usage | EP primarily; Workspace projects; Forge Platform qualifies composition | **Current:** historical EP material documents bounded status, logs, Prompt History, receipts, and Codex usage semantics. **Target:** qualified views for health, version, queue/run state, Agent availability, logs/evidence, and provider/model/host usage; unavailable measures remain explicitly unavailable. | W2 integration; provider telemetry contract. | Redaction/privacy tests; evidence and availability tests; provider attribution fixtures; no fabricated cost/token assertions. | Yes |
| W3 `MVP-REC-001` Persistence, backup, and recovery | EP and product storage contracts; Forge Platform validates deployment lifecycle | **Current:** clean-store and transactional-recovery principles exist in historical EP evidence. **Target:** durable supported-store lifecycle, backup/restore and upgrade recovery for the installed composition, with one writable authority. | `MVP-EXEC-001`; product storage migration contract. | Restart/interruption, backup/restore, upgrade/rollback-or-fail-safe evidence; forensic legacy-store disposition. | Yes |
| W4 `MVP-INST-001` macOS installation lifecycle | Forge Platform, consuming product artifacts | **Current:** no universal installer implementation. **Target:** clean-machine macOS Complete, Server/headless, Developer Workstation, and Custom role flows; verification, credentials, explicit service registration, receipts, upgrade, repair, and uninstall. | W0–W3; `MVP-COMP-001`. | Clean-install and repeatability tests; upgrade/repair/uninstall tests; least-privilege/security review; receipts and diagnostics. | Yes |
| W4 `MVP-MIG-001` Historical EP transition qualification | EP owns product migration; Forge Platform owns composed-install disposition | **Current:** DJConnect records clean-slate extraction and forensic-retention decisions; it is not a production migration authorization. **Target:** a qualified legacy-to-standalone clean-install/re-registration runbook: fresh official Schema 41 CENTRAL database, no legacy database migration, retained legacy store as immutable forensic evidence only, and no legacy runtime authority. | `MVP-REC-001`; `MVP-INST-001`; EP-owned contract. | Executed non-production clean-host qualification; legacy-store fingerprint/integrity evidence; fresh-store and new-registration evidence; recovery evidence; migration decision record; documented operator path. | Yes |
| K1–K4 `MVP-KNOW-001` Governed knowledge consumption boundary | Knowledge Base, Forge, EP/TDE evidence producers | **Current:** KB is a Git-backed CLI; governed observation/certification and read-only consumption are architecture-defined. **Target:** no mandatory runtime dependency for MVP; if evidence is used, it is traceable, read-only, and independently certified. | Knowledge-loop architecture; explicit producer contracts. | Boundary review; provenance tests for any adopted evidence. | No |
| P0 `POST-VERIFY-EP-RELOC-001` Standalone CENTRAL relocation | Engineering Platform owns relocation/export-import and lifecycle semantics; Forge Platform supplies only qualified installer/composition UX and orchestration | **Current:** not implemented or qualified. **Target:** after `STANDALONE_EP_VERIFIED`, EP can support a controlled relocation of an existing standalone CENTRAL to another host (first concrete case: MacBook to Mac mini), preserving supported operational CENTRAL history while establishing a new physical installation/host binding. | `STANDALONE_EP_VERIFIED`; EP-owned relocation contract; clean target-host Server install; explicit logical-CENTRAL versus physical-installation/host identity decision. | EP-owned export/import, quiescence, integrity, compatibility, restore, health, Agent rebind/re-pair/credential-rotation, old-host retirement, and end-to-end qualification evidence. | No — it does not block the B7/B8/B9 path or initial standalone verification; it must qualify before a permanent Mac mini CENTRAL deployment. |
| P1 `POST-DIST-001` Distributed/team execution | EP, Workspace, Forge; Forge Platform deployment qualification | Multi-host capacity, assignment, disconnect handling, and team fleet operations after a single supported topology qualifies. | W4 stable composition; deferred discovery/scheduling contracts. | Multi-host recovery and concurrency qualification. | No |

## Critical path

```text
W0 contracts and trust
  → W1 publishable artifacts + qualified composition
    → W2 EP execution + Forge/Workspace integration
      → W3 operations, persistence, recovery
        → W4 clean installation lifecycle + historical-EP transition
          → evidence-based MVP 1.0 release gate
```

Knowledge integration may progress in parallel only as an additive, read-only governed capability. Distributed/team work, additional platforms, and provider expansion follow MVP rather than delay the first coherent composition.

## Post-verification CENTRAL relocation

`POST-VERIFY-EP-RELOC-001` is deliberately distinct from `MVP-MIG-001`:

```text
Historical legacy EP → standalone CENTRAL
  clean-slate transition; fresh official Schema 41 CENTRAL DB
  no legacy DB migration

Existing standalone CENTRAL → another host
  later supported EP Server/CENTRAL relocation
  operational history may be preserved under the EP-owned contract
```

The sequencing is: B7 clean-host retirement, B7A/B7B standalone Server and Agent installation, B8 pairing/attachment, B9 first governed execution, then `STANDALONE_EP_VERIFIED`. Only after that milestone may the relocation capability be implemented and qualified. It may proceed alongside later Forge/Workspace work, but it must be qualified before using a Mac mini as the permanent CENTRAL host. It does not reopen or block the current B7/B8/B9 critical path.

Engineering Platform owns the relocation engine and its product semantics: admission quiescence, integrity checks, a consistent snapshot and manifest/checksums, compatibility validation, restore/import, new-host binding, health/qualification, and controlled retirement of the old installation. Forge Platform may present an installer choice such as **new CENTRAL** or **restore/relocate existing CENTRAL**, validate a qualified composition, and orchestrate calls to EP's published contract. It must not implement or own database migration, snapshot, restore, trust, or recovery semantics.

Before implementation, EP must explicitly decide whether a logical CENTRAL identity is portable while a physical Server installation/host identity is newly issued. The roadmap does not prejudge that decision. The relocation contract must also define the EP-owned Agent endpoint/trust transition: authenticated rebind or re-pair as appropriate, credential rotation/re-provisioning where required, and rejection of stale old-server trust.

### Relocation acceptance and qualification evidence

- A controlled source quiescence proof: no new work is admitted after the relocation boundary and in-flight work is resolved or represented by EP-defined recovery semantics.
- Source integrity, snapshot consistency, manifest, checksum, supported schema/version compatibility, and import/restore verification evidence.
- A clean target-host Server installation and a qualification record that distinguishes retained portable CENTRAL history from newly established host/install state.
- Health, durable-history, execution-evidence, restart, and bounded rollback-or-fail-safe qualification on the target before the source is retired.
- Agent endpoint/trust transition evidence, including the chosen rebind or re-pair flow, credential rotation where applicable, and negative proof that old credentials/endpoints do not remain silently trusted.
- An auditable old-host retirement record and a retained relocation receipt that identifies source, target, artifact/version compatibility, and outcome without exposing secrets.

### Relocation non-goals

- It is not a legacy EP-to-standalone migration and may not seed a standalone CENTRAL from the historical legacy database.
- It does not blindly copy machine-specific launchd state, PIDs, locks, sockets, caches, absolute host paths, host diagnostics, or other host-local runtime state.
- It does not clone Agent host identities or assume localhost/co-location bypasses endpoint or trust changes.
- It does not make Forge Platform the owner of an EP migration engine, CENTRAL database semantics, Agent credentials, or recovery policy.
- It does not authorize a permanent Mac mini deployment before the EP-owned contract and qualification evidence exist.

## MVP 1.0 release gate

Release requires a retained qualification bundle, not a subjective readiness statement. Every gate below must be `PASS`, or have an explicitly accepted non-blocking exception that does not weaken a listed MVP invariant.

| Gate | Required evidence |
| --- | --- |
| Architecture and ownership | Current architecture/ADRs, ownership matrix, and this roadmap agree; no unresolved critical authority or trust ambiguity. |
| Functional composition | Qualified manifest installs exact artifact versions; Forge→EP action, Workspace visibility/control, and Agent-host execution work through canonical contracts. |
| Reliability and recovery | Queue/lease serialization, provider interruption, restart, failure, validation, finalization, backup/restore, and recovery paths are exercised with durable evidence. |
| Security and supply chain | Trusted source/channel, digest and supported provenance/signature verification, explicit service registration, least privilege, credential isolation, redaction, and negative trust-boundary tests pass. |
| Installation lifecycle | Clean macOS installation for supported profiles, repeatable configuration, compatibility rejection, upgrade, repair, uninstall, diagnostics, and deployment receipts pass. |
| Observability | Component health/version, queues/runs, bounded logs, Prompt History/evidence, and truthful provider/host/model attribution are available; unavailable data is not fabricated. |
| Qualification and TDE | Contract, integration, security, and installer evidence is retained; applicable standalone TDE validation is linked without copying TDE authority. |
| Documentation and operations | Bootstrap, supported topology, credential/service operation, recovery, upgrade, and operator runbooks are discoverable from this repository. |
| Historical transition | EP has a qualified clean-slate legacy-to-standalone disposition: a fresh Schema 41 CENTRAL store, new registrations, preserved forensic legacy evidence, and no live legacy authority. A later standalone-to-standalone relocation, if used, follows the separately qualified EP-owned relocation contract. |

## Interpretation rules

Roadmap status does not certify an external repository or authorize production work. A capability becomes current only through its owning repository's governed implementation and evidence, then through Forge Platform composition qualification. Production action for this roadmap consolidation is **NONE**.
