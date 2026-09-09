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
atomic handoff/relaunch. A release sequence plus source, metadata and code
directory digests rejects rollback, replay and same-version/different-bytes
replacement. Required providers cannot be bypassed: every manifest-required
provider must be selected and in the `verified` state before the wizard can
continue.

The default coordinator fails closed. This package deliberately ships no real
release URL, signing key, credential, shell invocation, privileged helper or
product adapter. A production composition must inject implementations for the
signed-feed verifier, current-bundle inspector, operation-owned downloader,
SHA-256/code-signature/notarization verifier and atomic handoff. The core never
constructs commands from UI input, stores credentials, changes global
Git/Python tooling, writes a product database, selects a runtime, creates a
venv, or installs/modifies a service. Product-adapter integration remains under
the product-owned contracts in the repository architecture.

Run the pure state-machine tests on macOS:

```sh
cd macos/ForgePlatformInstaller
swift test
```
