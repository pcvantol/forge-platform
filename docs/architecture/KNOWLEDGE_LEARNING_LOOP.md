# Governed Engineering Knowledge Learning Loop — moved

## Status

**Superseded as canonical product architecture.**

The governed Engineering Knowledge Learning Loop was originally analyzed here because Forge Platform was the integration/composition repository used to study deployment and product boundaries. That analysis established important authority decisions, including that the AI Platform Engineering Knowledge Base (KB) is independent knowledge authority and is not currently an installable Forge Platform server role.

The canonical product architecture now belongs to **Forge**, because Forge owns planning and learning orchestration.

Canonical Forge documents:

- `pcvantol/forge/docs/architecture/dual-engineering-learning-system.md`
- `pcvantol/forge/docs/architecture/knowledge-learning-loop.md`
- `pcvantol/forge/docs/architecture/engineering-quality-learning-loop.md`
- `pcvantol/forge/docs/roadmap/0.1.md`

The KB repository remains canonical for the knowledge lifecycle itself: extraction, ingestion, observations, candidates, concepts, generalization, certification and publication.

## Forge Platform boundary retained

Forge Platform continues to own deployment/composition concerns only.

The following decisions from the original analysis remain valid:

- the KB is currently Git/CLI-backed, not a supported installable server role;
- Forge Platform must not invent a KB daemon/API for product symmetry;
- any future KB installer composition requires a qualified published artifact plus persistence, backup, update, concurrency and supported operating-model contracts;
- Forge Platform does not own knowledge certification, learning semantics, EP evidence semantics or Workspace governance.

Historical detail remains available in Git history. New learning-loop architecture changes must be made in the Forge canonical documents rather than recreating a competing architecture here.