#!/usr/bin/env python3
"""Guard Forge Platform's durable, main-first production release ordering."""

from dataclasses import asdict
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from forge_platform.release_operation import ReleaseOperation, ReleaseOperationStore


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
        self.assertIn('ReleaseOperationStore(Path("release-input", "release-operation"))', workflow)
        self.assertIn("store.prepare_qualified(operation, evidence={", workflow)
        self.assertIn("qualified receipt does not match the durable operation journal", workflow)

    def test_publication_readback_is_immutable_and_terminal_cleanup_is_separate(self) -> None:
        workflow = Path(".github/workflows/forge-platform-production-release.yml").read_text(encoding="utf-8")

        self.assertIn("group: forge-platform-production-release", workflow)
        self.assertIn("cancel-in-progress: false", workflow)
        self.assertIn("forge-platform-release-published-$VERSION-$SOURCE_SHA.json", workflow)
        self.assertIn("store.mark_published(qualified, evidence={", workflow)
        self.assertNotIn('.transition("PUBLISHED"', workflow)
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
        self.assertIn('ReleaseOperationStore(Path("published-input", "release-operation"))', workflow)
        self.assertIn('current = store.replace(current, pending)', workflow)
        self.assertIn('ReleaseOperationStore.same_identity(current, pending)', workflow)
        self.assertIn("store.mark_cleanup_pending(", workflow)
        self.assertIn("complete = store.complete(", workflow)
        self.assertNotIn('.transition("CLEANUP_PENDING"', workflow)
        self.assertNotIn('.transition("RELEASE_COMPLETE"', workflow)
        self.assertIn('mv -- published-input/release-operation release-outcomes/release-operation', workflow)
        self.assertIn('for target in operation-readback pending-readback "published-input/$COMPOSITION"', workflow)
        self.assertLess(
            workflow.index('for target in operation-readback pending-readback "published-input/$COMPOSITION"'),
            workflow.index('gh release upload "$TAG" "release-outcomes/$COMPLETE"'),
        )
        self.assertLess(workflow.index('current = store.replace(current, pending)'), workflow.index("complete = store.complete("))
        self.assertIn("operation-local cleanup is pending; resume the same release operation", workflow)
        self.assertIn('test ! -e published-input', workflow)

    def test_failed_journal_staging_is_classified_as_cleanup_pending(self) -> None:
        workflow = Path(".github/workflows/forge-platform-production-release.yml").read_text(encoding="utf-8")

        move_failure = 'if ! mv -- published-input/release-operation release-outcomes/release-operation; then'
        cleanup_start = "          cleanup_failed=false"
        self.assertIn(move_failure, workflow)
        failure_branch = workflow[workflow.index(move_failure):workflow.index(cleanup_start, workflow.index(move_failure))]
        self.assertIn("A failed move is therefore a controlled", failure_branch)
        self.assertIn("store.recover_published(published)", failure_branch)
        self.assertIn('Path("release-outcomes", "release-operation")', failure_branch)
        self.assertIn('Path("published-input", "release-operation")', failure_branch)
        self.assertIn('Path("release-outcomes", "recovered-release-operation")', failure_branch)
        self.assertIn("pending = store.mark_cleanup_pending(", failure_branch)
        self.assertIn('gh release upload "$TAG" "release-outcomes/$PENDING"', failure_branch)
        self.assertIn("operation-local journal staging is pending; resume the same release operation", failure_branch)
        self.assertIn("exit 1", failure_branch)
        self.assertLess(
            failure_branch.index("store.recover_published(published)"),
            failure_branch.index("pending = store.mark_cleanup_pending("),
        )

    def test_move_failure_branch_records_cleanup_pending_from_remaining_journal(self) -> None:
        workflow = Path(".github/workflows/forge-platform-production-release.yml").read_text(encoding="utf-8")
        move_failure = 'if ! mv -- published-input/release-operation release-outcomes/release-operation; then'
        branch_start = workflow.index(move_failure)
        heredoc_start = workflow.index("            PYTHONPATH=. python3 - <<'PY'", branch_start)
        body_start = workflow.index("\n", heredoc_start) + 1
        body_end = workflow.index("            PY\n", body_start)
        body = "\n".join(
            line[12:] if line.startswith("            ") else line
            for line in workflow[body_start:body_end].splitlines()
        )

        with tempfile.TemporaryDirectory() as temporary:
            workdir = Path(temporary)
            (workdir / "forge_platform").symlink_to(ROOT / "forge_platform", target_is_directory=True)
            operation = ReleaseOperation.create(
                operation_id="release-0001",
                product="forge-platform",
                component="composition",
                version="2.3.0",
                policy_revision="forge-platform-production-release-v3",
                source_revision="a" * 40,
                artifacts={"composition_manifest": "sha256:" + "b" * 64},
            )
            qualification = {
                "exact_main_sha": operation.source_revision,
                "artifact_digests": dict(operation.artifacts),
                "composition_asset": "composition.json",
            }
            publication = {
                "registry": "github-release",
                "tag": "forge-platform-v2.3.0",
                "composition_asset": "composition.json",
                "artifact_digests": dict(operation.artifacts),
                "readback": "PASS",
            }
            source = ReleaseOperationStore(workdir / "published-input" / "release-operation")
            source.acquire(operation.operation_id)
            try:
                qualified = source.prepare_qualified(operation, evidence=qualification)
                published = source.mark_published(qualified, evidence=publication)
            finally:
                source.release(operation.operation_id)
            (workdir / "operation-readback").mkdir()
            (workdir / "operation-readback" / "published.json").write_text(
                json.dumps(asdict(published), indent=2, sort_keys=True, allow_nan=False) + "\n",
                encoding="utf-8",
            )
            (workdir / "release-outcomes").mkdir()
            # A file at the destination makes the exact staging move fail,
            # leaving the source journal available to the workflow branch.
            (workdir / "release-outcomes" / "release-operation").write_text("blocked", encoding="utf-8")
            environment = dict(os.environ)
            environment.update(
                {
                    "OPERATION_ID": operation.operation_id,
                    "COMPOSITION": "composition.json",
                    "QUALIFIED": "qualified.json",
                    "PUBLISHED": "published.json",
                    "PENDING": "pending.json",
                }
            )
            script = (
                "set -euo pipefail\n"
                f"{move_failure}\n"
                "  PYTHONPATH=. python3 - <<'PY'\n"
                f"{body}\n"
                "PY\n"
                "fi\n"
            )
            result = subprocess.run(
                ["bash", "-c", script],
                cwd=workdir,
                env=environment,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            pending = ReleaseOperation.parse(
                json.loads((workdir / "release-outcomes" / "pending.json").read_text(encoding="utf-8"))
            )
            self.assertEqual(pending.state, "CLEANUP_PENDING")
            self.assertEqual(pending.operation_id, operation.operation_id)


if __name__ == "__main__":
    unittest.main()
