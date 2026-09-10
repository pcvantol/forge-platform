# Forge Platform handoff

Start with `BOOTSTRAP.md`. Forge Platform owns universal artifact composition,
deployment topology, compatibility, product-provisioner coordination, and
installer qualification. It coordinates install, update, repair and uninstall
through owning product contracts; it does not own product implementation,
Engineering Platform execution or EP installation/service/migration/cleanup
provisioning, the EP Project Agent protocol, Workspace behavior, or generic
development contracts.

The exact managed-Python contract has a platform-neutral source executor with
durable acquisition, immutable slot/venv, resume, final-readback and rollback
evidence. It has no production runtime artifact, native transport/inspection,
privileged adapter or released-installer wiring, so operational Python mutation
remains fail-closed.

The Universal Installer work is parked after source-level managed-Python
executor delivery. The recorded resumption target is a single EP Server
clean-install v1: no EP Project Agent, Forge, Workspace, provider login,
upgrade, repair, migration, rollback, removal, cleanup or live mutation has
been performed. Resume from the
[EP Server clean-install v1 parking roadmap](docs/roadmap/EP_SERVER_CLEAN_INSTALL_V1.md),
which records the verified baseline, ownership boundaries, external decisions
and documentary DAG.

The local generic projection is pinned in
`docs/ai-development/projection-manifest.json`; validate it with
`sh scripts/validate.sh`. For product authority and open work, use the local
architecture, ownership matrix, roadmap, and TDE integration documents.
