#!/usr/bin/env python3
"""Behavior checks for the exact managed-Python runtime executor."""

from __future__ import annotations

from dataclasses import replace
from hashlib import sha256
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from forge_platform.managed_python_runtime_executor import (
    ExactAssetFetchReceipt,
    MANAGED_PYTHON_ARCHIVE_LAYOUT,
    MANAGED_PYTHON_INTERPRETER_RELATIVE_PATH,
    ManagedPythonActivationReceipt,
    ManagedPythonArchiveInspection,
    ManagedPythonRuntimeExecutionRequest,
    ManagedPythonRuntimeExecutionStore,
    ManagedPythonRuntimeExecutor,
    ManagedPythonRollbackReceipt,
    ManagedPythonRuntimeSlotReceipt,
    ProductVenvExecutionReceipt,
)
from forge_platform.universal_installer import (
    DownloadIdentity,
    ManagedPythonRuntimeAction,
    ManagedPythonRuntimeIdentity,
    ManagedPythonRuntimeReadback,
    ProductVenvRequirement,
    UniversalInstallerError,
    plan_managed_python_runtime,
)


ASSETS = {
    "runtime": b"thin-arm64-runtime-archive",
    "source": b"cpython-upstream-source",
    "source_provenance": b'{"source":"verified"}',
    "build_provenance": b'{"build":"verified-arm64"}',
}


def digest(data: bytes) -> str:
    return "sha256:" + sha256(data).hexdigest()


def python_identity() -> ManagedPythonRuntimeIdentity:
    payload: dict[str, object] = {
        "schema": "forge-platform.managed-python-runtime/v1",
        "implementation": "cpython",
        "version": "3.14.7",
        "operating_system": "macos",
        "architecture": "arm64",
        "minimum_macos_version": "26.0.0",
        "build_variant": "standard-gil",
        "python_tag": "cp314",
        "abi_tag": "cp314",
        "platform_tag": "macosx_26_0_arm64",
        "artifact_kind": "forge-platform-managed-python-runtime-archive-v1",
        "managed_root_identity": "forge-platform-managed-python-v1",
        "artifact": {"url": "https://assets.example.invalid/python-runtime", "digest": digest(ASSETS["runtime"])},
        "source": {"url": "https://assets.example.invalid/python-source", "digest": digest(ASSETS["source"])},
        "source_provenance": {
            "url": "https://assets.example.invalid/python-source-provenance",
            "digest": digest(ASSETS["source_provenance"]),
        },
        "build_provenance": {
            "url": "https://assets.example.invalid/python-build-provenance",
            "digest": digest(ASSETS["build_provenance"]),
        },
        "policy_revision": "python-runtime-policy-1",
    }
    material = json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode()
    payload["identity_digest"] = digest(material)
    return ManagedPythonRuntimeIdentity.from_mapping(payload)


def request(*, operation_id: str = "python-operation-001", previous: str | None = None) -> ManagedPythonRuntimeExecutionRequest:
    identity = python_identity()
    if previous is None:
        readback = ManagedPythonRuntimeReadback(
            "ABSENT", None, None, None, (), "receipt:initial-python-absent"
        )
    else:
        readback = ManagedPythonRuntimeReadback(
            "ACTIVE",
            previous,
            "forge-platform-managed-python-v1",
            "sha256-" + previous.removeprefix("sha256:"),
            (),
            "receipt:initial-python-active",
        )
    action = plan_managed_python_runtime(identity, readback)
    venvs = tuple(
        ProductVenvRequirement(component, venv, identity.identity_digest)
        for component, venv in (
            ("engineering-platform-server", "engineering-platform-server-primary"),
            ("forge-runtime", "forge-runtime-primary"),
            ("workspace-server", "workspace-server-primary"),
        )
    )
    return ManagedPythonRuntimeExecutionRequest(operation_id, action, venvs)


class FakeTransport:
    def __init__(self, assets: dict[str, bytes] | None = None) -> None:
        self.assets = dict(ASSETS if assets is None else assets)
        self.calls: list[tuple[str, str, Path]] = []

    def fetch(
        self,
        role: str,
        locator: DownloadIdentity,
        destination: Path,
    ) -> ExactAssetFetchReceipt:
        self.calls.append((role, locator.url, destination))
        destination.write_bytes(self.assets[role])
        return ExactAssetFetchReceipt(
            role,
            locator.url,
            locator.url,
            digest(self.assets[role]),
            len(self.assets[role]),
            f"receipt:transport-{role}",
        )


class FakeInspector:
    def __init__(self) -> None:
        self.calls = 0
        self.override_architectures: tuple[str, ...] | None = None
        self.override_build_provenance: str | None = None

    def inspect(
        self,
        identity: ManagedPythonRuntimeIdentity,
        assets: dict[str, Path],
    ) -> ManagedPythonArchiveInspection:
        self.calls += 1
        self.assets = assets
        return ManagedPythonArchiveInspection(
            identity.identity_digest,
            identity.artifact.digest,
            identity.source.digest,
            identity.source_provenance.digest,
            self.override_build_provenance or identity.build_provenance.digest,
            MANAGED_PYTHON_ARCHIVE_LAYOUT,
            MANAGED_PYTHON_INTERPRETER_RELATIVE_PATH,
            self.override_architectures or ("arm64",),
            26,
            "cpython",
            "3.14.7",
            "standard-gil",
            "cp314",
            "cp314",
            "macosx_26_0_arm64",
            "python-runtime-policy-1",
            "receipt:archive-inspection",
        )


class FakeMutation:
    def __init__(self, *, previous: str | None = None) -> None:
        self.runtime_slots: dict[str, ManagedPythonRuntimeSlotReceipt] = {}
        self.venvs: dict[str, ProductVenvExecutionReceipt] = {}
        self.previous = previous
        self.active: str | None = previous
        self.retained: tuple[str, ...] = ()
        self.install_calls = 0
        self.venv_calls: list[str] = []
        self.activation_calls = 0
        self.fail_after_first_install = False
        self._failed_once = False

    def read_runtime_slot(
        self,
        operation_id: str,
        runtime_identity: str,
        runtime_slot_identity: str,
    ) -> ManagedPythonRuntimeSlotReceipt | None:
        return self.runtime_slots.get(runtime_slot_identity)

    def install_runtime_slot(
        self,
        operation_id: str,
        identity: ManagedPythonRuntimeIdentity,
        runtime_slot_identity: str,
        verified_archive: Path,
        inspection: ManagedPythonArchiveInspection,
    ) -> ManagedPythonRuntimeSlotReceipt:
        self.install_calls += 1
        receipt = ManagedPythonRuntimeSlotReceipt(
            operation_id,
            identity.identity_digest,
            "forge-platform-managed-python-v1",
            runtime_slot_identity,
            identity.artifact.digest,
            MANAGED_PYTHON_INTERPRETER_RELATIVE_PATH,
            ("arm64",),
            26,
            "READY",
            "receipt:runtime-slot",
        )
        self.runtime_slots[runtime_slot_identity] = receipt
        if self.fail_after_first_install and not self._failed_once:
            self._failed_once = True
            raise RuntimeError("simulated crash after durable runtime install")
        return receipt

    def read_product_venv(
        self,
        operation_id: str,
        requirement: ProductVenvRequirement,
        runtime_slot_identity: str,
    ) -> ProductVenvExecutionReceipt | None:
        return self.venvs.get(requirement.venv_identity)

    def ensure_product_venv(
        self,
        operation_id: str,
        requirement: ProductVenvRequirement,
        runtime_slot_identity: str,
    ) -> ProductVenvExecutionReceipt:
        self.venv_calls.append(requirement.venv_identity)
        receipt = ProductVenvExecutionReceipt(
            operation_id,
            requirement.component_identity,
            requirement.venv_identity,
            requirement.python_runtime_identity,
            runtime_slot_identity,
            "READY",
            f"receipt:venv-{requirement.component_identity}",
        )
        self.venvs[requirement.venv_identity] = receipt
        return receipt

    def read_active_runtime(self) -> ManagedPythonRuntimeReadback:
        if self.active is None:
            return ManagedPythonRuntimeReadback(
                "ABSENT", None, None, None, (), "receipt:active-runtime-absent"
            )
        return ManagedPythonRuntimeReadback(
            "ACTIVE",
            self.active,
            "forge-platform-managed-python-v1",
            "sha256-" + self.active.removeprefix("sha256:"),
            self.retained,
            "receipt:active-runtime-readback",
        )

    def activate_runtime(
        self,
        operation_id: str,
        runtime_identity: str,
        runtime_slot_identity: str,
        retained_runtime_identity: str | None,
    ) -> ManagedPythonActivationReceipt:
        self.activation_calls += 1
        self.active = runtime_identity
        self.retained = () if retained_runtime_identity is None else (retained_runtime_identity,)
        return ManagedPythonActivationReceipt(
            operation_id,
            runtime_identity,
            runtime_slot_identity,
            retained_runtime_identity,
            "ACTIVE",
            "receipt:runtime-activation",
        )

    def rollback_runtime(
        self,
        operation_id: str,
        restored_runtime_identity: str,
        restored_runtime_slot_identity: str,
        retained_failed_runtime_identity: str,
    ) -> ManagedPythonRollbackReceipt:
        self.active = restored_runtime_identity
        self.retained = (retained_failed_runtime_identity,)
        return ManagedPythonRollbackReceipt(
            operation_id,
            restored_runtime_identity,
            restored_runtime_slot_identity,
            retained_failed_runtime_identity,
            "ROLLED_BACK",
            "receipt:runtime-rollback",
            "receipt:active-runtime-readback",
        )


class ManagedPythonRuntimeExecutorTests(unittest.TestCase):
    def execute(
        self,
        execution_request: ManagedPythonRuntimeExecutionRequest,
        transport: FakeTransport | None = None,
        inspector: FakeInspector | None = None,
        mutation: FakeMutation | None = None,
    ) -> tuple[object, FakeTransport, FakeInspector, FakeMutation, ManagedPythonRuntimeExecutionStore]:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        store = ManagedPythonRuntimeExecutionStore(Path(self.temporary.name) / "managed-python")
        transport = transport or FakeTransport()
        inspector = inspector or FakeInspector()
        mutation = mutation or FakeMutation(previous=execution_request.rollback_runtime_identity)
        receipt = ManagedPythonRuntimeExecutor(store).execute(
            execution_request, transport, inspector, mutation
        )
        return receipt, transport, inspector, mutation, store

    def test_installs_exact_inputs_one_immutable_slot_and_three_isolated_venvs(self) -> None:
        execution_request = request()
        old_path = os.environ.get("PATH")
        os.environ["PATH"] = "/untrusted/python/on/path"
        self.addCleanup(lambda: os.environ.__setitem__("PATH", old_path or ""))

        receipt, transport, inspector, mutation, store = self.execute(execution_request)

        self.assertEqual(receipt.state, "COMPLETE")
        self.assertEqual(receipt.runtime_identity, execution_request.target.identity_digest)
        self.assertEqual(receipt.runtime_slot_identity, execution_request.runtime_slot_identity)
        self.assertEqual(
            receipt.installer_journal_evidence("a" * 64)["python_runtime_receipt_reference"],
            f"receipt:managed-python-{execution_request.operation_id}",
        )
        self.assertEqual([call[0] for call in transport.calls], list(ASSETS))
        self.assertEqual(inspector.calls, 1)
        self.assertEqual(mutation.install_calls, 1)
        self.assertEqual(
            mutation.venv_calls,
            [item.venv_identity for item in execution_request.product_venvs],
        )
        self.assertEqual(len(set(mutation.venv_calls)), 3)
        record = store.load(execution_request.operation_id)
        self.assertIsNotNone(record)
        self.assertEqual(record.state, "COMPLETE")
        self.assertEqual(oct(store.root.stat().st_mode & 0o777), "0o700")
        self.assertEqual(
            oct((store.operation_directory(execution_request.operation_id) / "record.json").stat().st_mode & 0o777),
            "0o600",
        )
        self.assertFalse(hasattr(execution_request, "path"))

    def test_wrong_download_digest_fails_before_inspection_or_mutation(self) -> None:
        bad_assets = dict(ASSETS)
        bad_assets["runtime"] = b"substituted-runtime"
        transport = FakeTransport(bad_assets)
        inspector = FakeInspector()
        mutation = FakeMutation()
        with tempfile.TemporaryDirectory() as temporary:
            store = ManagedPythonRuntimeExecutionStore(Path(temporary) / "managed-python")
            with self.assertRaisesRegex(UniversalInstallerError, "exact signed asset"):
                ManagedPythonRuntimeExecutor(store).execute(request(), transport, inspector, mutation)
        self.assertEqual(inspector.calls, 0)
        self.assertEqual(mutation.install_calls, 0)

    def test_wrong_architecture_or_provenance_fails_before_runtime_install(self) -> None:
        for mode in ("architecture", "provenance"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as temporary:
                inspector = FakeInspector()
                if mode == "architecture":
                    inspector.override_architectures = ("arm64", "x86_64")
                    expected = "thin arm64"
                else:
                    inspector.override_build_provenance = "sha256:" + "f" * 64
                    expected = "build_provenance_digest"
                mutation = FakeMutation()
                store = ManagedPythonRuntimeExecutionStore(Path(temporary) / "managed-python")
                with self.assertRaisesRegex((ValueError, UniversalInstallerError), expected):
                    ManagedPythonRuntimeExecutor(store).execute(
                        request(operation_id=f"python-{mode}"),
                        FakeTransport(),
                        inspector,
                        mutation,
                    )
                self.assertEqual(mutation.install_calls, 0)

    def test_upgrade_retains_previous_exact_runtime_for_rollback(self) -> None:
        previous = "sha256:" + "0" * 64
        execution_request = request(previous=previous)
        receipt, _, _, mutation, _ = self.execute(
            execution_request,
            mutation=FakeMutation(previous=previous),
        )
        self.assertEqual(receipt.rollback_runtime_identity, previous)
        self.assertEqual(mutation.retained, (previous,))
        self.assertIn(previous, mutation.read_active_runtime().retained_runtime_identities)

    def test_rollback_restores_only_frozen_previous_runtime_and_retains_failed_target(self) -> None:
        previous = "sha256:" + "0" * 64
        execution_request = request(operation_id="python-rollback", previous=previous)
        with tempfile.TemporaryDirectory() as temporary:
            store = ManagedPythonRuntimeExecutionStore(Path(temporary) / "managed-python")
            executor = ManagedPythonRuntimeExecutor(store)
            mutation = FakeMutation(previous=previous)
            executor.execute(execution_request, FakeTransport(), FakeInspector(), mutation)
            receipt = executor.rollback(execution_request, mutation)
            self.assertEqual(receipt.restored_runtime_identity, previous)
            self.assertEqual(
                receipt.retained_failed_runtime_identity,
                execution_request.target.identity_digest,
            )
            self.assertEqual(store.load(execution_request.operation_id).state, "ROLLED_BACK")
            self.assertEqual(executor.rollback(execution_request, mutation), receipt)
            with self.assertRaisesRegex(UniversalInstallerError, "cannot reactivate"):
                executor.execute(execution_request, FakeTransport(), FakeInspector(), mutation)

    def test_install_without_previous_runtime_cannot_claim_rollback(self) -> None:
        execution_request = request(operation_id="python-no-rollback")
        with tempfile.TemporaryDirectory() as temporary:
            store = ManagedPythonRuntimeExecutionStore(Path(temporary) / "managed-python")
            executor = ManagedPythonRuntimeExecutor(store)
            mutation = FakeMutation()
            executor.execute(execution_request, FakeTransport(), FakeInspector(), mutation)
            with self.assertRaisesRegex(UniversalInstallerError, "no frozen rollback"):
                executor.rollback(execution_request, mutation)

    def test_crash_after_runtime_install_resumes_from_readback_without_redownload_or_reinstall(self) -> None:
        execution_request = request(operation_id="python-resume")
        mutation = FakeMutation()
        mutation.fail_after_first_install = True
        transport = FakeTransport()
        inspector = FakeInspector()
        with tempfile.TemporaryDirectory() as temporary:
            store = ManagedPythonRuntimeExecutionStore(Path(temporary) / "managed-python")
            executor = ManagedPythonRuntimeExecutor(store)
            with self.assertRaisesRegex(RuntimeError, "simulated crash"):
                executor.execute(execution_request, transport, inspector, mutation)
            self.assertEqual(store.load(execution_request.operation_id).state, "VERIFIED")
            receipt = ManagedPythonRuntimeExecutor(store).execute(
                execution_request, transport, inspector, mutation
            )
        self.assertEqual(receipt.state, "COMPLETE")
        self.assertEqual(len(transport.calls), 4)
        self.assertEqual(inspector.calls, 1)
        self.assertEqual(mutation.install_calls, 1)

    def test_same_operation_rejects_changed_runtime_or_venv_identity(self) -> None:
        execution_request = request(operation_id="python-frozen")
        receipt, transport, inspector, mutation, store = self.execute(execution_request)
        self.assertEqual(receipt.state, "COMPLETE")
        changed = replace(
            execution_request,
            product_venvs=(
                replace(execution_request.product_venvs[0], venv_identity="changed-venv"),
                *execution_request.product_venvs[1:],
            ),
        )
        with self.assertRaisesRegex(UniversalInstallerError, "different immutable inputs"):
            ManagedPythonRuntimeExecutor(store).execute(changed, transport, inspector, mutation)

    def test_forged_runtime_action_cannot_bypass_planner_readback(self) -> None:
        execution_request = request(operation_id="python-forged-action")
        forged = ManagedPythonRuntimeAction(
            "NO_CHANGE",
            "caller-forged no-op",
            execution_request.target,
            execution_request.runtime_action.readback,
            None,
        )
        with self.assertRaisesRegex(UniversalInstallerError, "does not match trusted readback"):
            ManagedPythonRuntimeExecutionRequest(
                execution_request.operation_id,
                forged,
                execution_request.product_venvs,
            )

    def test_corrupt_captured_asset_blocks_reboot_resume(self) -> None:
        execution_request = request(operation_id="python-corrupt-resume")
        mutation = FakeMutation()
        mutation.fail_after_first_install = True
        with tempfile.TemporaryDirectory() as temporary:
            store = ManagedPythonRuntimeExecutionStore(Path(temporary) / "managed-python")
            executor = ManagedPythonRuntimeExecutor(store)
            with self.assertRaises(RuntimeError):
                executor.execute(execution_request, FakeTransport(), FakeInspector(), mutation)
            store.asset_path(execution_request.operation_id, "runtime").write_bytes(b"changed")
            with self.assertRaisesRegex(UniversalInstallerError, "changed after acquisition"):
                executor.execute(execution_request, FakeTransport(), FakeInspector(), mutation)

    def test_tampered_terminal_receipt_is_rejected_during_durable_readback(self) -> None:
        execution_request = request(operation_id="python-tampered-record")
        receipt, _, _, _, store = self.execute(execution_request)
        path = store.operation_directory(execution_request.operation_id) / "record.json"
        payload = json.loads(path.read_text())
        payload["terminal_receipt"]["runtime_identity"] = "sha256:" + "f" * 64
        payload["terminal_receipt"]["runtime_slot_identity"] = "sha256-" + "f" * 64
        path.write_text(json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n")
        with self.assertRaisesRegex(UniversalInstallerError, "record is invalid"):
            store.load(execution_request.operation_id)
        self.assertEqual(receipt.runtime_identity, execution_request.target.identity_digest)

    def test_mismatched_venv_receipt_fails_before_activation(self) -> None:
        class WrongVenvMutation(FakeMutation):
            def ensure_product_venv(
                self,
                operation_id: str,
                requirement: ProductVenvRequirement,
                runtime_slot_identity: str,
            ) -> ProductVenvExecutionReceipt:
                receipt = super().ensure_product_venv(
                    operation_id, requirement, runtime_slot_identity
                )
                return replace(receipt, python_runtime_identity="sha256:" + "f" * 64)

        mutation = WrongVenvMutation()
        with tempfile.TemporaryDirectory() as temporary:
            store = ManagedPythonRuntimeExecutionStore(Path(temporary) / "managed-python")
            with self.assertRaisesRegex((ValueError, UniversalInstallerError), "runtime slot"):
                ManagedPythonRuntimeExecutor(store).execute(
                    request(operation_id="python-wrong-venv"),
                    FakeTransport(),
                    FakeInspector(),
                    mutation,
                )
        self.assertEqual(mutation.activation_calls, 0)

    def test_second_nonterminal_operation_is_rejected(self) -> None:
        first = request(operation_id="python-first")
        second = request(operation_id="python-second")
        with tempfile.TemporaryDirectory() as temporary:
            store = ManagedPythonRuntimeExecutionStore(Path(temporary) / "managed-python")
            with store.locked_record(first):
                pass
            with self.assertRaisesRegex(UniversalInstallerError, "must resume"):
                with store.locked_record(second):
                    pass

    def test_symlink_asset_destination_is_rejected_before_transport(self) -> None:
        execution_request = request(operation_id="python-symlink")
        transport = FakeTransport()
        with tempfile.TemporaryDirectory() as temporary:
            store = ManagedPythonRuntimeExecutionStore(Path(temporary) / "managed-python")
            with store.locked_record(execution_request):
                pass
            store.prepare_asset_directory(execution_request.operation_id)
            target = Path(temporary) / "outside"
            target.write_bytes(b"do-not-overwrite")
            store.asset_path(execution_request.operation_id, "runtime").symlink_to(target)
            with self.assertRaisesRegex(UniversalInstallerError, "non-symlink"):
                ManagedPythonRuntimeExecutor(store).execute(
                    execution_request, transport, FakeInspector(), FakeMutation()
                )
            self.assertEqual(target.read_bytes(), b"do-not-overwrite")
            self.assertEqual(transport.calls, [])

    def test_symlinked_execution_root_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            real_root = Path(temporary) / "real-root"
            real_root.mkdir()
            linked_root = Path(temporary) / "linked-root"
            linked_root.symlink_to(real_root, target_is_directory=True)
            store = ManagedPythonRuntimeExecutionStore(linked_root)
            with self.assertRaisesRegex(UniversalInstallerError, "must be a real directory"):
                with store.locked_record(request(operation_id="python-linked-root")):
                    pass


if __name__ == "__main__":
    unittest.main()
