import Foundation
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
            sourceRevision: String(repeating: "b", count: 40),
            expectedBundleIdentifier: "com.example.installer",
            expectedTeamIdentifier: "ABCDE12345",
            expectedCodeDirectorySHA256: String(repeating: "c", count: 64),
            metadataSHA256: String(repeating: "d", count: 64),
            expectedReleaseTrustConfigurationSHA256: String(repeating: "e", count: 64),
            notarizationReference: "ticket-1",
            githubAsset: asset
        )
        return try InstallerSelfUpdateOperationIdentity(
            release: record,
            operationIdentifier: "operation-1"
        )
    }
}
