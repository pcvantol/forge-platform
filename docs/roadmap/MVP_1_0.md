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
- A first real two-project qualification after B8: DJConnect and the Engineering Platform source checkout are independently attached development projects at the same CENTRAL/Project Agent. This is a live multi-project data and Operations Console qualification, not EP self-hosting and not a disposable fixture.

### Explicitly post-MVP

- Windows/Linux installer support for Agents and Clients, and native installers beyond the supported macOS path.
- General distributed/team deployment: multi-host scheduling, automatic host assignment, cross-network recovery, and operational fleet management. The architecture already permits them; MVP does not claim them qualified.
- Multi-repository parallel mutating execution. This is a bounded post-`STANDALONE_EP_VERIFIED` Engineering Platform capability; it does not block MVP, B8 pairing/attachment, B9 first governed execution, or initial standalone verification.
- EP self-hosted execution. It is a separately qualified post-`STANDALONE_EP_VERIFIED` capability; it is neither exercised nor implied by B8C or B9.
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
| B8C `MULTI_PROJECT_CONSOLE_QUALIFIED` First real multi-project qualification | Engineering Platform Server/Operations Console and Project Agent; Forge Platform records composed evidence | **Target:** immediately after B8, attach `djconnect` and the `engineering-platform` development checkout as two first-class projects to the same CENTRAL/Agent. The latter uses its portable `.engineering-platform/repository.json`; it remains a development/source project while the installed EP artifact remains runtime authority. | B8 pairing and first DJConnect attachment; installed EP artifacts. | Project-selector/pulldown, `project_id` scoping, project-isolated queue/runs/reports/Prompt History/evidence/status, installation-wide versus project-scoped views, refresh/deep-link/selection behavior, and fail-closed cross-project-leakage negatives. | Yes for B9 / `STANDALONE_EP_VERIFIED`; it does not execute EP against its own source checkout. |
| B9 `STANDALONE_EP_VERIFIED` First governed end-to-end execution | Engineering Platform Server and Project Agent; DJConnect is the first execution target | **Target:** the first governed standalone execution follows CENTRAL → Project Agent → DJConnect isolated worktree → provider/Codex → validation/qualification/evidence/finalization. | `MULTI_PROJECT_CONSOLE_QUALIFIED`; installed EP artifacts; DJConnect attachment. | Retained end-to-end receipt and qualification bundle proving the full path, authority boundaries, isolated-worktree handling, and successful finalization. | Yes; success establishes `STANDALONE_EP_VERIFIED`. |
| F0 `EP_EXTRACTION_CUTOVER_COMPLETE` DJConnect EP extraction cutover/finalization | DJConnect owns removal from its repository; Engineering Platform owns the retained installed product/runtime; Forge Platform records boundary evidence | **Target:** only after `STANDALONE_EP_VERIFIED`, remove or retire every active generic EP product/runtime/source duplicate from DJConnect while retaining explicitly protected consumer declarations and historical evidence. | `STANDALONE_EP_VERIFIED`; DJConnect-governed cleanup plan and zero-live-duplicate audit. | Audit proves generic live EP implementation, runtime authority, and duplicated EP product semantics in DJConnect each equal zero; protected evidence and consumer material remain intact. | Yes for declaring extraction cutover complete; it does not retroactively alter B8C or B9 evidence. |
| S0 `EP_SELF_HOSTING_QUALIFIED` Separate EP self-hosting qualification | Engineering Platform | **Target:** an installed EP artifact executes governed development work for the Engineering Platform source project under the published contracts. | `STANDALONE_EP_VERIFIED`; separate EP-owned self-hosting plan and safeguards. | Dedicated self-hosting qualification and evidence; no source-checkout runtime authority. | No — separate from B8C/B9 and may not be inferred from their success. |
| K1–K4 `MVP-KNOW-001` Governed knowledge consumption boundary | Knowledge Base, Forge, EP/TDE evidence producers | **Current:** KB is a Git-backed CLI; governed observation/certification and read-only consumption are architecture-defined. **Target:** no mandatory runtime dependency for MVP; if evidence is used, it is traceable, read-only, and independently certified. | Knowledge-loop architecture; explicit producer contracts. | Boundary review; provenance tests for any adopted evidence. | No |
| P0 `POST-VERIFY-EP-RELOC-001` Standalone CENTRAL relocation | Engineering Platform owns relocation/export-import and lifecycle semantics; Forge Platform supplies only qualified installer/composition UX and orchestration | **Current:** not implemented or qualified. **Target:** after `STANDALONE_EP_VERIFIED`, EP can support a controlled relocation of an existing standalone CENTRAL to another host (first concrete case: MacBook to Mac mini), preserving supported operational CENTRAL history while establishing a new physical installation/host binding. | `STANDALONE_EP_VERIFIED`; EP-owned relocation contract; clean target-host Server install; explicit logical-CENTRAL versus physical-installation/host identity decision. | EP-owned export/import, quiescence, integrity, compatibility, restore, health, Agent rebind/re-pair/credential-rotation, old-host retirement, and end-to-end qualification evidence. | No — it does not block the B7/B8/B9 path or initial standalone verification; it must qualify before a permanent Mac mini CENTRAL deployment. |
| P1 `POST-VERIFY-PAR-001` Multi-execution runtime foundation | Engineering Platform | **Current:** no post-standalone parallel qualification is claimed. **Target:** after standalone verification, EP has durable, lane-isolated execution state that can represent more than one active execution without cross-lane evidence, validation, or finalization ambiguity. | `STANDALONE_EP_VERIFIED`; EP-owned durable execution contract. | Concurrent-lane lifecycle, restart/recovery, evidence isolation, and negative duplicate-finalization qualification. | No — starts only after standalone verification and does not block B8/B9. |
| P2 `POST-VERIFY-PAR-002` Repository lock/lease admission | Engineering Platform | **Target:** EP uses one durable repository lock/lease per mutating repository as the resource-exclusion boundary. A lane targeting multiple repositories atomically obtains every required lease before mutation; distinct repositories remain independently lockable. | `POST-VERIFY-PAR-001`; versioned EP admission/lease contract. | Contention, lease renewal/expiry/recovery, multi-repository acquisition, no-double-writer, and dependency-versus-resource-exclusion qualification. | No — post-verification only. |
| P3 `POST-VERIFY-PAR-003` Agent execution slots and capacity | Engineering Platform Project Agent and Server | **Target:** an Agent serving `0..N` repositories per Host/OS-user context advertises bounded capacity such as `max_parallel_executions`/slots; EP matches host/capability, capacity, dependencies, and leases, then applies admission, backpressure, and fairness. | `POST-VERIFY-PAR-002`; versioned Agent capability contract. | Capacity advertisement/reconciliation, eligible-host matching, saturation/backpressure, fairness, Agent disconnect, and no-self-admission qualification. | No — post-verification only. |
| P4 `MULTI_REPOSITORY_PARALLEL_EXECUTION_VERIFIED` Installed-Codex multi-repository parallel qualification | Engineering Platform; Forge/Workspace as contract consumers; Forge Platform qualifies only the supported composition | **Target:** a qualified installed-Codex run performs independent mutating lanes in parallel across different repositories while Forge-provided dependencies still sequence dependent work. EP remains execution/admission/durable-state authority; Workspace remains presentation/permitted control only. | P1–P3; qualified installed artifacts and test repositories. | Retained end-to-end qualification bundle proving parallel independent execution, one mutating lane per repository, dependency sequencing, capacity/backpressure, failure recovery, isolated evidence/validation/finalization, and authority-boundary negative tests. | No — it follows `STANDALONE_EP_VERIFIED` and does not delay the B8/B9 critical path. |
| P5 `POST-DIST-001` Distributed/team execution | EP, Workspace, Forge; Forge Platform deployment qualification | Multi-host capacity, assignment, disconnect handling, and team fleet operations after a single supported topology and bounded multi-repository parallel execution qualify. | W4 stable composition; `MULTI_REPOSITORY_PARALLEL_EXECUTION_VERIFIED`; deferred discovery/scheduling contracts. | Multi-host recovery and concurrency qualification. | No |

## Critical path

The roadmap has two prerequisite chains that join at the MVP release decision. The composition chain proves that a supported installed-artifact product exists. The standalone-transition chain proves that the historical DJConnect-hosted implementation has been replaced without leaving a second live generic EP authority. Neither chain can substitute for the other.

```text
COMPOSITION PREREQUISITES                         STANDALONE-TRANSITION PREREQUISITES
W0 contracts/trust                                B7 clean-host retirement
  → W1 artifacts + qualified composition            → B7A/B7B installed standalone Server + Agent
    → W2 execution + consumer integration              → B8_PASS: DJConnect paired and attached
      → W3 operations/persistence/recovery                → B8C_PASS: two real development projects isolated
        → W4 installation + clean-slate transition           → B9_PASS: governed DJConnect execution finalized
                                                               → STANDALONE_EP_VERIFIED
                                                                 → CUTOVER_PASS: zero-live-duplicate audit
                                                                   → EP_EXTRACTION_CUTOVER_COMPLETE

W4 + EP_EXTRACTION_CUTOVER_COMPLETE
  → MVP_1_0_RELEASE_READY
    → evidence-based MVP 1.0 release gate
```

`B8_PASS` is limited to authenticated pairing plus DJConnect attachment; it does not prove multi-project correctness. `B8C_PASS` deliberately uses two actual repositories, not a disposable fixture, and is a hard admission prerequisite for B9. `B9_PASS` requires a successful full DJConnect lifecycle, not merely provider activity or a created worktree. `STANDALONE_EP_VERIFIED` exists only when both B8C and B9 have passed with retained evidence. In every stage, source checkouts develop, test, and build, while the installed EP artifact is runtime authority.

`CUTOVER_PASS` is intentionally narrower and harder than a documentation review: the DJConnect zero-live-duplicate audit must pass while protected historical evidence remains. `EP_EXTRACTION_CUTOVER_COMPLETE` is therefore a prerequisite to `MVP_1_0_RELEASE_READY`, not an optional later tidying activity.

Knowledge integration may progress in parallel only as an additive, read-only governed capability. After `STANDALONE_EP_VERIFIED`, CENTRAL relocation, multi-repository parallel execution, and separately scoped EP self-hosting may also progress in parallel with the DJConnect cutover where their repository and change controls allow it. None weakens, substitutes for, or broadens the cutover's zero-live-duplicate audit; `EP_EXTRACTION_CUTOVER_COMPLETE` remains an independent finalization gate.

## B8C multi-project Operations Console qualification

`MULTI_PROJECT_CONSOLE_QUALIFIED` is a required live qualification between B8 and B9. The same Project Agent attaches both `djconnect` and the Engineering Platform development checkout to CENTRAL. The Engineering Platform checkout is declared through its portable `.engineering-platform/repository.json`, but it neither supplies Server modules nor runs the Server/Agent from source. B8C performs no self-hosted execution.

The retained qualification bundle must prove all of the following:

- The project selector/pulldown exposes DJConnect and Engineering Platform as two distinct first-class projects and preserves an unambiguous selected project.
- Every project-scoped queue, run, report, Prompt History entry, evidence item, and status result is constrained by `project_id`; selecting or querying project A cannot expose rows from project B.
- Installation-wide diagnostics remain installation-wide and are not falsely presented as project-scoped data.
- Browser refresh, direct/deep links, selector changes, and restored selection retain or safely re-establish project context without stale cross-project display.
- Positive isolation and negative leakage tests fail closed: a missing, stale, forged, or mismatched project context returns no other project's data and cannot be repaired by client-side filtering alone.

## DJConnect EP extraction cutover/finalization

The cleanup begins only after B9 succeeds and establishes `STANDALONE_EP_VERIFIED`. It is a DJConnect-governed documentation/change program, not permission for Forge Platform to modify DJConnect here. Its end gate is a **zero-live-duplicate audit**:

```text
generic live EP implementation in DJConnect = 0
generic live EP runtime authority in DJConnect = 0
duplicated generic EP product semantics in DJConnect = 0
historical evidence retained under preservation policy
```

The audit removes or retires all active generic EP product/runtime/source duplicates that are obsolete after extraction, including old `tools/engineering` implementation, dashboard/watcher/Local API/runtime code, service/install/launchd tooling, EP-specific CI workflows, bootstrap/repair/migration runtime, duplicated tests, current documentation, and authority assumptions. It must retain `.engineering-platform/repository.json`; necessary DJConnect-specific consumer adapters that use the installed EP interface; immutable historical prompts, receipts, and provenance; the legacy database as `HISTORY_ONLY` under the preservation policy; and migration/extraction evidence. The gate is not "no EP string remains in DJConnect" and must not destroy history to make an audit pass.

## Post-standalone self-hosting

`EP_SELF_HOSTING_QUALIFIED` is a distinct post-`STANDALONE_EP_VERIFIED` lane. It may demonstrate the installed EP artifact governing development work in the Engineering Platform source project, but cannot be merged into B8C (attachment/data-isolation qualification) or B9 (first governed DJConnect execution). Its qualification must preserve the installed-artifact runtime boundary and is neither a prerequisite nor substitute for `EP_EXTRACTION_CUTOVER_COMPLETE`.

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

The sequencing is: B7 clean-host retirement, B7A/B7B standalone Server and Agent installation, B8 pairing/attachment, B8C real two-project qualification, B9 first governed execution, then `STANDALONE_EP_VERIFIED`. Only after that milestone may the relocation capability be implemented and qualified. It may proceed alongside the DJConnect extraction cutover, self-hosting, and later Forge/Workspace work, but it must be qualified before using a Mac mini as the permanent CENTRAL host. It does not reopen or block the B8C/B9 critical path or satisfy the cutover audit.

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

## Post-verification multi-repository parallel lane execution

`MULTI_REPOSITORY_PARALLEL_EXECUTION_VERIFIED` is a deliberately bounded acceleration path, not a redefinition of product ownership. It begins only after B7 clean-host retirement, B7A/B7B standalone Server and Agent installation, B8 pairing/attachment, B8C real two-project qualification, B9 first governed execution, and `STANDALONE_EP_VERIFIED`. It may proceed alongside the separately scoped CENTRAL-relocation, DJConnect cutover, and self-hosting lanes, but none reopens or blocks the B8C/B9 critical path or softens the cutover end criterion.

```text
P1 durable multi-execution foundation
  → P2 repository lock/lease admission
    → P3 Agent slots/capacity and EP admission
      → P4 installed-Codex qualification
        → MULTI_REPOSITORY_PARALLEL_EXECUTION_VERIFIED
```

The P4 outcome is parallel mutation over different repositories only. It gives a direct path to accelerate independent work across Forge, Workspace, Engineering Platform, Forge Platform, and other autonomous repositories. Forge can nevertheless require sequence A → B between different repositories through its DAG/dependency plan. Forge plans that graph and intent; it never becomes an execution, lock, slot, queue, evidence, or finalization authority.

### Admission and backpressure semantics

- EP Server is the sole execution, admission, and durable-state authority. It evaluates dependencies, repository lease availability, Agent/Host capability matching, advertised bounded execution slots, and its fairness policy before admitting a lane.
- A Project Agent may serve `0..N` repositories in one Host/OS-user context and advertises bounded capacity such as `max_parallel_executions`. An advertised free slot is not permission to start work; only an EP admission creates an executable lane.
- A mutating lane holds an EP-managed lock/lease for every repository it will mutate. No second mutating lane may be admitted for a leased repository. Different repositories may run concurrently only when all dependencies are satisfied and every target lease and required capacity are available.
- When a required lease, eligible Agent, capability, or slot is unavailable, EP retains the lane in durable queued/blocked state and applies bounded backpressure and fairness rather than bypassing an existing lane or overcommitting an Agent. A dependent lane remains unadmitted until its planned predecessors complete under EP-defined success semantics.
- On Agent disconnect, capacity reduction, lease-renewal failure, provider interruption, validation failure, or finalization uncertainty, EP records lane-scoped durable state and uses its bounded recovery policy. It must not silently duplicate a mutation, transfer a live lease, reuse stale capacity, or finalize one lane using another lane's evidence. Lease recovery may admit a replacement only after EP has established that the prior holder can no longer mutate under the published contract.
- Workspace may display queue, capacity, blocked, failure, and finalization state and issue only permitted control intent through canonical APIs. It does not grant leases, allocate slots, override backpressure, or execute work through an Agent.

### Acceptance criteria and qualification evidence

- An installed EP Server/Project Agent composition executes at least two independent mutating lanes concurrently against different attached repositories, with a retained receipt for each lane.
- A contention test proves that two mutating lanes targeting one repository cannot execute concurrently, including when the lanes originate from different Forge-planned actions or Agents.
- A dependency test proves that different repositories remain sequenced when Forge declares a dependency, while an independent repository can proceed in parallel.
- Capacity tests prove that `max_parallel_executions`/slots are advertised and respected, saturation is durably queued or blocked, and EP applies its configured fairness/backpressure policy without Agent self-admission.
- Failure/recovery tests cover Agent loss, expired or failed lease renewal, provider interruption, validation failure, and finalization interruption, with no duplicate mutation, stale lease, evidence crossover, or unsafe automatic reassignment.
- Host/capability tests prove that EP selects only eligible attached repositories and Agents. Authority-boundary negative tests prove Forge cannot admit/lock/finalize and Workspace cannot allocate/override/directly execute.
- The qualification bundle records exact installed artifact versions, topology, capability advertisements, dependency plan, lease/admission decisions, lane-scoped validation/evidence/finalization, recovery outcomes, and redacted diagnostics. Forge Platform may retain composition qualification evidence but does not own EP runtime semantics.

### Non-goals

- This milestone does not provide same-repository parallelism. Multiple worktrees, declared disjoint scopes, generated-file coordination, migrations, and merge/conflict semantics require a separate post-MVP capability and qualification.
- It does not make Forge a scheduler or execution authority, Workspace a direct Agent controller, Forge Platform an EP runtime owner, or an Agent an independent admission authority.
- It does not require broad distributed/fleet scheduling, automatic cross-host rebalancing, arbitrary scaling, or every repository to be simultaneously available on every Host.
- It does not weaken repository serialization, dependency sequencing, durable evidence, validation, finalization, trust, or the no-direct-server-repository-access boundary.

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
| Standalone transition and extraction closure | `B8C_PASS` proves two-real-project Operations Console/data isolation; `B9_PASS` proves the first governed DJConnect lifecycle; `STANDALONE_EP_VERIFIED` is retained; and `EP_EXTRACTION_CUTOVER_COMPLETE` proves the zero-live-duplicate audit while preserving protected historical/consumer material. A later standalone-to-standalone relocation, if used, follows the separately qualified EP-owned relocation contract. |

## Interpretation rules

Roadmap status does not certify an external repository or authorize production work. A capability becomes current only through its owning repository's governed implementation and evidence, then through Forge Platform composition qualification. Production action for this roadmap consolidation is **NONE**.
