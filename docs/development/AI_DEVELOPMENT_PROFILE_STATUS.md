# AI-development contract projection status

Forge Platform consumes the committed offline projection from
`pcvantol/ai-development-contracts` at source commit
`dc58a5351b69074f445e0e81499bff816dbca738`, using profile `forge-platform`
and extension identity `FORGE_PLATFORM_DEVELOPMENT_EXTENSION`.

The generated projection and manifest are in `docs/ai-development/`. They are
validated by `sh scripts/validate.sh` locally and by Foundation validation in
CI. The local extension remains the sole location for Forge-Platform-specific
development context; it must not become a copy of generic contracts.
