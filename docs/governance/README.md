# Governance

`main` is the protected canonical branch. After the empty-repository bootstrap, reviewable work flows through pull requests. The repository follows the current family single-maintainer model: zero mandatory approvals, resolved review conversations, linear protected history, and squash-only merge for reviewable work.

The `Forge Platform main integrity` ruleset protects the default branch with deletion and force-push protection, pull-request enforcement, conversation resolution, and the existing `Foundation validation` required check.

This foundation does not alter any product repository, central authority, production service, or runtime state.
