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

An older installer cannot advance past the self-update gate. Required providers
cannot be bypassed: every manifest-required provider must be selected and in the
`verified` state before the wizard can continue.

The default coordinator fails closed. It intentionally does **not** download
artifacts, invoke a shell, construct commands from UI input, store credentials,
change global Git/Python tooling, write a product database, select a runtime,
create a venv, or install/modify a service. A later signed/bootstrap and
product-adapter integration must implement those bounded operations under the
contracts in the repository architecture.

Run the pure state-machine tests on macOS:

```sh
cd macos/ForgePlatformInstaller
swift test
```
