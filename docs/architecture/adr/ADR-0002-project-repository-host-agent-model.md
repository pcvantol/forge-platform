# ADR-0002 — Project, repository, host, Agent, and execution-lane model

**Status:** Accepted

## Decision

A Project has exactly one Canonical Project Authority Repository and zero or more Child Repositories. The authority repository records Git-reconstructable product topology; child repositories remain autonomous Git repositories. A single-repository Project is the trivial case where the authority repository is also the only execution/source repository.

Logical topology maps Projects to repositories, dependencies, and roles. Physical topology maps repositories to Hosts and Project Agents. Each Agent process serves one Host/OS-user context and may expose zero or more attached repositories. Agents may be offline; this does not remove shared Forge/Workspace state or create inferred execution eligibility.

An Execution Lane belongs to one Project, targets one or more repositories, has planned dependencies, and acquires a durable EP-owned repository lock/lease for every targeted repository. At most one mutating lane per repository is permitted initially. Forge plans dependencies; Engineering Platform enforces executable ordering, Host/Agent capability matching, capacity-aware admission, lock/lease lifecycle, and lane-scoped evidence/finalization. An Agent may advertise bounded execution capacity, but cannot self-admit work.

For the standalone transition, B8C attaches DJConnect and the Engineering Platform source checkout as two real development projects to the same CENTRAL/Agent after B8. B8C is an Operations Console/data-isolation qualification: project selection, `project_id` scoping, project-scoped versus installation-wide data, browser context restoration, and fail-closed cross-project leakage. It does not execute EP against its own source checkout; installed artifacts remain runtime authority. B9 then performs the first governed execution against DJConnect only. EP self-hosting is a later, separately qualified post-`STANDALONE_EP_VERIFIED` capability.

## Consequences

After `STANDALONE_EP_VERIFIED`, independent repositories can execute mutating lanes in parallel when they neither share a repository lease nor have a dependency ordering. Different repositories may still be sequenced by a Forge-planned dependency. EP applies bounded capacity, backpressure, and fairness; Forge remains planning-only and Workspace may present or issue permitted control intent but cannot schedule or execute.

Same-repository scope/worktree parallelism is deferred as a separate capability requiring its own resource and scope contract. Workspace persistence can present topology but cannot be its exclusive authority.

DJConnect may begin its EP extraction cutover only after B9 succeeds and establishes `STANDALONE_EP_VERIFIED`. Completion requires a zero-live-duplicate audit for generic EP implementation, runtime authority, and duplicated product semantics, while retaining the portable repository declaration, necessary installed-EP consumer adapters, and immutable historical/migration evidence.
