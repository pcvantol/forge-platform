import XCTest
@testable import ForgePlatformInstallerCore

final class SelfUpdateCoordinatorTests: XCTestCase {
    func testVerifiedNewerGitHubReleaseStagesVerifiesAndAtomicallyRelaunches() async throws {
        let current = try makeCurrentIdentity(version: "1.0.0", sequence: 10)
        let release = try makeReleaseRecord(version: "1.1.0", sequence: 11)
        let staging = StagingSpy(result: .success(try makeStagedAsset()))
        let verifier = ArtifactVerifierSpy()
        let handoff = AtomicHandoffSpy(result: .success(()))
        let recoveryStore = RecoveryStoreSpy()
        let coordinator = makeCoordinator(
            feed: FeedSpy(result: .success(release)),
            inspector: InspectorSpy(responses: [.success(current), .success(current), .success(current), .success(current)]),
            staging: staging,
            verifier: verifier,
            handoff: handoff,
            recoveryStore: recoveryStore
        )

        let check = await coordinator.checkForUpdate(currentVersion: current.version)
        XCTAssertEqual(check, .verifiedGitHubRelease(release.release))

        let update = await coordinator.handOffSelfUpdate(release.release)
        let stagedReleaseCount = await staging.stagedReleaseCount()
        let discardedAssets = await staging.discardedAssets()
        let verifierCalls = await verifier.calls()
        let handoffCallCount = await handoff.callCount()
        let handedOffRelease = await handoff.lastRelease()
        let receiptCount = await recoveryStore.receiptCount()
        XCTAssertEqual(update, .relaunching)
        XCTAssertEqual(stagedReleaseCount, 1)
        XCTAssertEqual(discardedAssets, [])
        XCTAssertEqual(verifierCalls, [.sha256, .codeSignature, .notarization])
        XCTAssertEqual(handoffCallCount, 1)
        XCTAssertEqual(handedOffRelease, release)
        XCTAssertEqual(receiptCount, 1)
    }

    func testStartupEnforcementAutomaticallyRelaunchesNewerVerifiedInstaller() async throws {
        let current = try makeCurrentIdentity(version: "1.0.0", sequence: 10)
        let release = try makeReleaseRecord(version: "1.1.0", sequence: 11)
        let staging = StagingSpy(result: .success(try makeStagedAsset()))
        let handoff = AtomicHandoffSpy(result: .success(()))
        let coordinator = makeCoordinator(
            feed: FeedSpy(result: .success(release)),
            inspector: InspectorSpy(responses: [.success(current), .success(current), .success(current), .success(current)]),
            staging: staging,
            handoff: handoff
        )

        let result = await coordinator.enforceCurrentInstaller(currentVersion: current.version)
        let stagedReleaseCount = await staging.stagedReleaseCount()
        let handoffCallCount = await handoff.callCount()

        XCTAssertEqual(result, .relaunching(release.release))
        XCTAssertEqual(stagedReleaseCount, 1)
        XCTAssertEqual(handoffCallCount, 1)
    }

    func testExactCurrentReleaseAllowsWizardButCannotBeHandedOffAgain() async throws {
        let release = try makeReleaseRecord(version: "1.0.0", sequence: 10)
        let current = try makeCurrentIdentity(
            version: "1.0.0",
            sequence: 10,
            sourceRevision: release.sourceRevision,
            codeDirectorySHA256: release.expectedCodeDirectorySHA256,
            metadataSHA256: release.metadataSHA256
        )
        let staging = StagingSpy(result: .success(try makeStagedAsset()))
        let coordinator = makeCoordinator(
            feed: FeedSpy(result: .success(release)),
            inspector: InspectorSpy(responses: [.success(current)]),
            staging: staging
        )

        let check = await coordinator.checkForUpdate(currentVersion: current.version)
        XCTAssertEqual(check, .verifiedGitHubRelease(release.release))

        let handoff = await coordinator.handOffSelfUpdate(release.release)
        let stagedReleaseCount = await staging.stagedReleaseCount()
        XCTAssertEqual(
            handoff,
            .failed(InstallerSelfUpdateFailureCode.noVerifiedPendingUpdate.userFacingMessage)
        )
        XCTAssertEqual(stagedReleaseCount, 0)
    }

    func testSameVersionWithChangedSignedIdentityFailsClosed() async throws {
        let release = try makeReleaseRecord(version: "1.0.0", sequence: 10)
        let current = try makeCurrentIdentity(
            version: "1.0.0",
            sequence: 10,
            sourceRevision: release.sourceRevision,
            codeDirectorySHA256: String(repeating: "e", count: 64),
            metadataSHA256: release.metadataSHA256
        )
        let staging = StagingSpy(result: .success(try makeStagedAsset()))
        let coordinator = makeCoordinator(
            feed: FeedSpy(result: .success(release)),
            inspector: InspectorSpy(responses: [.success(current)]),
            staging: staging
        )

        let check = await coordinator.checkForUpdate(currentVersion: current.version)
        let stagedReleaseCount = await staging.stagedReleaseCount()

        XCTAssertEqual(
            check,
            .rejected(InstallerSelfUpdateFailureCode.releaseIdentityConflict.userFacingMessage)
        )
        XCTAssertEqual(stagedReleaseCount, 0)
    }

    func testRejectedSignedFeedFailsClosedBeforeInspectingOrStaging() async throws {
        let current = try makeCurrentIdentity(version: "1.0.0", sequence: 10)
        let inspector = InspectorSpy(responses: [.success(current)])
        let staging = StagingSpy(result: .success(try makeStagedAsset()))
        let coordinator = makeCoordinator(
            feed: FeedSpy(result: .failure(InstallerSelfUpdateFailure(.releaseMetadataRejected))),
            inspector: inspector,
            staging: staging
        )

        let check = await coordinator.checkForUpdate(currentVersion: current.version)
        let inspectorCallCount = await inspector.callCount()
        let stagedReleaseCount = await staging.stagedReleaseCount()
        XCTAssertEqual(
            check,
            .rejected(InstallerSelfUpdateFailureCode.releaseMetadataRejected.userFacingMessage)
        )
        XCTAssertEqual(inspectorCallCount, 0)
        XCTAssertEqual(stagedReleaseCount, 0)
    }

    func testUnexpectedCurrentBundleIdentityBlocksUpdateBeforeStaging() async throws {
        let current = try CurrentInstallerBundleIdentity(
            version: try InstallerVersion("1.0.0"),
            acceptedReleaseSequence: 10,
            sourceRevision: String(repeating: "a", count: 40),
            bundleIdentifier: "com.pcvantol.forge-platform-installer",
            teamIdentifier: "ZZZZZZZZZZ",
            codeDirectorySHA256: String(repeating: "b", count: 64),
            metadataSHA256: String(repeating: "c", count: 64)
        )
        let release = try makeReleaseRecord(version: "1.1.0", sequence: 11)
        let staging = StagingSpy(result: .success(try makeStagedAsset()))
        let coordinator = makeCoordinator(
            feed: FeedSpy(result: .success(release)),
            inspector: InspectorSpy(responses: [.success(current)]),
            staging: staging
        )

        let check = await coordinator.checkForUpdate(currentVersion: current.version)
        let stagedReleaseCount = await staging.stagedReleaseCount()
        XCTAssertEqual(
            check,
            .rejected(InstallerSelfUpdateFailureCode.currentBundleIdentityMismatch.userFacingMessage)
        )
        XCTAssertEqual(stagedReleaseCount, 0)
    }

    func testHashFailureDiscardsStagingAndNeverHandoffs() async throws {
        let current = try makeCurrentIdentity(version: "1.0.0", sequence: 10)
        let release = try makeReleaseRecord(version: "1.1.0", sequence: 11)
        let stagedAsset = try makeStagedAsset()
        let staging = StagingSpy(result: .success(stagedAsset))
        let verifier = ArtifactVerifierSpy(
            sha256Result: .failure(InstallerSelfUpdateFailure(.sha256VerificationFailed))
        )
        let handoff = AtomicHandoffSpy(result: .success(()))
        let coordinator = makeCoordinator(
            feed: FeedSpy(result: .success(release)),
            inspector: InspectorSpy(responses: [.success(current), .success(current), .success(current), .success(current)]),
            staging: staging,
            verifier: verifier,
            handoff: handoff
        )

        _ = await coordinator.checkForUpdate(currentVersion: current.version)
        let result = await coordinator.handOffSelfUpdate(release.release)
        let discardedAssets = await staging.discardedAssets()
        let verifierCalls = await verifier.calls()
        let handoffCallCount = await handoff.callCount()

        XCTAssertEqual(
            result,
            .failed(InstallerSelfUpdateFailureCode.sha256VerificationFailed.userFacingMessage)
        )
        XCTAssertEqual(discardedAssets, [stagedAsset])
        XCTAssertEqual(verifierCalls, [.sha256])
        XCTAssertEqual(handoffCallCount, 0)
    }

    func testNotarizationFailureDiscardsStagingAfterAllPriorChecks() async throws {
        let current = try makeCurrentIdentity(version: "1.0.0", sequence: 10)
        let release = try makeReleaseRecord(version: "1.1.0", sequence: 11)
        let stagedAsset = try makeStagedAsset()
        let staging = StagingSpy(result: .success(stagedAsset))
        let verifier = ArtifactVerifierSpy(
            notarizationResult: .failure(InstallerSelfUpdateFailure(.notarizationVerificationFailed))
        )
        let handoff = AtomicHandoffSpy(result: .success(()))
        let coordinator = makeCoordinator(
            feed: FeedSpy(result: .success(release)),
            inspector: InspectorSpy(responses: [.success(current), .success(current)]),
            staging: staging,
            verifier: verifier,
            handoff: handoff
        )

        _ = await coordinator.checkForUpdate(currentVersion: current.version)
        let result = await coordinator.handOffSelfUpdate(release.release)
        let verifierCalls = await verifier.calls()
        let discardedAssets = await staging.discardedAssets()
        let handoffCallCount = await handoff.callCount()

        XCTAssertEqual(
            result,
            .failed(InstallerSelfUpdateFailureCode.notarizationVerificationFailed.userFacingMessage)
        )
        XCTAssertEqual(verifierCalls, [.sha256, .codeSignature, .notarization])
        XCTAssertEqual(discardedAssets, [stagedAsset])
        XCTAssertEqual(handoffCallCount, 0)
    }

    func testCurrentBundleChangeBetweenCheckAndHandoffBlocksTimeOfCheckUseRace() async throws {
        let current = try makeCurrentIdentity(version: "1.0.0", sequence: 10)
        let changed = try makeCurrentIdentity(
            version: "1.0.0",
            sequence: 10,
            sourceRevision: String(repeating: "d", count: 40)
        )
        let release = try makeReleaseRecord(version: "1.1.0", sequence: 11)
        let staging = StagingSpy(result: .success(try makeStagedAsset()))
        let handoff = AtomicHandoffSpy(result: .success(()))
        let coordinator = makeCoordinator(
            feed: FeedSpy(result: .success(release)),
            inspector: InspectorSpy(responses: [.success(current), .success(changed)]),
            staging: staging,
            handoff: handoff
        )

        _ = await coordinator.checkForUpdate(currentVersion: current.version)
        let result = await coordinator.handOffSelfUpdate(release.release)
        let stagedReleaseCount = await staging.stagedReleaseCount()
        let handoffCallCount = await handoff.callCount()

        XCTAssertEqual(
            result,
            .failed(InstallerSelfUpdateFailureCode.currentBundleChanged.userFacingMessage)
        )
        XCTAssertEqual(stagedReleaseCount, 0)
        XCTAssertEqual(handoffCallCount, 0)
    }

    func testCurrentBundleChangeWhileAssetIsStagedDiscardsItBeforeAtomicHandoff() async throws {
        let current = try makeCurrentIdentity(version: "1.0.0", sequence: 10)
        let changed = try makeCurrentIdentity(
            version: "1.0.0",
            sequence: 10,
            metadataSHA256: String(repeating: "d", count: 64)
        )
        let release = try makeReleaseRecord(version: "1.1.0", sequence: 11)
        let stagedAsset = try makeStagedAsset()
        let staging = StagingSpy(result: .success(stagedAsset))
        let verifier = ArtifactVerifierSpy()
        let handoff = AtomicHandoffSpy(result: .success(()))
        let coordinator = makeCoordinator(
            feed: FeedSpy(result: .success(release)),
            inspector: InspectorSpy(responses: [.success(current), .success(current), .success(changed)]),
            staging: staging,
            verifier: verifier,
            handoff: handoff
        )

        _ = await coordinator.checkForUpdate(currentVersion: current.version)
        let result = await coordinator.handOffSelfUpdate(release.release)
        let discardedAssets = await staging.discardedAssets()
        let verifierCalls = await verifier.calls()
        let handoffCallCount = await handoff.callCount()

        XCTAssertEqual(
            result,
            .failed(InstallerSelfUpdateFailureCode.currentBundleChanged.userFacingMessage)
        )
        XCTAssertEqual(discardedAssets, [stagedAsset])
        XCTAssertEqual(verifierCalls, [.sha256, .codeSignature, .notarization])
        XCTAssertEqual(handoffCallCount, 0)
    }

    func testStagedFileIdentityChangeAfterHashVerificationDiscardsAssetAndBlocksHandoff() async throws {
        let current = try makeCurrentIdentity(version: "1.0.0", sequence: 10)
        let release = try makeReleaseRecord(version: "1.1.0", sequence: 11)
        let stagedAsset = try makeStagedAsset()
        let changedIdentity = try StagedInstallerFileIdentity(
            volumeReference: "volume-1",
            fileReference: "file-2",
            byteCount: stagedAsset.fileIdentity.byteCount
        )
        let staging = StagingSpy(
            result: .success(stagedAsset),
            identityResponses: [.success(stagedAsset.fileIdentity), .success(changedIdentity)]
        )
        let verifier = ArtifactVerifierSpy()
        let handoff = AtomicHandoffSpy(result: .success(()))
        let recoveryStore = RecoveryStoreSpy()
        let coordinator = makeCoordinator(
            feed: FeedSpy(result: .success(release)),
            inspector: InspectorSpy(responses: [.success(current), .success(current)]),
            staging: staging,
            verifier: verifier,
            handoff: handoff,
            recoveryStore: recoveryStore
        )

        _ = await coordinator.checkForUpdate(currentVersion: current.version)
        let result = await coordinator.handOffSelfUpdate(release.release)
        let discardedAssets = await staging.discardedAssets()
        let verifierCalls = await verifier.calls()
        let handoffCallCount = await handoff.callCount()
        let pendingRecovery = await recoveryStore.pendingRecord()

        XCTAssertEqual(
            result,
            .failed(InstallerSelfUpdateFailureCode.stagedAssetIdentityChanged.userFacingMessage)
        )
        XCTAssertEqual(discardedAssets, [stagedAsset])
        XCTAssertEqual(verifierCalls, [.sha256])
        XCTAssertEqual(handoffCallCount, 0)
        XCTAssertNil(pendingRecovery)
    }

    func testStartupRecoveryCleansInterruptedStagedAssetBeforeCheckingFeed() async throws {
        let current = try makeCurrentIdentity(version: "1.0.0", sequence: 10)
        let release = try makeReleaseRecord(version: "1.1.0", sequence: 11)
        let operation = try InstallerSelfUpdateOperationIdentity(
            release: release,
            operationIdentifier: "recovery-operation-1"
        )
        let stagedAsset = try makeStagedAsset()
        let recoveryRecord = try InstallerSelfUpdateRecoveryRecord(
            operation: operation,
            phase: .verifiedForHandoff,
            stagedAsset: stagedAsset
        )
        let staging = StagingSpy(result: .success(stagedAsset))
        let recoveryStore = RecoveryStoreSpy(pending: recoveryRecord)
        let coordinator = makeCoordinator(
            feed: FeedSpy(result: .failure(InstallerSelfUpdateFailure(.releaseFeedUnavailable))),
            inspector: InspectorSpy(responses: [.success(current)]),
            staging: staging,
            recoveryStore: recoveryStore
        )

        let result = await coordinator.checkForUpdate(currentVersion: current.version)
        let discardedAssets = await staging.discardedAssets()
        let pendingRecovery = await recoveryStore.pendingRecord()

        XCTAssertEqual(
            result,
            .rejected(InstallerSelfUpdateFailureCode.releaseFeedUnavailable.userFacingMessage)
        )
        XCTAssertEqual(discardedAssets, [stagedAsset])
        XCTAssertNil(pendingRecovery)
    }

    func testRecoveryDoesNotDeleteAssetAfterCrashAtAtomicHandoffBoundary() async throws {
        let current = try makeCurrentIdentity(version: "1.0.0", sequence: 10)
        let release = try makeReleaseRecord(version: "1.1.0", sequence: 11)
        let operation = try InstallerSelfUpdateOperationIdentity(
            release: release,
            operationIdentifier: "handoff-boundary-operation-1"
        )
        let recoveryRecord = try InstallerSelfUpdateRecoveryRecord(
            operation: operation,
            phase: .handoffAttempting
        )
        let stagedAsset = try makeStagedAsset()
        let staging = StagingSpy(result: .success(stagedAsset))
        let recoveryStore = RecoveryStoreSpy(pending: recoveryRecord)
        let coordinator = makeCoordinator(
            feed: FeedSpy(result: .failure(InstallerSelfUpdateFailure(.releaseFeedUnavailable))),
            inspector: InspectorSpy(responses: [.success(current)]),
            staging: staging,
            recoveryStore: recoveryStore
        )

        let result = await coordinator.checkForUpdate(currentVersion: current.version)
        let discardedAssets = await staging.discardedAssets()
        let pendingRecovery = await recoveryStore.pendingRecord()

        XCTAssertEqual(
            result,
            .rejected(InstallerSelfUpdateFailureCode.handoffReceiptPersistencePending.userFacingMessage)
        )
        XCTAssertEqual(discardedAssets, [])
        XCTAssertEqual(pendingRecovery?.phase, .handoffAttempting)
    }

    func testOlderOrReplayedReleaseCannotReplaceNewerInstaller() async throws {
        let current = try makeCurrentIdentity(version: "1.1.0", sequence: 11)
        let release = try makeReleaseRecord(version: "1.0.0", sequence: 10)
        let staging = StagingSpy(result: .success(try makeStagedAsset()))
        let coordinator = makeCoordinator(
            feed: FeedSpy(result: .success(release)),
            inspector: InspectorSpy(responses: [.success(current)]),
            staging: staging
        )

        let check = await coordinator.checkForUpdate(currentVersion: current.version)
        let stagedReleaseCount = await staging.stagedReleaseCount()
        XCTAssertEqual(check, .rejected(InstallerSelfUpdateFailureCode.rollbackAttempt.userFacingMessage))
        XCTAssertEqual(stagedReleaseCount, 0)
    }

    func testMismatchedStagedAssetCannotReachVerifierOrHandoff() async throws {
        let current = try makeCurrentIdentity(version: "1.0.0", sequence: 10)
        let release = try makeReleaseRecord(version: "1.1.0", sequence: 11)
        let unexpectedAsset = try StagedInstallerAsset(
            releaseAssetName: "UnexpectedInstaller.zip",
            opaqueReference: "stage-unexpected",
            fileIdentity: try makeStagedFileIdentity()
        )
        let staging = StagingSpy(result: .success(unexpectedAsset))
        let verifier = ArtifactVerifierSpy()
        let handoff = AtomicHandoffSpy(result: .success(()))
        let coordinator = makeCoordinator(
            feed: FeedSpy(result: .success(release)),
            inspector: InspectorSpy(responses: [.success(current), .success(current)]),
            staging: staging,
            verifier: verifier,
            handoff: handoff
        )

        _ = await coordinator.checkForUpdate(currentVersion: current.version)
        let result = await coordinator.handOffSelfUpdate(release.release)
        let discardedAssets = await staging.discardedAssets()
        let verifierCalls = await verifier.calls()
        let handoffCallCount = await handoff.callCount()

        XCTAssertEqual(
            result,
            .failed(InstallerSelfUpdateFailureCode.stagedAssetMismatch.userFacingMessage)
        )
        XCTAssertEqual(discardedAssets, [unexpectedAsset])
        XCTAssertEqual(verifierCalls, [])
        XCTAssertEqual(handoffCallCount, 0)
    }

    func testAtomicHandoffFailureDiscardsVerifiedStageAndDoesNotClaimRelaunch() async throws {
        let current = try makeCurrentIdentity(version: "1.0.0", sequence: 10)
        let release = try makeReleaseRecord(version: "1.1.0", sequence: 11)
        let stagedAsset = try makeStagedAsset()
        let staging = StagingSpy(result: .success(stagedAsset))
        let handoff = AtomicHandoffSpy(
            result: .failure(InstallerSelfUpdateFailure(.atomicHandoffFailed))
        )
        let coordinator = makeCoordinator(
            feed: FeedSpy(result: .success(release)),
            inspector: InspectorSpy(responses: [.success(current), .success(current), .success(current), .success(current)]),
            staging: staging,
            handoff: handoff
        )

        _ = await coordinator.checkForUpdate(currentVersion: current.version)
        let result = await coordinator.handOffSelfUpdate(release.release)
        let discardedAssets = await staging.discardedAssets()
        let handoffCallCount = await handoff.callCount()

        XCTAssertEqual(
            result,
            .failed(InstallerSelfUpdateFailureCode.atomicHandoffFailed.userFacingMessage)
        )
        XCTAssertEqual(discardedAssets, [stagedAsset])
        XCTAssertEqual(handoffCallCount, 1)
    }

    func testAtomicHandoffWithMismatchedReceiptFailsClosedWithoutDeletingPotentiallyActivatedAsset() async throws {
        let current = try makeCurrentIdentity(version: "1.0.0", sequence: 10)
        let release = try makeReleaseRecord(version: "1.1.0", sequence: 11)
        let stagedAsset = try makeStagedAsset()
        let staging = StagingSpy(result: .success(stagedAsset))
        let handoff = AtomicHandoffSpy(result: .success(()), invalidReceipt: true)
        let recoveryStore = RecoveryStoreSpy()
        let coordinator = makeCoordinator(
            feed: FeedSpy(result: .success(release)),
            inspector: InspectorSpy(responses: [.success(current), .success(current), .success(current), .success(current)]),
            staging: staging,
            handoff: handoff,
            recoveryStore: recoveryStore
        )

        _ = await coordinator.checkForUpdate(currentVersion: current.version)
        let result = await coordinator.handOffSelfUpdate(release.release)
        let discardedAssets = await staging.discardedAssets()
        let pendingRecovery = await recoveryStore.pendingRecord()

        XCTAssertEqual(
            result,
            .failed(InstallerSelfUpdateFailureCode.handoffReceiptInvalid.userFacingMessage)
        )
        XCTAssertEqual(discardedAssets, [])
        XCTAssertEqual(pendingRecovery?.phase, .handoffReceiptPending)
    }

    func testStagingReferencesRejectPathsAndShellLikeValues() {
        XCTAssertThrowsError(
            try StagedInstallerAsset(
                releaseAssetName: "ForgePlatformInstaller.app.zip",
                opaqueReference: "../tmp/installer",
                fileIdentity: try makeStagedFileIdentity()
            )
        )
        XCTAssertThrowsError(
            try StagedInstallerAsset(
                releaseAssetName: "ForgePlatformInstaller.app.zip",
                opaqueReference: "stage;open",
                fileIdentity: try makeStagedFileIdentity()
            )
        )
    }

    private func makeCoordinator(
        feed: any SignedInstallerReleaseFeedVerifying,
        inspector: any CurrentInstallerBundleInspecting,
        staging: any InstallerUpdateStaging,
        verifier: any StagedInstallerArtifactVerifying = ArtifactVerifierSpy(),
        handoff: any InstallerAtomicHandoffPerforming = AtomicHandoffSpy(result: .success(())),
        recoveryStore: any InstallerSelfUpdateRecoveryStoring = RecoveryStoreSpy()
    ) -> VerifiedInstallerSelfUpdateCoordinator {
        VerifiedInstallerSelfUpdateCoordinator(
            releaseFeed: feed,
            currentBundleInspector: inspector,
            staging: staging,
            artifactVerifier: verifier,
            atomicHandoff: handoff,
            recoveryStore: recoveryStore
        )
    }

    private func makeReleaseRecord(version: String, sequence: UInt64) throws -> VerifiedInstallerReleaseRecord {
        let asset = try GitHubInstallerReleaseAsset(
            repository: "pcvantol/forge-platform",
            tag: "installer-v\(version)",
            assetName: "ForgePlatformInstaller.app.zip"
        )
        let release = VerifiedInstallerRelease(
            version: try InstallerVersion(version),
            releasePage: asset.releasePage,
            assetName: asset.assetName,
            sha256: String(repeating: "f", count: 64),
            signingKeyID: "forge-platform-installer-release-v1"
        )
        return try VerifiedInstallerReleaseRecord(
            release: release,
            sequence: sequence,
            sourceRevision: String(repeating: "a", count: 40),
            expectedBundleIdentifier: "com.pcvantol.forge-platform-installer",
            expectedTeamIdentifier: "ABCDE12345",
            expectedCodeDirectorySHA256: String(repeating: "b", count: 64),
            metadataSHA256: String(repeating: "c", count: 64),
            notarizationReference: "notarization-ticket-v1",
            githubAsset: asset
        )
    }

    private func makeCurrentIdentity(
        version: String,
        sequence: UInt64,
        sourceRevision: String = String(repeating: "a", count: 40),
        codeDirectorySHA256: String = String(repeating: "b", count: 64),
        metadataSHA256: String = String(repeating: "c", count: 64)
    ) throws -> CurrentInstallerBundleIdentity {
        try CurrentInstallerBundleIdentity(
            version: try InstallerVersion(version),
            acceptedReleaseSequence: sequence,
            sourceRevision: sourceRevision,
            bundleIdentifier: "com.pcvantol.forge-platform-installer",
            teamIdentifier: "ABCDE12345",
            codeDirectorySHA256: codeDirectorySHA256,
            metadataSHA256: metadataSHA256
        )
    }

    private func makeStagedAsset() throws -> StagedInstallerAsset {
        try StagedInstallerAsset(
            releaseAssetName: "ForgePlatformInstaller.app.zip",
            opaqueReference: "stage-1",
            fileIdentity: try makeStagedFileIdentity()
        )
    }

    private func makeStagedFileIdentity() throws -> StagedInstallerFileIdentity {
        try StagedInstallerFileIdentity(
            volumeReference: "volume-1",
            fileReference: "file-1",
            byteCount: 4096
        )
    }
}

private actor FeedSpy: SignedInstallerReleaseFeedVerifying {
    private let result: Result<VerifiedInstallerReleaseRecord, InstallerSelfUpdateFailure>

    init(result: Result<VerifiedInstallerReleaseRecord, InstallerSelfUpdateFailure>) {
        self.result = result
    }

    func latestVerifiedInstallerRelease() async -> Result<VerifiedInstallerReleaseRecord, InstallerSelfUpdateFailure> {
        result
    }
}

private actor InspectorSpy: CurrentInstallerBundleInspecting {
    private var responses: [Result<CurrentInstallerBundleIdentity, InstallerSelfUpdateFailure>]
    private var calls = 0

    init(responses: [Result<CurrentInstallerBundleIdentity, InstallerSelfUpdateFailure>]) {
        self.responses = responses
    }

    func inspectCurrentInstallerBundle() async -> Result<CurrentInstallerBundleIdentity, InstallerSelfUpdateFailure> {
        calls += 1
        guard !responses.isEmpty else {
            return .failure(InstallerSelfUpdateFailure(.currentBundleUnavailable))
        }
        return responses.removeFirst()
    }

    func callCount() -> Int {
        calls
    }
}

private actor StagingSpy: InstallerUpdateStaging {
    private let result: Result<StagedInstallerAsset, InstallerSelfUpdateFailure>
    private var identityResponses: [Result<StagedInstallerFileIdentity, InstallerSelfUpdateFailure>]
    private var stagedReleases: [VerifiedInstallerReleaseRecord] = []
    private var discarded: [StagedInstallerAsset] = []

    init(
        result: Result<StagedInstallerAsset, InstallerSelfUpdateFailure>,
        identityResponses: [Result<StagedInstallerFileIdentity, InstallerSelfUpdateFailure>] = []
    ) {
        self.result = result
        self.identityResponses = identityResponses
    }

    func stageInstallerUpdate(
        for release: VerifiedInstallerReleaseRecord
    ) async -> Result<StagedInstallerAsset, InstallerSelfUpdateFailure> {
        stagedReleases.append(release)
        return result
    }

    func discardStagedInstallerUpdate(
        _ stagedAsset: StagedInstallerAsset
    ) async -> Result<Void, InstallerSelfUpdateFailure> {
        discarded.append(stagedAsset)
        return .success(())
    }

    func inspectStagedInstallerAssetIdentity(
        _ stagedAsset: StagedInstallerAsset
    ) async -> Result<StagedInstallerFileIdentity, InstallerSelfUpdateFailure> {
        guard !identityResponses.isEmpty else {
            return .success(stagedAsset.fileIdentity)
        }
        return identityResponses.removeFirst()
    }

    func stagedReleaseCount() -> Int {
        stagedReleases.count
    }

    func discardedAssets() -> [StagedInstallerAsset] {
        discarded
    }
}

private actor ArtifactVerifierSpy: StagedInstallerArtifactVerifying {
    enum Call: Equatable, Sendable {
        case sha256
        case codeSignature
        case notarization
    }

    private let sha256Result: Result<Void, InstallerSelfUpdateFailure>
    private let codeSignatureResult: Result<Void, InstallerSelfUpdateFailure>
    private let notarizationResult: Result<Void, InstallerSelfUpdateFailure>
    private var recordedCalls: [Call] = []

    init(
        sha256Result: Result<Void, InstallerSelfUpdateFailure> = .success(()),
        codeSignatureResult: Result<Void, InstallerSelfUpdateFailure> = .success(()),
        notarizationResult: Result<Void, InstallerSelfUpdateFailure> = .success(())
    ) {
        self.sha256Result = sha256Result
        self.codeSignatureResult = codeSignatureResult
        self.notarizationResult = notarizationResult
    }

    func verifySHA256(
        of stagedAsset: StagedInstallerAsset,
        for release: VerifiedInstallerReleaseRecord
    ) async -> Result<Void, InstallerSelfUpdateFailure> {
        recordedCalls.append(.sha256)
        return sha256Result
    }

    func verifyCodeSignature(
        of stagedAsset: StagedInstallerAsset,
        for release: VerifiedInstallerReleaseRecord
    ) async -> Result<Void, InstallerSelfUpdateFailure> {
        recordedCalls.append(.codeSignature)
        return codeSignatureResult
    }

    func verifyNotarization(
        of stagedAsset: StagedInstallerAsset,
        for release: VerifiedInstallerReleaseRecord
    ) async -> Result<Void, InstallerSelfUpdateFailure> {
        recordedCalls.append(.notarization)
        return notarizationResult
    }

    func calls() -> [Call] {
        recordedCalls
    }
}

private actor AtomicHandoffSpy: InstallerAtomicHandoffPerforming {
    private let result: Result<Void, InstallerSelfUpdateFailure>
    private let invalidReceipt: Bool
    private var releases: [VerifiedInstallerReleaseRecord] = []

    init(
        result: Result<Void, InstallerSelfUpdateFailure>,
        invalidReceipt: Bool = false
    ) {
        self.result = result
        self.invalidReceipt = invalidReceipt
    }

    func handOffAtomicallyAndRelaunch(
        operation: InstallerSelfUpdateOperationIdentity,
        currentBundle: CurrentInstallerBundleIdentity,
        stagedAsset: StagedInstallerAsset,
        release: VerifiedInstallerReleaseRecord
    ) async -> Result<InstallerSelfUpdateHandoffReceipt, InstallerSelfUpdateFailure> {
        releases.append(release)
        switch result {
        case .success:
            do {
                let receiptOperation: InstallerSelfUpdateOperationIdentity
                if invalidReceipt {
                    receiptOperation = try InstallerSelfUpdateOperationIdentity(
                        operationIdentifier: "mismatched-operation",
                        installerVersion: operation.installerVersion,
                        releaseSequence: operation.releaseSequence,
                        sourceRevision: operation.sourceRevision,
                        artifactSHA256: operation.artifactSHA256,
                        expectedCodeDirectorySHA256: operation.expectedCodeDirectorySHA256,
                        metadataSHA256: operation.metadataSHA256,
                        bundleIdentifier: operation.bundleIdentifier,
                        teamIdentifier: operation.teamIdentifier
                    )
                } else {
                    receiptOperation = operation
                }
                return .success(try InstallerSelfUpdateHandoffReceipt(
                    operation: receiptOperation,
                    handoffReference: "handoff-1",
                    activatedCodeDirectorySHA256: operation.expectedCodeDirectorySHA256
                ))
            } catch {
                return .failure(InstallerSelfUpdateFailure(.handoffReceiptInvalid))
            }
        case .failure(let failure):
            return .failure(failure)
        }
    }

    func callCount() -> Int {
        releases.count
    }

    func lastRelease() -> VerifiedInstallerReleaseRecord? {
        releases.last
    }
}

private actor RecoveryStoreSpy: InstallerSelfUpdateRecoveryStoring {
    private var pending: InstallerSelfUpdateRecoveryRecord?
    private var receipts: [InstallerSelfUpdateHandoffReceipt] = []

    init(pending: InstallerSelfUpdateRecoveryRecord? = nil) {
        self.pending = pending
    }

    func loadPendingSelfUpdate() async -> Result<InstallerSelfUpdateRecoveryRecord?, InstallerSelfUpdateFailure> {
        .success(pending)
    }

    func savePendingSelfUpdate(
        _ record: InstallerSelfUpdateRecoveryRecord
    ) async -> Result<Void, InstallerSelfUpdateFailure> {
        pending = record
        return .success(())
    }

    func clearPendingSelfUpdate(
        for operation: InstallerSelfUpdateOperationIdentity
    ) async -> Result<Void, InstallerSelfUpdateFailure> {
        guard pending == nil || pending?.operation == operation else {
            return .failure(InstallerSelfUpdateFailure(.recoveryPersistenceFailed))
        }
        pending = nil
        return .success(())
    }

    func persistHandoffReceipt(
        _ receipt: InstallerSelfUpdateHandoffReceipt
    ) async -> Result<Void, InstallerSelfUpdateFailure> {
        receipts.append(receipt)
        return .success(())
    }

    func pendingRecord() -> InstallerSelfUpdateRecoveryRecord? {
        pending
    }

    func receiptCount() -> Int {
        receipts.count
    }
}
