#!/usr/bin/env python3
"""Guard the durable release-state ordering required by production delivery."""

from pathlib import Path
import unittest


class ProductionReleaseWorkflowTests(unittest.TestCase):
    def test_published_evidence_precedes_terminal_completion_and_release_is_serialized(self) -> None:
        workflow = Path(".github/workflows/forge-platform-production-release.yml").read_text(encoding="utf-8")

        published_job = workflow.index("  publish-or-verify-published-evidence:")
        complete_job = workflow.index("  record-release-complete:")
        self.assertLess(published_job, complete_job)
        self.assertIn("group: forge-platform-production-release", workflow)
        self.assertIn("cancel-in-progress: false", workflow)
        self.assertIn("forge-platform-release-published-$VERSION-$SOURCE_SHA.json", workflow)
        self.assertIn('qualified.transition("PUBLISHED"', workflow)
        self.assertIn('published.transition("RELEASE_COMPLETE"', workflow)
        self.assertIn('test "$SOURCE_SHA" = "$(git rev-parse origin/main)"', workflow)
        self.assertIn("--verify-artifacts", workflow)
        self.assertIn("gh release download \"$TAG\" --pattern \"$COMPOSITION\" --dir registry-readback", workflow)
        self.assertIn("cmp \"release-assets/$COMPOSITION\" \"registry-readback/$COMPOSITION\"", workflow)
        self.assertIn("gh release view \"$TAG\" --json assets --jq '.assets[].name'", workflow)
        self.assertIn("gh release download \"$TAG\" --pattern \"$COMPOSITION\" --pattern \"$PUBLISHED\" --dir release-evidence", workflow)
        self.assertIn("test ! -e release-evidence", workflow)


if __name__ == "__main__":
    unittest.main()
