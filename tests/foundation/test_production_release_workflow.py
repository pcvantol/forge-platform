#!/usr/bin/env python3
"""Guard Forge Platform's durable, main-first production release ordering."""

from pathlib import Path
import unittest


class ProductionReleaseWorkflowTests(unittest.TestCase):
    def test_qualified_operation_is_retained_before_publication_and_uses_full_main_sha(self) -> None:
        workflow = Path(".github/workflows/forge-platform-production-release.yml").read_text(encoding="utf-8")

        qualify = workflow.index("  qualify-composition:")
        retain = workflow.index("  retain-qualified-release-operation:")
        publish = workflow.index("  publish-or-verify-published-evidence:")
        complete = workflow.index("  record-release-complete:")
        self.assertLess(qualify, retain)
        self.assertLess(retain, publish)
        self.assertLess(publish, complete)
        self.assertIn("operation_id: ${{ steps.context.outputs.operation_id }}", workflow)
        self.assertIn('OPERATION_ID="forge-platform-$VERSION-$SOURCE_SHA"', workflow)
        self.assertIn('test "$SOURCE_SHA" = "$(git rev-parse origin/main)"', workflow)
        self.assertIn("--verify-artifacts", workflow)
        self.assertIn("forge-platform-release-qualified-$VERSION-$SOURCE_SHA.json", workflow)
        self.assertIn('gh release create "$TAG" --draft --target "$SOURCE_SHA"', workflow)
        self.assertIn("existing release has no durable QUALIFIED provenance", workflow)
        self.assertLess(
            workflow.index('gh release upload "$TAG" "release-input/$QUALIFIED"'),
            workflow.index('gh release upload "$TAG" "release-input/$COMPOSITION"'),
        )
        self.assertIn('cmp "release-input/$QUALIFIED" "qualified-readback/$QUALIFIED"', workflow)
        self.assertIn('qualified.operation_id != os.environ["OPERATION_ID"]', workflow)
        self.assertIn('qualified.qualification != {', workflow)

    def test_publication_readback_is_immutable_and_terminal_cleanup_is_separate(self) -> None:
        workflow = Path(".github/workflows/forge-platform-production-release.yml").read_text(encoding="utf-8")

        self.assertIn("group: forge-platform-production-release", workflow)
        self.assertIn("cancel-in-progress: false", workflow)
        self.assertIn("forge-platform-release-published-$VERSION-$SOURCE_SHA.json", workflow)
        self.assertIn('qualified.transition("PUBLISHED"', workflow)
        self.assertIn('gh release download "$TAG" --pattern "$COMPOSITION" --dir operation-readback', workflow)
        self.assertIn('cmp "release-input/$COMPOSITION" "operation-readback/$COMPOSITION"', workflow)
        self.assertIn("public release lacks durable PUBLISHED provenance", workflow)
        self.assertIn("PUBLISHED release lacks its immutable composition asset", workflow)
        published_record = workflow.index('gh release upload "$TAG" "release-input/$PUBLISHED"')
        public_release = workflow.index('gh release edit "$TAG" --draft=false')
        self.assertLess(published_record, public_release)
        self.assertIn('test "$(gh release view "$TAG" --json isDraft --jq .isDraft)" = false', workflow)
        self.assertIn('gh release download "$TAG" --pattern "$COMPOSITION" --pattern "$PUBLISHED" --dir public-readback', workflow)
        self.assertIn('cmp "release-input/$PUBLISHED" "public-readback/$PUBLISHED"', workflow)
        self.assertIn("forge-platform-release-cleanup-pending-$VERSION-$SOURCE_SHA.json", workflow)
        self.assertIn('published.transition("CLEANUP_PENDING"', workflow)
        self.assertIn('published.transition("RELEASE_COMPLETE"', workflow)
        self.assertIn('for target in operation-readback pending-readback "published-input/$COMPOSITION"', workflow)
        self.assertLess(
            workflow.index('for target in operation-readback pending-readback "published-input/$COMPOSITION"'),
            workflow.index('gh release upload "$TAG" "release-outcomes/$COMPLETE"'),
        )
        self.assertIn("operation-local cleanup is pending; resume the same release operation", workflow)
        self.assertIn('test ! -e published-input', workflow)


if __name__ == "__main__":
    unittest.main()
