# ADR-0005 — Governed engineering learning loop and knowledge authority boundaries

**Status:** Accepted

## Decision

The AI Platform Engineering Knowledge Base is the independent authority for reusable knowledge lifecycle, certification, and publication. Forge uses Certified Knowledge read-only for future planning; Workspace presents/initiates governed UX actions; Engineering Platform and Project Agents produce execution evidence; TDE produces qualification evidence. None may certify reusable knowledge.

Knowledge integration is additive. No Forge, Workspace, EP, or Agent execution path depends on KB availability. Evidence enters through approved Knowledge Sources and explicit evidence/export profiles, remains read-only against source repositories, and progresses through the KB lifecycle before governed certification.

The KB is currently a Git-backed repository-local CLI capability, not an installable server role. Forge Platform will not add it to installer roles until the KB publishes a qualified artifact and defines its persistence, concurrency, backup, update, and supported operating model.

## Consequences

EP success, TDE results, Forge planning output, Agent facts, and automation output are evidence only. They cannot self-certify. Cross-product integrations require explicit read-only consumer or evidence-export contracts. KB runtime, lifecycle, storage, source integration, and certification remain KB-owned.
