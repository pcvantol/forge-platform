# AI-development contract projection status

Forge Platform consumes `pcvantol/ai-development-contracts` at canonical source commit `ec070e399ff4dbd92e760370002995fe4f4d52d6`.

At foundation time, `profiles/profiles.json` contains profiles for `forge`, `workspace`, `engineering-platform`, `tde`, and related existing consumers, but no `forge-platform` profile. Therefore this repository does **not** fabricate a generated generic projection or duplicate generic branch, handoff, governance, and TDE contracts.

## Exact central-profile requirement

Add a `forge-platform` profile whose extension identity is `FORGE_PLATFORM_DEVELOPMENT_EXTENSION`, then materialize and commit the generated projection and projection manifest here using the central materializer. The projection must remain generated generic content plus the local extension; this repository's extension must not become a copy of generic contracts.
