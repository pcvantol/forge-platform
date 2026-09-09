# Component-operation delegation contract

Forge Platform coordinates an install, update, repair or rollback only after a
component artifact has been selected from qualified evidence. The coordinator
binds its operation ID to the component identity, requested role, product
version, source revision, artifact digest and qualification reference.

It sends that exact selection to a product-owned public operation adapter and
retains the resulting product operation ID, terminal state and evidence
reference. A retry with the same coordinator operation is idempotent; a retry
that changes the selected artifact or action fails closed.

This is deliberately not an installation record and cannot prove that a
runtime is active. The product-owned adapter remains responsible for runtime
selection, service references, health identity, data compatibility, backup,
migration, rollback and cleanup. Forge Platform does not accept direct
interpreter, PATH, runtime, database, CENTRAL, migration, backup, service or
command instructions through this boundary.

The initial in-process coordinator is a source-level kernel. The future
universal installer must supply durable operation storage and inter-process
locking, then consume the product receipts without replacing product engines.
