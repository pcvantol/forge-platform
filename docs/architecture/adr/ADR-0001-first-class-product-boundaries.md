# ADR-0001 — First-class product boundaries

**Status:** Accepted

## Decision

Forge, Workspace, Engineering Platform, Forge Platform, TDE, AI Development Contracts, and the AI Platform Engineering Knowledge Base remain separate first-class repositories and product authorities. Forge and Workspace are peers; neither is a child source authority of the other or of Engineering Platform.

Forge owns planning and engineering intent. Workspace owns shared control-plane/product-team state and human UX. Engineering Platform owns execution admission, scheduling, execution, validation, qualification, and evidence. Its Project Agent is an Engineering Platform component. TDE remains a standalone product authority; AI Development Contracts remains generic-contract authority; the Knowledge Base remains knowledge-lifecycle authority.

Forge Platform owns only universal distribution, deployment composition, artifact verification, compatibility declarations, and installation lifecycle. It composes independently published artifacts and never becomes a hidden source monolith or product-runtime authority.

## Consequences

Cross-product integration uses published contracts and artifacts. Product repositories preserve their own source, releases, protocol implementations, and product behavior. Co-location does not collapse authority.
