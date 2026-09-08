# Evidence-gated cross-repository component composition

**Status:** target Forge Platform architecture; canonical when merged. Implementation and qualification remain separately governed.

## Purpose

Forge Platform owns installation and release composition of independently published Forge, Workspace and Engineering Platform artifacts. It must support a development flow where installer-role implementation can advance in parallel with producer work, while final release composition waits for exact published artifact evidence.

This document defines that boundary for cross-repository Forge Missions. Forge owns the engineering Action graph; EP owns execution/admission/evidence; Forge Platform owns the final component manifest and installer behavior.

## Parallel implementation versus final composition

A producer artifact and its installer support do not need to be implemented serially.

Example Mission: **make Engineering Platform Project Agents production-ready and installable**.

```text
engineering-platform repository
  EP-A1 contract
     |\
     | +--> EP-A2 Agent runtime -------------------+
     +----> EP-A3 Server/Agent protocol -----------+--> EP-A4 package/qualify
                                                        |
                                                        v
                                                EP-A5 publish artifacts

forge-platform repository
  FP-A1 Agent role/model --> FP-A2 installer support --------+
                                                           |
EP-A5 published artifact evidence --------------------------+--> FP-A3 final component manifest
                                                                |
                                                                v
                                                         FP-A4 installer qualification
```

EP implementation and Forge Platform installer support may proceed concurrently when Forge declares them independent and EP execution resources permit it.

The final component manifest is different: it is evidence-gated by the actual producer publication.

## Producer evidence required for manifest finalization

For each installable component, a final manifest entry must bind the installable bytes to source and qualification evidence. At minimum:

```text
component identity
component version
source repository/revision
artifact name/acquisition reference
artifact SHA-256 or qualified digest
signature/provenance reference where available
qualification/release evidence reference
supported OS/architecture
protocol compatibility
component dependencies
```

The artifact digest identifies what will actually be installed. The source revision identifies where those bytes came from. Neither substitutes for the other.

A future or guessed version/checksum is invalid. A source merge without the required published artifact is not enough to finalize the manifest.

## Forge dependency edge

Forge may materialize the final manifest Action with a hard dependency on the producer publication Action:

```text
FP-A3.finalize_manifest.depends_on = [EP-A5.publish_artifacts, FP-A2.installer_support]
```

The `EP-A5` Action DoD should expose the artifact evidence needed by `FP-A3`. EP terminal evidence makes that producer outcome verifiable. Forge reconciles the evidence and only then releases the dependent Forge Platform Action.

Forge Platform itself does not read Forge's planning database or EP CENTRAL directly. It consumes the qualified artifact references and produces its own repository change under ordinary EP execution.

## Five first-class installable artifacts

The same evidence-gated rule applies independently to:

- Forge Runtime / Forge Server artifact;
- Workspace Server artifact;
- Workspace Client artifact;
- Engineering Platform Server artifact;
- Engineering Platform Project Agent artifact.

A platform release can therefore be composed only when every required component in that release has its own published artifact evidence and the declared compatibility set has been qualified.

## Dynamic replanning

The component manifest is not an engineering plan. If producer evidence changes the work needed—for example, a protocol version changes or a new Agent packaging constraint appears—Forge may revise future Engineering Actions in the Living Mission Graph. The already published producer artifacts and already materialized Actions remain immutable evidence/history.

## Qualification

Qualification must prove:

- installer-role implementation can proceed before producer artifact publication when no hard dependency exists;
- final manifest Action stays blocked before required producer artifact evidence exists;
- source merge alone cannot satisfy an artifact dependency;
- wrong artifact digest/source revision/provenance does not unlock the dependent Action;
- correct artifact evidence unlocks the dependent Action through Forge replanning/reconciliation;
- manifest schema keeps source revision distinct from artifact digest;
- every required manifest component references a qualified artifact rather than a mutable checkout;
- installer qualification uses the exact manifest-pinned artifact bytes.

This is a natural cross-repository dogfood target after the first serial Forge dynamic-Mission canary and after EP qualifies the multi-execution/repository-lease/capacity capabilities needed for safe parallel work.
