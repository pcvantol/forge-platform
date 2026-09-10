# Forge Platform local consolidation and parked installer

Increment: `FOUR_REPO_CONSOLIDATION_PARKING_2026_09_10`. Recorded 2026-09-10.
Scoped under [Forge Platform roadmap](README.md).
[Documentary consolidation DAG](CONSOLIDATION_PARKING_2026_09_10_DAG.json).

## Decision and existing authoritative parking scope

The owner requests unfinished work be preserved, assessed and parked for later.
This documentation-only NO_BUMP change records local inventory and its remaining
checks. It does not reopen or duplicate the already-merged clean-install plan.
Its documentary authority starts only at its own protected merge. No product
code, tests, workflows, version, run, provider invocation, credential, service,
installer, release, live machine or cleanup is changed.

PARKED is not cancelled, qualified, a runtime lifecycle transition, or proof
that a local process has stopped. Old handoff next-increment instructions do
not authorize resumption. A later explicitly selected task must use current
owning evidence and authority; missing prerequisites are recorded, not built
as an unrequested side effect. No new universal-installer prerequisite is
inserted before the original serial Forge -> EP -> Forge Mission canary.

## Verified remote closure

SOURCE_VERIFIED remote main: `0bb24eb1094d7912de4e624b3ecd97fe73159ce9`.
[PR #61](https://github.com/pcvantol/forge-platform/pull/61) is merged with that
merge SHA and historical head `70ec30080c007424cdb1f3dd52f467ec916144ec`.
Fresh heads/open-PR readback contains main only and no open PR before this
separate documentation change. No remote product featurebranch remains.
This is remote source integration, NOT an operationally complete installer.

[Remote heads](https://api.github.com/repos/pcvantol/forge-platform/git/matching-refs/heads/) ·
[open PRs](https://api.github.com/repos/pcvantol/forge-platform/pulls?state=open&per_page=100).
Existing clean-install scope, all detailed nodes and resumption rules remain in
[EP_SERVER_CLEAN_INSTALL_V1.md](EP_SERVER_CLEAN_INSTALL_V1.md). Retain that
record and delivered source unchanged. The cross-product index is owned by
[Forge](https://github.com/pcvantol/forge/blob/main/docs/roadmap/CONSOLIDATION_PARKING_2026_09_10.md),
not a second installer execution authority.

## Owner-reported local inventory

USER_REPORTED, not independently inspected on the Mac:

| Inventory | Reported value | Disposition |
| --- | --- | --- |
| Local branches | 54: main plus 53 features | Retain until exact per-ref assessment |
| Worktrees | 52: primary plus 51 auxiliary | All reported clean; no blanket removal |
| Main | 41 commits behind origin/main, no unique local main commits | FAST_FORWARD_CANDIDATE after current worktree/ancestry/ownership checks |
| Featurebranches with merged PR link | 37 | CONDITIONAL_CLEANUP_CANDIDATES after local tip equals qualified PR head or later residuals are reconciled |
| Featurebranches without direct PR link | 16 | PARKED_PENDING_COMPARISON; names/tips and actual patches not supplied |

The report does not identify each of the 53 branches or map them onto the 51
auxiliary worktrees. Do not infer that all auxiliary trees belong to the 37
merged items. Full names, paths, SHA tips, PR mapping, ignored/stash content,
locks and active ownership remain open evidence requirements. Clean status
only establishes the reported absence of ordinary uncommitted changes; it does
not establish retention safety, no ignored data or semantic integration.

For each of the unnamed 16, capture exact refs and compare its patch to fresh
main and any predecessor/successor PR. Classify PRESENT_ON_MAIN,
SUPERSEDED_BY_STRONGER_MAIN_IMPLEMENTATION, GENUINE_RESIDUAL or UNRESOLVED.
Retain genuine/unknown work with content and provenance; do not merge obsolete
intermediate branches merely to call the repository consolidated. A suspected
squash equivalent is not a proven content match and not deletion authority.

A later authorized physical cleanup must verify exact target, no active run/
lease/conflicting PR or locked worktree, all tracked/untracked/ignored data,
post-merge local commits and recoverable retention. A bundle alone cannot
preserve uncommitted/untracked/ignored files. Do not follow .engineering into
runtime data, publish private artifacts, globally prune or force-delete.
No local fast-forward, worktree removal or branch deletion is executed here.

## Parked installer outcome and non-goals

Existing v1 outcome: `EP_SERVER_CLEAN_INSTALL_VERIFIED`, only a clean EP Server
installation on native Apple Silicon/macOS 26+ with the exact approved Python
identity. It excludes Forge, Workspace, EP Project Agent, GitHub/Codex/provider
login, upgrades, repair, migration, rollback, uninstall and cleanup from the
v1 acceptance scope. Administrator authority for a system service is separate
from provider credentials. Existing/conflicting installations fail the clean
path; they do not silently become upgrade operations.

The owner reports SOURCE_FIXED foundation for host restrictions, pinned Python
identity/build evidence, durable Python executor kernel, signed catalog and
component selection, native shell/self-update/release packaging and the
parking DAG. This is consistent with the merged scope record, not proof of
production adapters, signed published installer or clean-Mac/reboot success.
Source-level rollback primitives do not expand the v1 operation scope.

## Remaining dependency groups — all retained and parked

| Consolidation node | Existing owning nodes / required result |
| --- | --- |
| FP-LOCAL | Exact branch/worktree inventory, including names and tips of all 16 unmatched branches |
| FP-MAIN | Safe current fast-forward only; no reset or integration of unknown work |
| FP-37 | Per-item final preservation check for the 37 reported merged branches |
| FP-16 | Semantic/residual assessment for the 16 unmatched branches |
| FP-CLEANUP | Per-target permitted removal after evidence and retention; no blanket deletion of 51 trees |
| FP-INSTALLER | Reference, do not replace, the existing EP-only clean-install DAG |
| FP-LATER | Wider product provisioners, provider flows, upgrade/migration/rollback/uninstall/cleanup and discovery remain post-v1 parked work |

FP-INSTALLER retains every existing dependency, without inventing extra edges:

- FP-EP-CI-1: approved independent cryptographically signed C-3a time authority
  and adapter; local clock/ordinary NTP/HTTP Date are not the accepted substitute;
- EP-CI-1 and EP-CI-2: EP-owned published exact artifact and Python build/test
  evidence, clean-only provisioner, readback, service/health and terminal receipt;
- FP-EP-CI-2/3/4: locked mutation re-verification, receipt validation, one-component
  preset/readback, native index transport, manifest/session production;
- FP-EP-CI-5/6: real Python transport/archive/Mach-O inspection, privileged bridge
  and native wizard/session to EP provisioner wiring;
- FP-EP-CI-7: protected signing, notarization, release, production trust resources
  and current-installer handoff;
- FP-EP-CI-Q: explicitly authorized clean-Mac installation, fresh-shell, reboot
  and resolver/identity proof, yielding EP_SERVER_CLEAN_INSTALL_VERIFIED.

Those remain the detailed [existing graph](EP_SERVER_CLEAN_INSTALL_V1.md), not
newly scheduled work. Policy-aware composition, Project Hygiene release scope,
MVP and knowledge integration remain under [README.md](README.md) and their
owning DAGs. Do not silently discard them or start them from this checkpoint.

## Closure

Remote source integration and installer parking are proven by #61. This change
adds the owner-reported local inventory and explicit unresolved per-branch work.
Physical consolidation is NOT_COMPLETE: the 16 unmatched branches have not
been examined here and no worktree has been removed. No product runtime,
release, installer or first Forge E2E capability is qualified by these docs.
