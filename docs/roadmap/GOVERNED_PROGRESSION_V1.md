# Governed delivery composition roadmap

Increment: `GOVERNED_PROGRESSION_AND_DELIVERY_AUTHORITY_V1`.
Scoped under [policy-aware composition roadmap](POLICY_GOVERNANCE_V1.md) and
its [canonical roadmap index](README.md).
Design: [delivery authority and promotion gates](../architecture/DELIVERY_AUTHORITY_AND_PROMOTION_GATES.md).
Shared documentary DAG:
`pcvantol/forge:docs/roadmap/governed-progression-v1.json`.
All implementation/qualification nodes below remain PLANNED.

| Node | Owner | Depends on | Required proof |
| --- | --- | --- | --- |
| GP-0 | Four owning products | none | Consistent progression/target/authority documentation |
| GP-DC | Forge/EP/Platform consumers; project owns declaration | GP-0 | Exact target/environment/trigger/approval/deploy authority contract |
| GP-X | Forge + EP integration with existing target authority | GP-Q, GP-DC | Qualified real external gate/request/readback without authority transfer |
| GP-P | Forge Platform | GP-X | External-delivery-aware composition using qualified artifacts and exact owner approval/operation evidence |

```text
GP-0 -> GP-DC ------------------+
GP-F + GP-E -> GP-Q ------------+-> GP-X -> GP-P
```

GP-P additionally consumes the existing applicable artifact, POL-P, VR-Q and
installation qualifications. It is not a dependency imposed on every local
installation or on a Mission with no deployment. Static design can proceed
before live integration. Workspace GP-W remains a separate consumer UI lane.

Do not add general CD, PROD/App Store deployment, universal installer completion
or rich Workspace review UI ahead of the first serial no-deployment canary.
Existing pending artifact/SemVer PRs retain their own findings and delivery.
No runtime/executable programme-DAG change, grant or publication is authorized
by this roadmap; this increment only makes the design canonical after merge.
