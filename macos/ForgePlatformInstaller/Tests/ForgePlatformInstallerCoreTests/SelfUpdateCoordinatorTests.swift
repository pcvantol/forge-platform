import XCTest
@testable import ForgePlatformInstallerCore

final class SelfUpdateCoordinatorTests: XCTestCase {
    func testVerifiedNewerGitHubReleaseStagesVerifiesAndAtomicallyRelaunches() async throws {
        let current = try makeCurrentIdentity(version: "1.0.0", sequence: 10)
        let release = try makeReleaseRecord(version: "1.1.0", sequence: 11)
        let staging = StagingSpy(result: .success(try makeStagedAsset()))
        let verifier = ArtifactVerifierSpy()
        let handoff = AtomicHandoffSpy(result: .success(()))
        let coordinator = makeCoordinator(
            feed: FeedSpy(result: .success(release)),
            inspector: InspectorSpy(responses: [.success(current), .success(current), .success(current)]),
            staging: staging,
            verifier: verifier,
            handoff: handoff
        )

        let check = await coordinator.checkForUpdate(currentVersion: current.version)
        XCTAssertEqual(check, .verifiedGitHubRelease(release.release))

        let update = await coordinator.handOffSelfUpdate(release.release)
        let stagedReleaseCount = await staging.stagedReleaseCount()
        let discardedAssets = await staging.discardedAssets()
        let verifierCalls = await verifier.calls()
        let handoffCallCount = await handoff.callCount()
        let handedOffRelease = await handoff.lastRelease()
        XCTAssertEqual(update, .relaunching)
        XCTAssertEqual(stagedReleaseCount, 1)
        XCTAssertEqual(discardedAssets, [])
        XCTAssertEqual(verifierCalls, [.sha256, .codeSignature, .notarization])
        XCTAssertEqual(handoffCallCount, 1)
        XCTAssertEqual(handedOffRelease, release)
    }

    func testStartupEnforcementAutomaticallyRelaunchesNewerVerifiedInstaller() async throws {
        let current = try makeCurrentIdentity(version: "1.0.0", sequence: 10)
        let release = try makeReleaseRecord(version: "1.1.0", sequence: 11)
        let staging = StagingSpy(result: .success(try makeStagedAsset()))
        let handoff = AtomicHandoffSpy(result: .success(()))
        let coordinator = makeCoordinator(
            feed: FeedSpy(result: .success(release)),
            inspector: InspectorSpy(responses: [.success(current), .success(current), .success(current)]),
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
            inspector: InspectorSpy(responses: [.success(current), .success(current), .success(current)]),
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
            opaqueReference: "stage-unexpected"
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
            inspector: InspectorSpy(responses: [.success(current), .success(current), .success(current)]),
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

    func testStagingReferencesRejectPathsAndShellLikeValues() {
        XCTAssertThrowsError(
            try StagedInstallerAsset(
                releaseAssetName: "ForgePlatformInstaller.app.zip",
                opaqueReference: "../tmp/installer"
            )
        )
        XCTAssertThrowsError(
            try StagedInstallerAsset(
                releaseAssetName: "ForgePlatformInstaller.app.zip",
                opaqueReference: "stage;open"
            )
        )
    }

    private func makeCoordinator(
        feed: any SignedInstallerReleaseFeedVerifying,
        inspector: any CurrentInstallerBundleInspecting,
        staging: any InstallerUpdateStaging,
        verifier: any StagedInstallerArtifactVerifying = ArtifactVerifierSpy(),
        handoff: any InstallerAtomicHandoffPerforming = AtomicHandoffSpy(result: .success(()))
    ) -> VerifiedInstallerSelfUpdateCoordinator {
        VerifiedInstallerSelfUpdateCoordinator(
            releaseFeed: feed,
            currentBundleInspector: inspector,
            staging: staging,
            artifactVerifier: verifier,
            atomicHandoff: handoff
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
            opaqueReference: "stage-1"
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
    private var stagedReleases: [VerifiedInstallerReleaseRecord] = []
    private var discarded: [StagedInstallerAsset] = []

    init(result: Result<StagedInstallerAsset, InstallerSelfUpdateFailure>) {
        self.result = result
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
    private var releases: [VerifiedInstallerReleaseRecord] = []

    init(result: Result<Void, InstallerSelfUpdateFailure>) {
        self.result = result
    }

    func handOffAtomicallyAndRelaunch(
        currentBundle: CurrentInstallerBundleIdentity,
        stagedAsset: StagedInstallerAsset,
        release: VerifiedInstallerReleaseRecord
    ) async -> Result<Void, InstallerSelfUpdateFailure> {
        releases.append(release)
        return result
    }

    func callCount() -> Int {
        releases.count
    }

    func lastRelease() -> VerifiedInstallerReleaseRecord? {
        releases.last
    }
}
