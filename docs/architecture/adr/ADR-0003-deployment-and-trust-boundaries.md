# ADR-0003 — Deployment roles and explicit trust boundaries

**Status:** Accepted

## Decision

Workspace Client↔Workspace Server is a user/session trust relationship. Project Agent↔Engineering Platform Server is an independent host/agent execution trust relationship. Workspace Client↔local Project Agent is a third, local UX boundary. Credentials and authorization domains remain separate; localhost and same-machine deployment grant no implicit trust.

Workspace Client-only, Project Agent-only, and combined developer-workstation deployments are valid. Server roles (Forge Runtime, Workspace Server, Engineering Platform Server) may co-reside or be deployed separately. Project Agent-only hosts may serve as headless platform-specific execution hosts.

The local Agent boundary cannot bypass EP admission, durable scheduling, provider execution, finalization, merge authority, or TDE. Engineering Platform owns the future Local Project Agent API; Workspace owns its consumer implementation.

## Consequences

EP Server communicates through the Agent protocol even when co-located with an Agent. Source checkouts develop/test/build; installed artifacts run. No server obtains direct local-repository authority merely through co-location.
