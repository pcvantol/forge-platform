import Foundation
import Darwin
import XCTest
@testable import ForgePlatformInstallerCore

final class SelfUpdateRecoveryStoreTests: XCTestCase {
    func testFileStorePersistsNonSecretPendingRecordAndReceiptFirstRecovery() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-platform-installer-recovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = FileInstallerSelfUpdateRecoveryStore(rootDirectory: directory)
        let operation = try makeOperation()
        let stagedAsset = try StagedInstallerAsset(
            releaseAssetName: "ForgePlatformInstaller.app.zip",
            opaqueReference: "stage-1",
            fileIdentity: try StagedInstallerFileIdentity(
                volumeReference: "volume-1",
                fileReference: "file-1",
                byteCount: 4096
            )
        )
        let pending = try InstallerSelfUpdateRecoveryRecord(
            operation: operation,
            phase: .verifiedForHandoff,
            stagedAsset: stagedAsset
        )

        let save = await store.savePendingSelfUpdate(pending)
        let loaded = await store.loadPendingSelfUpdate()

        guard case .success = save else {
            return XCTFail("Pending recovery record should persist")
        }
        XCTAssertEqual(loaded, .success(pending))

        let receipt = try InstallerSelfUpdateHandoffReceipt(
            operation: operation,
            handoffReference: "handoff-1",
            activatedCodeDirectorySHA256: operation.expectedCodeDirectorySHA256
        )
        let savedReceipt = await store.persistHandoffReceipt(receipt)
        let afterReceipt = await store.loadPendingSelfUpdate()

        guard case .success = savedReceipt else {
            return XCTFail("Handoff receipt should persist")
        }
        XCTAssertEqual(afterReceipt, .success(nil))
    }

    func testRecoveryRecordRejectsStagedPhaseWithoutTypedFileIdentity() throws {
        let operation = try makeOperation()

        XCTAssertThrowsError(
            try InstallerSelfUpdateRecoveryRecord(
                operation: operation,
                phase: .stagedForVerification
            )
        )
    }

    func testFileStoreFailsClosedForSymlinkedStateRoot() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-platform-installer-recovery-symlink-root-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("state", isDirectory: true)
        let target = base.appendingPathComponent("target", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: target)

        let result = await FileInstallerSelfUpdateRecoveryStore(rootDirectory: root)
            .savePendingSelfUpdate(try makePendingRecord())

        guard case .failure(let failure) = result else {
            return XCTFail("A symlinked recovery root must fail closed")
        }
        XCTAssertEqual(failure, InstallerSelfUpdateFailure(.recoveryPersistenceFailed))
    }

    func testFileStoreFailsClosedForPermissiveExistingStateRoot() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-platform-installer-recovery-permissive-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)

        let result = await FileInstallerSelfUpdateRecoveryStore(rootDirectory: root)
            .savePendingSelfUpdate(try makePendingRecord())

        guard case .failure(let failure) = result else {
            return XCTFail("A permissive recovery root must fail closed")
        }
        XCTAssertEqual(failure, InstallerSelfUpdateFailure(.recoveryPersistenceFailed))
    }

    func testFileStoreFailsClosedForExistingStateRootWithSpecialPermissionBit() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-platform-installer-recovery-special-mode-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let chmodResult = root.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.chmod(path, mode_t(0o1700))
        }
        XCTAssertEqual(chmodResult, 0)

        let result = await FileInstallerSelfUpdateRecoveryStore(rootDirectory: root)
            .savePendingSelfUpdate(try makePendingRecord())

        guard case .failure(let failure) = result else {
            return XCTFail("A recovery root with special permission bits must fail closed")
        }
        XCTAssertEqual(failure, InstallerSelfUpdateFailure(.recoveryPersistenceFailed))
    }

    func testFileStoreFailsClosedForSymlinkedPendingRecord() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-platform-installer-recovery-symlink-record-\(UUID().uuidString)", isDirectory: true)
        let unrelated = root.appendingPathComponent("unrelated.json", isDirectory: false)
        let pending = root.appendingPathComponent("pending-installer-self-update.json", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data("{}".utf8).write(to: unrelated)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unrelated.path)
        try FileManager.default.createSymbolicLink(at: pending, withDestinationURL: unrelated)

        let result = await FileInstallerSelfUpdateRecoveryStore(rootDirectory: root)
            .loadPendingSelfUpdate()

        XCTAssertEqual(result, .failure(InstallerSelfUpdateFailure(.recoveryLoadFailed)))
    }

    func testFileStoreFailsClosedForSymlinkedReceiptsDirectory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-platform-installer-recovery-symlink-receipts-\(UUID().uuidString)", isDirectory: true)
        let target = root.appendingPathComponent("unrelated", isDirectory: true)
        let receipts = root.appendingPathComponent("handoff-receipts", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createSymbolicLink(at: receipts, withDestinationURL: target)
        let operation = try makeOperation()
        let receipt = try InstallerSelfUpdateHandoffReceipt(
            operation: operation,
            handoffReference: "handoff-1",
            activatedCodeDirectorySHA256: operation.expectedCodeDirectorySHA256
        )

        let result = await FileInstallerSelfUpdateRecoveryStore(rootDirectory: root)
            .persistHandoffReceipt(receipt)

        guard case .failure(let failure) = result else {
            return XCTFail("A symlinked receipt directory must fail closed")
        }
        XCTAssertEqual(failure, InstallerSelfUpdateFailure(.recoveryPersistenceFailed))
    }

    private func makePendingRecord() throws -> InstallerSelfUpdateRecoveryRecord {
        let operation = try makeOperation()
        return try InstallerSelfUpdateRecoveryRecord(
            operation: operation,
            phase: .stagedForVerification,
            stagedAsset: try StagedInstallerAsset(
                releaseAssetName: "ForgePlatformInstaller.app.zip",
                opaqueReference: "stage-1",
                fileIdentity: try StagedInstallerFileIdentity(
                    volumeReference: "volume-1",
                    fileReference: "file-1",
                    byteCount: 4096
                )
            )
        )
    }

    private func makeOperation() throws -> InstallerSelfUpdateOperationIdentity {
        let asset = try GitHubInstallerReleaseAsset(
            repository: "example/installer",
            tag: "installer-v1.1.0",
            assetName: "ForgePlatformInstaller.app.zip"
        )
        let release = VerifiedInstallerRelease(
            version: try InstallerVersion("1.1.0"),
            releasePage: asset.releasePage,
            assetName: asset.assetName,
            sha256: String(repeating: "a", count: 64),
            signingKeyID: "test-key"
        )
        let record = try VerifiedInstallerReleaseRecord(
            release: release,
            sequence: 11,
            channel: .stable,
            sourceRevision: String(repeating: "b", count: 40),
            expectedBundleIdentifier: "com.example.installer",
            expectedTeamIdentifier: "ABCDE12345",
            expectedCodeDirectorySHA256: String(repeating: "c", count: 64),
            policyRevision: "release/v1",
            capabilities: ["composition/v1", "provider-gate/v1"],
            provenanceSHA256: String(repeating: "d", count: 64),
            expectedReleaseTrustConfigurationSHA256: String(repeating: "e", count: 64),
            notarizationReference: "receipt:ticket-1",
            githubAsset: asset
        )
        return try InstallerSelfUpdateOperationIdentity(
            release: record,
            operationIdentifier: "operation-1"
        )
    }
}
