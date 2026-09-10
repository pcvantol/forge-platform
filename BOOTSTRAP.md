# Forge Platform bootstrap

## Current pickup checkpoint — consolidation and parking, 10 September 2026

Read the [local consolidation record](docs/roadmap/CONSOLIDATION_PARKING_2026_09_10.md)
and [documentary DAG](docs/roadmap/CONSOLIDATION_PARKING_2026_09_10_DAG.json).
The installer remains PARKED under the already-merged
[EP Server clean-install v1 roadmap](docs/roadmap/EP_SERVER_CLEAN_INSTALL_V1.md).
No next installer increment, host cleanup or qualification run is selected.
The consolidation record now reflects the completed physical cleanup: the
pre-documentation baseline had one local `main` worktree, no local feature
branches, no unpreserved WIP, and `main` equal to `origin/main`. The 37
delivered branches were removed; all 16 formerly unmatched branches were
classified with no genuine residual and no unresolved item. This checkpoint
does not activate the retained installer DAG or make it a Forge-E2E gate.

Start every Forge Platform development session from this repository-local
entrypoint. Read, in order:

1. `docs/ai-development/GENERATED_PROJECTION.md` for the committed generic
   development contracts;
2. `docs/development/FORGE_PLATFORM_DEVELOPMENT_EXTENSION.md` for the local
   distribution, installer, artifact, and compatibility qualification rules;
3. `docs/architecture/FORGE_PLATFORM_ARCHITECTURE.md` and
   `docs/architecture/OWNERSHIP_MATRIX.md` for product boundaries;
4. `docs/roadmap/README.md` and `docs/development/TDE_INTEGRATION.md` for
   local planning and delivery evidence;
5. for policy/version/release work, `docs/architecture/POLICY_AWARE_COMPOSITION.md`
   and `docs/roadmap/POLICY_GOVERNANCE_V1.md`. These route the coordinated
   documentation target without making this product a peer policy authority.

Validate the checkout offline with `sh scripts/validate.sh`. The generated
projection is committed evidence, not a live dependency on another checkout or
network service. Update it only through the governed central-contract update
workflow.
