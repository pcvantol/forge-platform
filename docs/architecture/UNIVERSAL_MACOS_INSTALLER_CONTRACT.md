# Universal macOS Installer contract

**Status:** Canonical implementation contract. Forge Platform has a source-level installer foundation, a native wizard shell, a read-only native outer-catalog admission kernel, and unassembled catalog-trust/transport/acceptance-storage seams. It does not yet certify a published installer, a privileged helper, a product provisioner adapter, or production deployment.

This contract implements [ADR-0004](adr/ADR-0004-universal-installer-artifact-composition.md) and [ADR-0006](adr/ADR-0006-server-deployment-and-discovery.md). It is not a second EP, Forge, or Workspace installation engine.

## Separately versioned artifacts

Forge Platform defines two separately versioned immutable artifact types; their production publication remains a later qualified increment:

| Artifact | Meaning |
| --- | --- |
| `forge-platform-installer` | Native macOS bootstrapper, wizard, updater, managed-tool orchestration, and composition UI. Its identity includes installer version, source revision, digest, code-signing identity, notarization evidence, and GitHub Release receipt. |
| `forge-platform-composition` | Signed/digest-pinned selection of published Forge, Workspace, and EP artifacts, compatibility evidence, host/tool requirements, and installer capability requirement. |

There is deliberately **not** one installer package per Forge/EP/Workspace combination. One installer can consume many immutable compositions. Each composition declares a minimum installer version and named capabilities. A new component, such as a separate Execution Agent, needs a new installer release only when it needs a new component type, provisioner-adapter protocol, UI semantic, or other new capability. Its composition requires that capability; an older installer updates first or rejects the composition.

Product version, installer version, composition identity, protocol/schema versions, source revision, and artifact digest remain separate values. `installer-version.json` is the sole source for the native installer version/channel/capability projection; it is deliberately independent of Forge Platform's `product-version.json` composition-release version.

An installer release reserves the distinct GitHub tag configured by its
reviewed installer-release identity policy (normally a prefix followed by the
installer version). The signed channel remains immutable descriptor metadata
rather than a tag suffix, so stable and candidate work can never publish
different bytes under one installer-version identity. The committed policy is
deliberately `UNCONFIGURED` until the actual GitHub namespace, application
bundle identifier, Apple Team identifier and public descriptor-key threshold
are approved. An unconfigured policy blocks the release workflow; no source
literal or test fixture is an implicit production identity.

## Sealed installer release-trust resource V2

A released native installer may carry exactly one code-signed public resource,
`ForgePlatformInstallerReleaseTrust.json`, that defines the future GitHub
Release bootstrap trust policy. This is a format contract only: this repository
commits no production resource, repository, bundle identity, Team identifier,
or signing key. A source build without the resource remains fail-closed.

The strict JSON object has exactly these fields:

```text
schema_version = 2
configuration_sha256
repository
release_descriptor_locator = "github-release-asset-v1"
release_descriptor_asset_name
expected_bundle_identifier
expected_team_identifier
signature_threshold
ed25519_public_keys = [{ key_id, public_key_base64 }, ...]
```

`repository` matches
`^[A-Za-z0-9][A-Za-z0-9._-]{0,99}/[A-Za-z0-9][A-Za-z0-9._-]{0,99}$` (so neither
path segment can be `.` or `..`) and
`release_descriptor_asset_name` matches
`^[A-Za-z0-9][A-Za-z0-9._-]{0,122}\.json$` (at most 128 bytes including
`.json`); it is therefore bounded,
slash-free, and cannot begin with a dot segment.
`expected_bundle_identifier` matches
`^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$` and `expected_team_identifier` matches
`^[A-Z0-9]{10}$`. Each `key_id` matches
`^[a-z0-9][a-z0-9._-]{0,127}$`; keys are strictly ascending by ID, key IDs and
public keys are each unique, and `public_key_base64` is canonical standard
Base64 for exactly 32 raw Ed25519 public-key bytes. The threshold is an integer
from one through the number of keys (maximum sixteen).

`configuration_sha256` is lower-case SHA-256 of UTF-8 bytes obtained by joining
these tokens with one NUL byte, in the exact order shown (followed by the two
key tokens per key in strict key-ID order):

```text
forge-platform-installer-release-trust-v2
schema_version=2
repository=<repository>
release_descriptor_locator=<release_descriptor_locator>
release_descriptor_asset_name=<release_descriptor_asset_name>
expected_bundle_identifier=<expected_bundle_identifier>
expected_team_identifier=<expected_team_identifier>
signature_threshold=<signature_threshold>
ed25519_public_key_count=<count>
ed25519_public_key_id=<key_id>
ed25519_public_key_base64=<public_key_base64>
```

Duplicate JSON members (including nested key objects), unknown fields,
non-integer JSON numbers, malformed UTF-8, noncanonical Base64 and any private
or operational input are rejected. A resource is limited to 32 KiB. The bundle
packager reads a caller-supplied resource only from a regular non-symlink file,
validates this exact contract, and copies its captured bytes into the unsigned
candidate. Before a protected qualification can accept an archive, it reads
the in-archive V2 resource without extraction and binds its configuration
digest, repository, descriptor asset name, bundle/team identity, threshold and
ordered key-ID set to the reviewed durable release identity. It does not fetch,
publish, sign, stage, hand off, or activate an installer.

## Sealed composition-catalog trust resource V1

`ForgePlatformInstallerCompositionCatalogTrust.json` is a separate public,
code-signed resource for the catalog policy. It is a format contract only:
this repository commits no production resource or catalog signing key. A source
build without it remains fail-closed, and a release-trust key never becomes a
catalog-signing key merely because the two policies are bundled together.

The strict JSON object has exactly these fields:

```text
schema_version = 1
configuration_sha256
installer_release_trust_configuration_sha256
signature_threshold
ed25519_public_keys = [{ key_id, public_key_base64 }, ...]
```

`installer_release_trust_configuration_sha256` is the exact raw V2
release-trust configuration digest carried by the same released installer.
It scopes this independent catalog policy to that release-trust configuration;
it does not reuse its keys. `key_id` and `public_key_base64` use the same
strict, canonical Ed25519 rules as V2: keys are strictly ascending by key ID,
both IDs and key material are unique, there are at most sixteen keys, and the
threshold is from one through the key count.

`configuration_sha256` is lower-case SHA-256 of UTF-8 bytes formed by joining
these NUL-delimited tokens in this exact order, followed by the two key tokens
for each ascending key:

```text
forge-platform-installer-composition-catalog-trust-v1
schema_version=1
installer_release_trust_configuration_sha256=<raw V2 configuration digest>
signature_threshold=<threshold>
ed25519_public_key_count=<count>
ed25519_public_key_id=<key_id>
ed25519_public_key_base64=<public_key_base64>
```

The resource is at most 32 KiB and admits at most 64 nested containers and
16,384 JSON values. Duplicate JSON members (including nested key objects),
unknown fields, non-integer values, malformed UTF-8, noncanonical Base64,
wrong ordering, a configuration-digest mismatch and operational/secret fields
all fail closed. Its parser/JSON schema model only a public policy; they do not
create a signature verifier, persist an anchor, select a composition or make a
product change.

The native C-2a transport seam may fetch only the exact already-verified
catalog locator through a fresh credential-free HTTPS session. It rejects all
redirects, requires HTTP 200 and an exact final URL, bounds the response to the
catalog's 512 KiB limit, and exposes only the locator plus raw bytes. It does
not treat an HTTP `Date` header as trusted-clock evidence and is not yet wired
to session preparation, product selection, persistence, the wizard or a
release artifact. A later reviewed boundary must provide independent trusted
clock evidence and bind a verified terminal product operation before it can
persist a catalog acceptance.

The native C-2b acceptance store keeps the highest accepted catalog identity
in a private installer-owned file per scope. Its scope is exactly the raw V2
release-trust configuration digest, signed channel and exact catalog-feed URL;
the catalog-trust-resource digest is intentionally not part of that scope, so
policy rotation does not silently forget accepted provenance. A fixed
SHA-256-derived file name prevents a URL or scope string from becoming a path.
The store uses an independent non-blocking lock, secure `openat`/`mkdirat`
reads, `0700` directories, `0600` records, durable synchronization of a new
state root and each record directory with its parent, atomic fsync/rename
persistence, and strict JSON. It accepts no bare anchor: its only write input binds the
scope and catalog sequence/digest to `COMPLETE`, a bounded operation ID,
composition identity, manifest digest and opaque receipt reference. Lower
sequence and different bytes under the same sequence fail closed; an identical
catalog commitment is idempotent and does not overwrite its original terminal
binding.

C-2b is still unassembled. It neither verifies a product receipt nor invokes
a product operation, and no startup, runtime builder, catalog transport,
session preparer, wizard or packager calls it. A future product-owned
operation coordinator must create the terminal commitment only after it has
verified its own terminal receipts, readiness and cleanup.

## Sealed installer release provenance V1

`ForgePlatformInstallerReleaseProvenance.json` is a second, public,
code-signed bundle resource. It records the exact immutable release facts that
the final signed descriptor must repeat, without introducing a signing cycle:
the final descriptor/archive digests and CodeDirectory digest are deliberately
not fields of this resource. The strict public contract is
[`universal-installer-release-provenance.schema.json`](../../schemas/universal-installer-release-provenance.schema.json).
A source build has no provenance resource and remains fail-closed; the source
packager never manufactures one.

The object is at most 32 KiB, has exactly these fields, and contains no URL,
credential, private key, final archive digest, or notarization material:

```text
schema_version = 1
provenance_sha256
installer_version
channel = stable | candidate
release_sequence > 0
source_revision
policy_revision
capabilities = strictly sorted unique identifiers
release_trust_configuration_sha256
```

`release_sequence` is a positive unsigned 64-bit integer. Installer-version
components are stable decimal values that fit the native signed 64-bit
`InstallerVersion` representation; parser limits prevent a Python release
candidate that the native installer could not represent.

`provenance_sha256` is lower-case SHA-256 of NUL-delimited UTF-8 tokens in this
exact order:

```text
forge-platform-installer-release-provenance-v1
schema_version=1
installer_version=<installer_version>
channel=<channel>
release_sequence=<release_sequence>
source_revision=<source_revision>
policy_revision=<policy_revision>
release_trust_configuration_sha256=<configuration_sha256>
capability_count=<count>
capability=<capability>  (one per ascending capability)
```

The packager captures one regular, non-symlink input file before it creates the
bundle, validates strict UTF-8 JSON (including duplicate-key and non-finite
value rejection), and copies those captured bytes verbatim. A later protected
signer must prove that the signed app carries this exact semantic provenance;
it must not replace or infer it from a filename, version, or `PATH` result.
When release resources are supplied, the packager accepts the V2 trust resource
and V1 provenance resource only as a matched pair: their configuration digests
must agree, the trust resource's expected bundle identifier must equal the
packaged app, and provenance version/channel/capabilities must equal the
installer-version projection. A partial or mismatched pair fails before an
output bundle is written.

## Canonical GitHub Release descriptor identity

The signed `forge-platform.installer-release/v1` descriptor now contains one
strict `github_release` object: repository, tag, and descriptor asset name.
Every macOS asset contains a safe `.zip` asset name, archive
`sha256:<lowercase-hex>`, strict bundle and Apple Team identity, full raw
`code_directory_sha256`, and a typed opaque
`notarization_receipt_reference`. It contains no installer asset URL. The only
permitted archive URL is derived from the signed repository/tag/asset name as
the canonical GitHub Releases download location; a supplied URL or unsafe tag
or asset name fails closed. The separately signed composition catalog retains
its explicit HTTPS feed URL.

The descriptor also binds the raw V2
`release_trust_configuration_sha256` and the V1 `provenance_sha256`. The
durable installer-release identity, preparation, qualification and publication
evidence repeat those facts. A positive release sequence is reserved in the
durable release store while the candidate is `PREPARED`; a retry can reuse it
only for exactly the same operation, candidate bytes, source, policy, trust
configuration, provenance, identity and capabilities. This is source-level
collision protection, not a claim that a GitHub Release was created.
Publication evidence separately records the configured descriptor asset name,
the exact descriptor digest read back from that asset, and an opaque readback
receipt; a local generic descriptor filename is not upload or readback proof.
The current sealed V2 resource fixes the GitHub repository/descriptor locator
and app bundle/team identity used to admit a descriptor. Its configuration
digest identifies the currently running bundle; the descriptor's distinct
trust-configuration digest identifies the target bundle and may rotate only
through the verified staged-target path.

## Mandatory self-update

```text
verify own installed bundle identity
  → locate GitHub Release metadata
  → verify signed installer descriptor, expiry and monotonic sequence
  → verify macOS/architecture asset digest, signing and notarization
  → stage a newer installer in a private versioned area
  → write non-secret handoff evidence
  → launch the staged newer installer and exit the old process
  → only the newer installer may inspect a composition or mutate a platform
```

GitHub Releases transport bytes, but `latest`, a tag, title, filename, or HTTP success is not a trust root. The bootstrapper accepts only a signed `forge-platform.installer-release/v1` descriptor under its rotatable embedded public-key/threshold policy. The descriptor binds canonical GitHub repository/tag/descriptor-asset identity, sequence, channel, expiry, installer version/source revision, exact archive SHA-256, full CodeDirectory SHA-256, code-signing team/bundle identity, typed notarization receipt reference, capabilities, V2 trust-configuration digest, V1 provenance digest, and the signed **catalog-feed locator**. A same installer version with different source, bytes, capability declaration, feed locator, trust configuration, provenance, or signing identity fails closed rather than being overwritten.

Both the installer descriptor and composition catalog use only an explicit
public signature envelope: `{ "algorithm": "ed25519", "key_id": "…",
"signature": "…" }`. The signature is canonical unpadded base64url for the
64-byte Ed25519 result; opaque strings, mixed algorithms, duplicate key IDs,
unknown key IDs, and fewer than the reviewed threshold all fail before a
cryptographic verifier runs. Key IDs are public routing identities, not public
key material or credentials. The protected verifier resolves each ID through
its independently protected trust root and must verify every counted signature
under that exact policy. The current source identity remains `UNCONFIGURED`,
so it contains no production key IDs or public keys and cannot publish.

The catalog is a deliberately separate signed, expiring, monotonic feed. It contains immutable composition URLs/SHA-256 values and their installer requirements. Before any selection, the installer requires fresh feed-readback and trusted-clock evidence, verifies the catalog signature, channel, validity interval and locally retained highest accepted sequence/digest, then verifies each manifest against the selected catalog-entry digest. A lower sequence, or different bytes under an already accepted sequence, fails closed. This is what lets one compatible installer discover a later Forge/EP/Workspace composition without needlessly replacing its binary; a composition requiring an unavailable capability still requires a newer installer first. An unavailable, expired, unsigned, stale, architecture-incompatible, or unverifiable feed blocks platform mutation. An explicit offline bundle is allowed only when installer and catalog evidence were verified in advance under the same policy and still satisfy freshness/anti-replay rules.

The native C-1 admission kernel accepts at most 512 KiB of strict UTF-8
catalog bytes, with at most 64 nested containers and 16,384 JSON values. It
requires an injected trusted-clock readback whose freshness window is no more
than five minutes, exactly the catalog locator carried by the current verified
installer descriptor, and a separately reviewed catalog-key threshold policy.
Catalog composition identities are exact, non-normalized sequences of one to
256 Unicode scalars and exclude Unicode White_Space and C0/DEL controls across
the outer catalog, component-combination index, manifest, policy/journal
records, terminal commitment, schemas, qualifier and native session verifier.
That policy is explicitly scoped to the current installer V2
release-trust-configuration digest, but it has a separate key set: a
self-update key does not automatically become a catalog-signing key. C-1 only
returns internal verified outer-catalog evidence and a candidate anti-replay
anchor. It neither performs transport, downloads the index or manifest,
persists the candidate anchor, creates a session, nor makes a product change.
The later operation coordinator persists that anchor only together with the
verified terminal product-operation evidence, scoped by trust-configuration
digest, channel and exact catalog-feed locator.

The old process never starts component work while a newer verified installer is available. A crash/reboot after staging resumes the same non-secret handoff; it does not execute an arbitrary downloaded binary or silently continue with stale installer logic.

The release-side counterpart is equally restartable: the unsigned candidate
first becomes a durable, immutable `PREPARED` record under one operation ID,
including its candidate manifest and per-architecture digests. A later
qualification record must bind that exact prepared input as well as the signed
descriptor, release archives, CodeDirectory digests, typed notarization
receipts, sequence, trust configuration and provenance. Retrying with changed
source, policy, identity, capability, candidate bytes, signed bytes, sequence
or provenance under the same operation ID fails closed. `PREPARED`, `QUALIFIED`, `PUBLISHED`,
`CLEANUP_PENDING`, and `RELEASE_COMPLETE` are distinct evidence states; no
public side effect is inferred from an unsigned candidate or a lost response.

The checked-in GitHub Actions framework deliberately creates this journal only
inside its run artifact. It is useful for an individual candidate and remains
blocked before signing/publication, but it is not a protected cross-run durable
reservation store. Enabling protected publication requires a reviewed durable
shared operation/sequence store and GitHub Release readback reconciliation; a
new workflow dispatch must never treat a fresh artifact directory as proof
that an earlier sequence or operation did not exist.

### Component-combination selection index

The catalog has a versioned, digest-bound selection-index payload,
`forge-platform.component-combination-catalog/v1`, specified in
[`universal-installer-component-combination-catalog.schema.json`](../../schemas/universal-installer-component-combination-catalog.schema.json).
The signed outer `forge-platform.composition-catalog/v1` carries its explicit
optional `component_combination_catalog` locator (`url` plus SHA-256). The
optional field preserves parsing of older signed catalogs; trying to use the
component-set selector without the locator fails closed. The production parser
derives `CatalogPublicationBinding` only from a verified
`CompositionCatalog`, then checks the index's exact bytes against that signed
locator. It is not a second trust root and it is not an installer package. Its
entries bind all of the following:

- a composition identity, numeric selection sequence, exact manifest URL and
  digest;
- the exact component set, with an explicit installer capability set for every
  component type;
- a minimum installer version and the union of required installer capabilities;
  and
- explicit `upgrade_from` composition identities.

The resolver selects only an **exact** requested component set and the highest
published selection sequence with an explicit upgrade route. It never infers a
role from a filename, selects a component superset, or bypasses a newer entry
that needs an unavailable capability by silently offering an older tuple.
Instead it returns `INSTALLER_UPDATE_REQUIRED`; the ordinary self-update gate
must obtain and relaunch a trusted newer installer before the manifest is
fetched. The locally retained catalog sequence/digest prevents replay or a
different byte sequence under the same identity.

This lets a later composition advertise, for example,
`engineering-platform-execution-agent` with
`component-provisioner/engineering-platform-execution-agent/v1`. It does not
declare that component installable today and does not manufacture an EP
provisioner. A newly released installer may select it only after it actually
implements and advertises that capability; an older installer stops at the
self-update gate. The model is deliberately generic so a future component does
not require one installer package per Forge/EP/Workspace combination.

The selection-index parser and behavior checks are source-level policy work.
The protected publisher has not yet bound or published a real index, so no
current GitHub Release, installer, or Mac installation is claimed by this
contract.

## Native wizard and gates

The macOS application is a native SwiftUI shell over a bounded trusted coordinator. The UI never constructs a shell command from input, stores a credential, selects a product runtime, writes a product database, creates a product venv, or registers a service itself.

1. Self-update.
2. Verified signed composition/session selection. Its accepted immutable session binds the composition, catalog and manifest identities to its exact provider requirements; a provider projection cannot be supplied separately or before this gate.
3. Host preflight and managed-tool inventory for that accepted session.
4. Dynamic **Add providers** for the provider requirements bound to that same session.
5. Product-owned installation inventory and reviewed add/update/repair/remove diff for that same session.
6. Product-owned execution and cross-component readiness.
7. Final per-component status, installer-log reference, artifact identities, and only product-verified HTTP(S) links.

Every gate fails closed. A future privileged helper communicates only with the coordinator's fixed protocol and never becomes an alternative product provisioner.

## Managed tools and providers

Git and Python are inventoried and, where a qualified composition requires them, bootstrapped from installer-owned digest-pinned artifacts. The installer uses explicit managed-tool identities. It does not replace `/usr/bin/git`, a Homebrew installation, an arbitrary user Python, or a PATH-selected executable. A tool upgrade is explicit and must not mutate unrelated global toolchains. Product component venvs remain separate from managed tools and from every other component.

The dynamic provider screen can show Codex CLI and GitHub CLI independently as selected, optional, or required. For every enabled provider the state is `ABSENT → INSTALLED → AUTHENTICATION_REQUIRED → VERIFIED`. The wizard advances only when every enabled provider is `VERIFIED`; a selected optional provider therefore cannot be silently bypassed. If a profile requires both Codex and GitHub CLI, both are selected and both must finish installation, interactive authentication, and non-secret validation. Either failure blocks the next screen. Optional providers may be deselected only when the selected composition permits it. Vendor actions are fixed audited commands or UI handoffs; the UI never accepts command text. Credentials stay in provider user-scoped secure storage and never enter a system service, composition, receipt, diagnostic, or installer log.

A server-only profile can omit user-scoped provider requirements only when its qualified composition explicitly says so. This is not a bypass for a profile that needs a local Project Agent or interactive provider execution.

## macOS services, data, and isolation

On macOS, `launchd` is the native system service manager. “System service, not launchd” is therefore contradictory. This contract means:

- Forge Runtime/Server, EP Server, and Workspace Server use a product-owned, root-authorized **system-domain `LaunchDaemon`**, not a per-user `LaunchAgent` or `gui/<uid>` registration.
- An EP Project Agent and user-provider credentials remain user/host scoped because they may access local repositories and OS secure credential storage.
- Every server component has its own product-owned runtime/data root, database, logs, cache, backups, account/permission model, and isolated venv. No component shares a venv, database, data root, or service label with another product.

An existing per-user EP `LaunchAgent` to system-domain transition is an EP-owned provisioner/migration increment. Forge Platform may show the product contract and coordinate a qualified operation; it may not migrate EP service state or data itself.

## Discovery, diff, execution, and recovery

The installer reads product-owned inventory and update assessments through the component-operation delegation contract. It never infers an active component from a filename, wheel cache, arbitrary venv, `PATH`, service label, or HTTP reachability alone. A product readback identifies selected runtime, executable, server, instance, and identity-aware health evidence. For EP, a single operational installation also requires machine-wide inventory coverage and no conflict.

For EP, Forge Platform's boundary ends at an exact artifact/role request and the
EP-owned resolver/provisioner's correlated readback, update assessment and
execute/resume receipt. EP alone owns its installation record, runtime and
service selection, data compatibility, backup, migration, rollback, cleanup,
and operational lock; Forge Platform must not add a second EP provisioner.

| Observed state | Candidate action |
| --- | --- |
| component absent | product-owned install of the exact artifact |
| healthy exact artifact | retain/no change |
| healthy different artifact with `UPDATE_AVAILABLE` | product-owned update |
| exact artifact unhealthy | product-owned repair |
| unselected installation with a published product-uninstall dispatcher | product-owned remove |
| unknown/conflicting inventory, incompatible update, absent or not-yet-dispatchable removal contract, or identity mismatch | blocked |

No product mutation is dispatched until self-update, installer capability, preflight, managed-tool, provider, manifest, and component-diff gates pass. A managed Git/Python install or upgrade forces a completed managed-tool receipt and fresh post-tool plan fingerprint before the journal can enter product operations. The installer keeps an operation-specific non-secret journal outside product CENTRAL/data stores. It serializes one non-terminal host operation, records operation ID, installer/composition/artifact identities, state transitions, typed receipt references, and cleanup/recovery state; it never records tokens, credentials, raw provider output, or arbitrary paths.

The composition-level saga is `composition lock → exact artifact staging → product readback/compatibility → product-owned quiesce/backup/migrate/activate/verify/cleanup → authenticated discovery/pairing → cross-component readiness → receipt`.

Products own installation locks, backup, database migration, activation, service registration, health-content validation, rollback, cleanup, and crash/reboot resume. Forge Platform does not write product data or implement a second migration/rollback engine. Automatic rollback is offered only when affected products supply compatible rollback/restore receipts. An irreversible migration failure remains `RECOVERY_PENDING`, with necessary product recovery artifacts retained. Installer cleanup covers only its own staging/download/cache material; product backup retention is owned by the product contract.

Discovery produces a candidate only. Product APIs verify product, instance, fingerprint, and capability and execute authenticated pairing. A changed endpoint, instance, or fingerprint never silently replaces a pinned binding, including for co-located components.

## Current source and remaining work

Forge Platform now contains strict schemas and a tested policy kernel for signed-release selection, canonical GitHub Release identity, structured public signature envelopes and key-ID/threshold gating, sealed V2 trust-configuration and V1 provenance identities, fresh/trusted-clock feed gates, catalog signature/sequence/digest anti-replay, context-bound composition selection, installer capability checks, preflight, Git/Python planning, provider gating, system-service declaration checks, and read-only composition diffs. The native core now also has a tested C-1 outer-catalog admission kernel, shared strict canonical-JSON/Ed25519 verification primitives, canonical HTTPS validation, bounded JSON parsing, a source-level sealed catalog-trust resource loader, a credential-free exact-locator transport seam, and a durable per-scope catalog-anchor store. These remain deliberately unassembled: no source resource or production key exists, an absent resource fails closed, a catalog-host HTTP `Date` cannot establish trusted time, and no runtime/session/UI/product/packager path consumes the trust/transport/store seams. The store has no product receipt validator or production caller, so it cannot by itself create an accepted catalog. No component-index/manifest selector or session-plan producer exists yet. It also contains a tested native SwiftUI wizard shell, a separate installer release-operation journal with an immutable `PREPARED` candidate precursor and durable sequence reservation, and a source-only release workflow framework. That framework verifies an exact merged `main` candidate, requires its exact version-preparation receipt, requires a reviewed release-identity policy, records required public sequence/provenance inputs, packages an **unsigned** `.app` candidate without manufacturing sealed resources, records the digest of the exact staged archive, and binds the later operation/descriptor handoff to the configured GitHub repository, tag, descriptor asset name, archive asset names, bundle identifier, Team identifier, CodeDirectory digest and typed notarization receipt. Its signing/notarization and public-GitHub-Release environments deliberately fail closed until a real protected Apple signer, notarization adapter, native trust/provenance loader, descriptor verifier and publisher are configured. The structural handoff verifier enforces the public envelope shape and reviewed identity binding, but intentionally reports that cryptographic signature verification was not performed; it is never a publication authorization.

The structural verifier also reads V2 trust and V1 provenance resources directly
from every supplied archive and binds their semantic identities to the durable
reviewed release identity; it still does not authorize signing or publication.

Next owning increments are: package a separately reviewed code-signed catalog-trust policy and compose the existing trust/transport/storage seams only with independent trusted-clock evidence and a product-owned terminal-operation receipt validator, then add component-index/manifest selection only after an explicit preset/component-set and product-owned installed-composition readback exist; connect the protected signer/notarization/publisher to the installer release framework and qualify an actual GitHub Release; native trusted bootstrap/handoff; EP then Forge/Workspace execute/resume/uninstall adapters; managed-tool/provider coordinators that retain no secrets; and installed-artifact clean-Mac, add/update/remove, migration/rollback, reboot-recovery, pairing, readiness, and summary qualification.

Until those increments have their own evidence, this is `SOURCE_FIXED` for the installer foundation only, not `INSTALLATION_VERIFIED`, `SINGLE_OPERATIONAL_INSTALLATION_VERIFIED`, or release/publication authority.
