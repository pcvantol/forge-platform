# Policy-aware composition roadmap

Increment: `POLICY_GOVERNANCE_AND_EFFECTIVE_PROFILES_V1`.
Part of the [canonical roadmap index](README.md), governed by
[Policy-aware composition](../architecture/POLICY_AWARE_COMPOSITION.md).
This increment is documentation-only; all runtime capabilities below remain PLANNED.

| Node | Owner / result | Required inputs | Position |
| --- | --- | --- | --- |
| POL-0 | Four owners document classifications, authority and compatible logical contracts | none | This documentation increment |
| POL-Q | Forge/EP qualify effective request/admission policy binding, history and authority | POL-B, with POL-F/POL-E | External qualification dependency, not Platform status authority |
| VR-Q | Forge/EP qualify native release planning -> bounded execution -> actual published artifact evidence | VR-F, VR-X, POL-Q | External producer proof before final composition |
| POL-P | Forge Platform qualifies component/policy/runtime manifest and controlled owner activation/installation receipts | POL-Q, VR-Q | PLANNED local production-composition capability |
| POL-W | Workspace implements Policy & Automation management UI | POL-WC, POL-Q | Separate peer UI; not an installer or first-canary prerequisite |

```text
{POL-F, POL-E} -> POL-B -> POL-Q
{VR-F, VR-X, POL-Q} -> VR-Q
{POL-Q, VR-Q} -> POL-P
{POL-WC, POL-Q} -> POL-W  (independent UI lane)
```

The full documentary node/edge set is
`pcvantol/forge:docs/roadmap/policy-governance-v1.json`, proposal
[Forge #50](https://github.com/pcvantol/forge/pull/50). EP-owned milestones are in
[EP #103](https://github.com/pcvantol/engineering-platform/pull/103); Workspace
consumer/UX milestones in [Workspace #15](https://github.com/pcvantol/workspace/pull/15).
Owning main/evidence decides implementation and readiness; diagram order does not.

## Scope relative to existing work

Static composition/policy contract design can run in parallel with producer
implementation. Final manifests require actual published qualified artifacts.
Pending #16 retains the artifact-gated composition proposal; #17's versioning
implementation must reconcile with native Forge release planning and the SemVer
review findings. Neither is rewritten, merged or qualified by this increment.

Do not make full Workspace UI, every legacy policy migration or general discovery
a new prerequisite for the first Forge -> EP -> Forge canary. Production universal
installer readiness is different: the claimed release/policy/component combination
requires its real producer and installed qualification.

Preserve the existing executable bootstrap DAG and grants. This document neither
allocates Missions nor resets budgets, authorizes side effects or changes version
baselines. Merge of this documentation makes a design canonical, not a runtime
capability implemented.
