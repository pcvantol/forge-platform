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
| Universal installer and deployment composition | `pcvantol/forge-platform` | Forge, Workspace, Engineering Platform artifacts | Installs qualified published artifacts only. |
| Cross-product compatibility matrix | `pcvantol/forge-platform` | Product artifacts/releases | Product repos own individual protocol implementation. |
| Canonical Project topology | A Project's Canonical Project Authority Repository | Workspace, Forge, Engineering Platform | Not owned by `pcvantol/forge-platform`; Git-reconstructable. |
