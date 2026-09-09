# Component-operation delegation contract

Forge Platform may coordinate an install, update, repair, or rollback only
after it has selected a component artifact from qualified composition evidence.
This is a **consumer contract**, not an EP, Forge, or Workspace installation
engine and not evidence that a concrete product endpoint is already deployed.

## Bounded coordinator input

A request binds one coordinator operation ID to all of the following:

- component identity, requested role, operation kind, and opaque
  product-owned installation identity;
- the complete qualified artifact identity: version, source revision, source
  locator, SHA-256 digest, and qualification reference; and
- a small product-extension selection mapping whose contents are canonicalized
  into the retry fingerprint.

Changing any of those values under an existing operation ID fails closed. In
particular, a new source locator is not accepted merely because its digest or
version happens to match a prior request.

The opaque installation identity is the only target selector accepted by the
coordinator. The extension mapping rejects direct or nested runtime,
interpreter, executable, PATH, venv, launch/service, process, database,
CENTRAL, migration, backup, credential, source-version, or installation-path
instructions. Forge Platform has no local fallback lookup for such input.

## Product-owned adapter boundary

The product repository must supply an adapter; Forge Platform does not import
product source or manufacture one. The public adapter shape is deliberately
small:

| Product-owned method | Result consumed by Forge Platform | Product-owned meaning |
| --- | --- | --- |
| `readback(request)` | component/install correlation; opaque selected runtime, executable, server and instance identities; observed artifact; identity-aware health evidence; inventory coverage and conflict evidence | Resolves the official runtime and verifies the actual interface/instance. It decides whether the machine-wide inventory is sufficient to assert one operational installation. |
| `assess_update(request)` | `UPDATE_AVAILABLE`, `UP_TO_DATE`, `INCOMPATIBLE`, or `UNKNOWN` for the exact candidate plus evidence | Determines compatibility and whether a candidate update may run. |
| `execute(request)` | product operation ID, exact component/install/artifact correlation, state, operation evidence, and cleanup evidence where pending | Performs product-owned provisioning with the product's authoritative installation lock. |
| `resume(request, prior_receipt)` | the same product operation identity and a new correlated receipt | Resumes a `CLEANUP_PENDING` or `RECOVERY_PENDING` product operation after crash or reboot. |

For Engineering Platform, the adapter must be backed by the EP-owned
installation resolver/provisioner and its installation record. It owns runtime
selection, service references, health-content/instance verification, data
compatibility, backup, migration, rollback, cleanup, and operational locks.
Forge Platform may display or retain its non-secret evidence but may not
reinterpret it as a PATH, HTTP-reachability, service, database, or migration
decision.

An `ACTIVE` product readback is valid only with a selected runtime,
executable, instance, qualified artifact, and product health evidence. Forge
Platform exposes `single_operational_installation_verified` only when the
product readback is `ACTIVE`/`HEALTHY`, has `MACHINE_WIDE` inventory coverage,
and reports no conflict. A per-user observation, incomplete scan, or unknown
conflict status cannot become a Mac-wide uniqueness claim.

For an `update`, Forge Platform dispatches `execute` only after the product
returns `UPDATE_AVAILABLE` for that exact qualified artifact. `UP_TO_DATE`,
`INCOMPATIBLE`, and `UNKNOWN` do not dispatch a product mutation. A completed
receipt must be followed by product `ACTIVE`/`HEALTHY` readback for the same
exact artifact. A mismatched component, installation, artifact, or resumed
product-operation ID fails closed.

## Durable coordination only

The durable coordinator stores one atomic, mode-`0600` coordination record per
safe operation ID. It retains the preflight/postflight product readbacks, the
candidate update assessment, current receipt, and any prior pending receipts;
it never stores the product request extension mapping or credentials. It
rejects malformed/non-finite JSON and a record whose operation ID does not
match its directory.

Within one Forge Platform operations root, a hashed component/install target
lock prevents two different coordinator IDs from dispatching concurrently. A
persisted `CLEANUP_PENDING` or `RECOVERY_PENDING` receipt blocks a new ID for
that target until the original operation is resumed. This is only a local
composition throttle. It is neither a replacement for nor proof of the
product-owned installation lock; EP remains authoritative across all callers,
accounts, processes, crashes, and reboots.

The current source kernel does not implement a concrete EP endpoint, privileged
installer, artifact download, service action, migration, rollback, cleanup, or
live-machine operation. Those remain product-owned or future universal
installer work. Any future adapter must preserve this boundary and use the
same product operation identity to make execute/resume crash-safe.
