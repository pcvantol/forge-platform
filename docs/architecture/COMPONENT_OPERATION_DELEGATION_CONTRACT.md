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

The durable coordinator writes one private, atomic coordination record per
safe operation ID and uses a non-blocking per-operation process lock. It stores
only the operation fingerprint and product receipt, never the product request
or credentials. A future universal installer must provide its deployment-level
retention and abandoned-operation recovery policy while continuing to consume
product receipts without replacing product engines.
