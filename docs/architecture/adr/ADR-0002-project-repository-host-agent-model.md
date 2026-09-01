# ADR-0002 — Project, repository, host, Agent, and execution-lane model

**Status:** Accepted

## Decision

A Project has exactly one Canonical Project Authority Repository and zero or more Child Repositories. The authority repository records Git-reconstructable product topology; child repositories remain autonomous Git repositories. A single-repository Project is the trivial case where the authority repository is also the only execution/source repository.

Logical topology maps Projects to repositories, dependencies, and roles. Physical topology maps repositories to Hosts and Project Agents. Each Agent process serves one Host/OS-user context and may expose zero or more attached repositories. Agents may be offline; this does not remove shared Forge/Workspace state or create inferred execution eligibility.

An Execution Lane belongs to one Project, targets one or more repositories, has planned dependencies, and acquires a repository lock for every targeted repository. At most one mutating lane per repository is permitted initially. Forge plans dependencies; Engineering Platform enforces executable ordering and lock admission.

## Consequences

Independent repositories can execute in parallel when they neither share a locked repository nor have a dependency ordering. Same-repository scope/worktree parallelism is deferred. Workspace persistence can present topology but cannot be its exclusive authority.
