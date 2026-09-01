# Installer security boundary

The intended installer architecture follows these invariants:

- acquire only trusted, published artifacts;
- verify artifact digests and supported signature/provenance evidence;
- use least privilege and explicit service registration;
- keep secrets out of repository configuration and deployment receipts;
- never bypass localhost trust; and
- use real consumer credentials for local components.

Security qualification and signing/notarization testing are future Forge Platform-specific validation concerns. This repository contains neither privileged installer code nor production credentials.
