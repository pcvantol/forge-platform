# Cross-repository ownership matrix

| Concept | Canonical repository | Consumer repositories | Notes |
| --- | --- | --- | --- |
| Forge planning and engineering intent | `pcvantol/forge` | Workspace, Engineering Platform | Forge plans; EP executes admitted actions. |
| Workspace shared product/project state | `pcvantol/workspace` | Forge, Engineering Platform, Workspace Clients | Server-authoritative; clients do not create divergent truth. |
| Workspace Client | `pcvantol/workspace` | Forge Platform installs it | Human UX; may operate without a local Agent. |
| EP execution, admission, scheduling, evidence | `pcvantol/engineering-platform` | Forge, Workspace | EP is execution authority. |
| Engineering Platform Project Agent | `pcvantol/engineering-platform` | Workspace consumer integration; Forge Platform installs it | One process per Host/OS-user context, serving 0..N repositories. |
| EP Local Project Agent API | `pcvantol/engineering-platform` | Workspace consumer/adapter | Forge Platform owns neither protocol nor adapter. |
| Technical Debt Engine | `pcvantol/technical-debt-engine` | Product repositories | Standalone delivery/integration authority. |
| Generic AI-development contracts | `pcvantol/ai-development-contracts` | Product repositories | Generated projection plus local extension. |
| Generalized/certified engineering knowledge | `pcvantol/ai-platform-engineering-knowledge-base` | Product repositories | Knowledge lifecycle authority. |
| Knowledge Sources | Knowledge Base | Source repositories | Registered sources remain autonomous and read-only to KB operations. |
| Engineering Observations | Knowledge Base | Approved source/evidence producers | Evidence only; not reusable authoritative knowledge. |
| Knowledge Candidates / Concepts / Generalized Knowledge | Knowledge Base | Governance reviewers | Lifecycle proposals/interpretations; not Certified Knowledge. |
| Certified Knowledge / knowledge certification | Knowledge Base governance | Forge, Workspace, EP consumers | Independent governed promotion; no producer self-certifies. |
| Knowledge extraction | Knowledge Base | Approved Knowledge Sources | Current extractor reads a shallow Git clone and writes observations in KB. |
| Knowledge consumption | Knowledge Base | Forge, Workspace, EP future consumers | Read-only and traceable; direct KB internal-file coupling is not a cross-product contract. |
| EP evidence export | Engineering Platform + Knowledge Base | TDE, Project Agents | Explicit future contract; EP remains evidence producer. |
| Forge knowledge consumption | Forge + Knowledge Base | Workspace, EP | Explicit future read-only consumer contract. |
| Workspace knowledge UX | Workspace + Knowledge Base | Users | Workspace displays/controls; KB retains lifecycle authority. |
| KB distribution | Knowledge Base; Forge Platform when qualified | Forge Platform | KB must first publish a supported artifact and operating model. |
| Universal installer and deployment composition | `pcvantol/forge-platform` | Forge, Workspace, Engineering Platform artifacts | Installs qualified published artifacts only. |
| Cross-product compatibility matrix | `pcvantol/forge-platform` | Product artifacts/releases | Product repos own individual protocol implementation. |
| Canonical Project topology | A Project's Canonical Project Authority Repository | Workspace, Forge, Engineering Platform | Not owned by `pcvantol/forge-platform`; Git-reconstructable. |
