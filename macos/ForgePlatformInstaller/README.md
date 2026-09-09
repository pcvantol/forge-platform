# Forge Platform Installer for macOS

This Swift Package contains the native SwiftUI wizard shell for the Forge
Platform Universal Installer. It is intentionally an orchestration UI, not a
second product installer engine.

The shell provides these gated screens:

- a mandatory self-update gate that accepts only a verified GitHub Release
  descriptor from a future trusted bootstrap coordinator;
- host-preflight evidence, including installer-owned Git and Python toolchain
  checks without selecting or modifying an unrelated global toolchain;
- a dynamic Codex CLI / GitHub CLI provider screen, with independent selection,
  install, authentication, and verification states;
- qualified composition-diff review;
- product-owned execution/readiness evidence; and
- an installation summary including product-supplied dashboard URLs and a
  `System LaunchDaemon` service scope where applicable.

An older installer cannot advance past the self-update gate. The core includes
`VerifiedInstallerSelfUpdateCoordinator.enforceCurrentInstaller`, which makes
startup update enforcement automatic once the app wires in trusted adapters: it
accepts a signed GitHub Release record, checks the sealed identity of the
running bundle, stages one exact release asset, verifies its SHA-256,
code-signature and notarization independently, and only then delegates an
atomic handoff/relaunch. A release sequence plus source, provenance and code
directory digests rejects rollback, replay and same-version/different-bytes
replacement. Required providers cannot be bypassed: every manifest-required
provider must be selected and in the `verified` state before the wizard can
continue.

The released app is wired through `ReleasedInstallerStartupBoundary`: it does
not construct a wizard with `UnavailableInstallerWizardCoordinator`, and it
does not offer a manual update bypass. The boundary first requires both sealed
release-trust and release-provenance resources, binds their exact trust-policy
digest, builds a trusted runtime from them, and calls automatic startup
enforcement. Only a `current` result creates the wizard; a relaunch or any
missing/invalid/mismatched resource stays on a fail-closed status screen.
Interrupted installer-only work is recorded in a separate non-secret recovery
journal with typed staged-file identity and handoff-receipt evidence. It is not
a product database or a component installation journal.

Before startup recovery, release qualification, staging, verification, or
handoff, a trusted runtime also obtains one non-blocking host-wide self-update
lease. The supplied file-backed implementation uses a permanent, installer
owned lock inode with restrictive permissions and an advisory kernel lock; a
busy or unsafe lock state blocks rather than racing a second installer. A
successful handoff keeps its lease until the old process exits (or `exec`s),
while the replacement retries that specific short handoff window only a bounded
number of times. Production composition must place this state root under its
privileged, machine-wide installer controller. A per-user directory does not
prove cross-account uniqueness.

The sealed trust descriptor is a public V2 policy resource named
`ForgePlatformInstallerReleaseTrust.json`. It has exact fields for the GitHub
repository, the fixed `github-release-asset-v1` descriptor convention and
asset name, expected bundle/team identity, threshold, and ordered Ed25519 key
IDs plus canonical Base64-encoded public keys. Its SHA-256 covers a
domain-separated, NUL-delimited representation of those accepted semantics.
The package's bundle packager validates that exact V2 form and copies an
explicit, non-symlink resource verbatim; source builds carry no resource and
therefore fail closed. The descriptor never contains a private key, credential,
URL, arbitrary transport setting, product authority, or installed-component
state.

The descriptor is checked inside a strictly validated macOS code-signed bundle
and is bound separately into signed release/current/staged-bundle identity
checks. Its checksum is not a substitute for code signing or the signed
release-feed trust root; those remain required and absent configuration still
fails closed.

The separate public V1 resource
`ForgePlatformInstallerReleaseProvenance.json` binds stable installer version,
channel, positive release sequence, source and policy revisions, sorted
capabilities, and the exact V2 release-trust configuration digest. Its own
digest uses an explicit NUL-delimited canonical representation. The startup
boundary rejects an absent, malformed, unsealed, installer-version-mismatched,
or trust-configuration-mismatched provenance record before it builds a runtime
or shows the wizard.
The model exposes only a pure exact-identity comparison for a future signed
descriptor verifier; it does not fetch a feed, authorize an update, stage
bytes, or grant product authority. Source builds carry no provenance resource
and remain fail-closed.

The default coordinator fails closed. This package deliberately ships no real
release URL, signing key, credential, shell invocation, privileged helper or
product adapter. A production composition must inject implementations for the
signed-feed verifier, current-bundle inspector, operation-owned downloader,
SHA-256/code-signature/notarization verifier and atomic handoff. The core never
constructs commands from UI input, stores credentials, changes global
Git/Python tooling, writes a product database, selects a runtime, creates a
venv, or installs/modifies a service. Product-adapter integration remains under
the product-owned contracts in the repository architecture.

The unsigned app-layout helper accepts a release-trust descriptor only through
an explicit `--sealed-release-trust-resource PATH` argument. It validates the
native loader's exact three-field v1 JSON shape and canonical digest, rejects
symlinks, duplicate/unknown fields and explicit key-material fields, then
copies the caller's validated bytes verbatim to
`Contents/Resources/ForgePlatformInstallerReleaseTrust.json`. It never finds,
generates or defaults a production identity, repository, URL, public/private
key or credential. Omitting that argument leaves the resource absent, so the
candidate remains fail-closed until a protected release packager supplies a
reviewed non-secret descriptor and code-signs the completed bundle.

Run the pure state-machine tests on macOS:

```sh
cd macos/ForgePlatformInstaller
swift test
```
