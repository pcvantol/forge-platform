# Forge Platform bootstrap

Start every Forge Platform development session from this repository-local
entrypoint. Read, in order:

1. `docs/ai-development/GENERATED_PROJECTION.md` for the committed generic
   development contracts;
2. `docs/development/FORGE_PLATFORM_DEVELOPMENT_EXTENSION.md` for the local
   distribution, installer, artifact, and compatibility qualification rules;
3. `docs/architecture/FORGE_PLATFORM_ARCHITECTURE.md` and
   `docs/architecture/OWNERSHIP_MATRIX.md` for product boundaries;
4. `docs/roadmap/README.md` and `docs/development/TDE_INTEGRATION.md` for
   local planning and delivery evidence.

Validate the checkout offline with `sh scripts/validate.sh`. The generated
projection is committed evidence, not a live dependency on another checkout or
network service. Update it only through the governed central-contract update
workflow.
