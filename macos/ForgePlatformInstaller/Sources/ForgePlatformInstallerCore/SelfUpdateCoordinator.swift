import Foundation

/// A typed failure returned by a trusted self-update collaborator.  Collaborators
/// deliberately return an error code rather than raw command output, paths, URLs,
/// or credentials: those values must not become wizard diagnostics.
public enum InstallerSelfUpdateFailureCode: String, Equatable, Sendable {
    case releaseFeedUnavailable
    case releaseMetadataRejected
    case currentBundleUnavailable
    case currentBundleIdentityMismatch
    case currentBundleChanged
    case installerVersionMismatch
    case rollbackAttempt
    case releaseIdentityConflict
    case noVerifiedPendingUpdate
    case stagingFailed
    case stagedAssetMismatch
    case sha256VerificationFailed
    case codeSignatureVerificationFailed
    case notarizationVerificationFailed
    case stagingCleanupFailed
    case atomicHandoffFailed

    var userFacingMessage: String {
        switch self {
        case .releaseFeedUnavailable:
            return "De geverifieerde GitHub Release-feed is niet beschikbaar."
        case .releaseMetadataRejected:
            return "Het releasebewijs is niet geldig of niet vertrouwd."
        case .currentBundleUnavailable:
            return "De identiteit van deze installer kon niet worden gecontroleerd."
        case .currentBundleIdentityMismatch:
            return "Deze app komt niet overeen met de vertrouwde installer-identiteit."
        case .currentBundleChanged:
            return "De actieve installer is tijdens de updatecontrole gewijzigd."
        case .installerVersionMismatch:
            return "De wizardversie komt niet overeen met de actieve installerbundel."
        case .rollbackAttempt:
            return "De release-feed biedt geen nieuwere geldige installer; doorgaan is geblokkeerd."
        case .releaseIdentityConflict:
            return "De release-identiteit conflicteert met de geïnstalleerde installer."
        case .noVerifiedPendingUpdate:
            return "Er is geen geverifieerde installer-update klaar voor overdracht."
        case .stagingFailed:
            return "De installer-update kon niet veilig worden voorbereid."
        case .stagedAssetMismatch:
            return "Het voorbereide updatebestand hoort niet bij de geverifieerde release."
        case .sha256VerificationFailed:
            return "De SHA-256-controle van de installer-update is mislukt."
        case .codeSignatureVerificationFailed:
            return "De codeondertekening van de installer-update is niet geldig."
        case .notarizationVerificationFailed:
            return "De notarization-controle van de installer-update is niet geldig."
        case .stagingCleanupFailed:
            return "De mislukte installer-update kon niet volledig worden opgeruimd."
        case .atomicHandoffFailed:
            return "De installer-update kon niet atomair worden geactiveerd en herstart."
        }
    }
}

public struct InstallerSelfUpdateFailure: Error, Equatable, Sendable {
    public let code: InstallerSelfUpdateFailureCode

    public init(_ code: InstallerSelfUpdateFailureCode) {
        self.code = code
    }
}

public enum InstallerSelfUpdateMetadataError: Error, Equatable, Sendable {
    case invalidRepository(String)
    case invalidTag(String)
    case invalidAssetName(String)
    case invalidOpaqueReference(String)
    case invalidBundleIdentifier(String)
    case invalidTeamIdentifier(String)
    case invalidDigest(String)
    case invalidSourceRevision(String)
    case invalidReleaseSequence
    case releasePageMismatch
    case releaseAssetMismatch
}

/// A GitHub Release asset is named, rather than addressed through an arbitrary
/// URL supplied by the UI.  The signed-feed verifier owns transport and any
/// redirect policy; the coordinator only authorizes this exact release identity.
public struct GitHubInstallerReleaseAsset: Equatable, Sendable {
    public let repository: String
    public let tag: String
    public let assetName: String

    public init(repository: String, tag: String, assetName: String) throws {
        guard InstallerSelfUpdateValidation.isGitHubRepository(repository) else {
            throw InstallerSelfUpdateMetadataError.invalidRepository(repository)
        }
        guard InstallerSelfUpdateValidation.isGitHubTag(tag) else {
            throw InstallerSelfUpdateMetadataError.invalidTag(tag)
        }
        guard InstallerSelfUpdateValidation.isInstallerArchiveName(assetName) else {
            throw InstallerSelfUpdateMetadataError.invalidAssetName(assetName)
        }
        self.repository = repository
        self.tag = tag
        self.assetName = assetName
    }

    public var releasePage: String {
        "https://github.com/\(repository)/releases/tag/\(tag)"
    }
}

/// Immutable, signed-feed evidence for one Universal Installer release.  The
/// feed implementation must verify its signature and GitHub provenance before
/// constructing this value.  The coordinator then binds the downloaded bundle
/// to all of this identity evidence before it asks for an atomic relaunch.
public struct VerifiedInstallerReleaseRecord: Equatable, Sendable {
    public let release: VerifiedInstallerRelease
    public let sequence: UInt64
    public let sourceRevision: String
    public let expectedBundleIdentifier: String
    public let expectedTeamIdentifier: String
    public let expectedCodeDirectorySHA256: String
    public let metadataSHA256: String
    public let notarizationReference: String
    public let githubAsset: GitHubInstallerReleaseAsset

    public init(
        release: VerifiedInstallerRelease,
        sequence: UInt64,
        sourceRevision: String,
        expectedBundleIdentifier: String,
        expectedTeamIdentifier: String,
        expectedCodeDirectorySHA256: String,
        metadataSHA256: String,
        notarizationReference: String,
        githubAsset: GitHubInstallerReleaseAsset
    ) throws {
        guard sequence > 0 else {
            throw InstallerSelfUpdateMetadataError.invalidReleaseSequence
        }
        guard InstallerSelfUpdateValidation.isGitRevision(sourceRevision) else {
            throw InstallerSelfUpdateMetadataError.invalidSourceRevision(sourceRevision)
        }
        guard InstallerSelfUpdateValidation.isBundleIdentifier(expectedBundleIdentifier) else {
            throw InstallerSelfUpdateMetadataError.invalidBundleIdentifier(expectedBundleIdentifier)
        }
        guard InstallerSelfUpdateValidation.isTeamIdentifier(expectedTeamIdentifier) else {
            throw InstallerSelfUpdateMetadataError.invalidTeamIdentifier(expectedTeamIdentifier)
        }
        guard InstallerSelfUpdateValidation.isSHA256(release.sha256),
              InstallerSelfUpdateValidation.isSHA256(expectedCodeDirectorySHA256),
              InstallerSelfUpdateValidation.isSHA256(metadataSHA256) else {
            throw InstallerSelfUpdateMetadataError.invalidDigest(release.sha256)
        }
        guard InstallerSelfUpdateValidation.isOpaqueReference(release.signingKeyID),
              InstallerSelfUpdateValidation.isOpaqueReference(notarizationReference) else {
            throw InstallerSelfUpdateMetadataError.invalidOpaqueReference(notarizationReference)
        }
        guard release.releasePage == githubAsset.releasePage else {
            throw InstallerSelfUpdateMetadataError.releasePageMismatch
        }
        guard release.assetName == githubAsset.assetName else {
            throw InstallerSelfUpdateMetadataError.releaseAssetMismatch
        }

        self.release = release
        self.sequence = sequence
        self.sourceRevision = sourceRevision
        self.expectedBundleIdentifier = expectedBundleIdentifier
        self.expectedTeamIdentifier = expectedTeamIdentifier
        self.expectedCodeDirectorySHA256 = expectedCodeDirectorySHA256
        self.metadataSHA256 = metadataSHA256
        self.notarizationReference = notarizationReference
        self.githubAsset = githubAsset
    }
}

/// Identity read from the currently running application bundle.  A concrete
/// inspector must obtain it from sealed bundle metadata and code-signing
/// inspection, rather than an environment variable, PATH lookup, or display
/// version alone.
public struct CurrentInstallerBundleIdentity: Equatable, Sendable {
    public let version: InstallerVersion
    public let acceptedReleaseSequence: UInt64
    public let sourceRevision: String
    public let bundleIdentifier: String
    public let teamIdentifier: String
    public let codeDirectorySHA256: String
    public let metadataSHA256: String

    public init(
        version: InstallerVersion,
        acceptedReleaseSequence: UInt64,
        sourceRevision: String,
        bundleIdentifier: String,
        teamIdentifier: String,
        codeDirectorySHA256: String,
        metadataSHA256: String
    ) throws {
        guard acceptedReleaseSequence > 0 else {
            throw InstallerSelfUpdateMetadataError.invalidReleaseSequence
        }
        guard InstallerSelfUpdateValidation.isGitRevision(sourceRevision) else {
            throw InstallerSelfUpdateMetadataError.invalidSourceRevision(sourceRevision)
        }
        guard InstallerSelfUpdateValidation.isBundleIdentifier(bundleIdentifier) else {
            throw InstallerSelfUpdateMetadataError.invalidBundleIdentifier(bundleIdentifier)
        }
        guard InstallerSelfUpdateValidation.isTeamIdentifier(teamIdentifier) else {
            throw InstallerSelfUpdateMetadataError.invalidTeamIdentifier(teamIdentifier)
        }
        guard InstallerSelfUpdateValidation.isSHA256(codeDirectorySHA256),
              InstallerSelfUpdateValidation.isSHA256(metadataSHA256) else {
            throw InstallerSelfUpdateMetadataError.invalidDigest(codeDirectorySHA256)
        }

        self.version = version
        self.acceptedReleaseSequence = acceptedReleaseSequence
        self.sourceRevision = sourceRevision
        self.bundleIdentifier = bundleIdentifier
        self.teamIdentifier = teamIdentifier
        self.codeDirectorySHA256 = codeDirectorySHA256
        self.metadataSHA256 = metadataSHA256
    }
}

/// Opaque staging identity.  It deliberately cannot carry a filesystem path or
/// a shell expression into the core coordinator.
public struct StagedInstallerAsset: Equatable, Sendable {
    public let releaseAssetName: String
    public let opaqueReference: String

    public init(releaseAssetName: String, opaqueReference: String) throws {
        guard InstallerSelfUpdateValidation.isInstallerArchiveName(releaseAssetName) else {
            throw InstallerSelfUpdateMetadataError.invalidAssetName(releaseAssetName)
        }
        guard InstallerSelfUpdateValidation.isOpaqueReference(opaqueReference) else {
            throw InstallerSelfUpdateMetadataError.invalidOpaqueReference(opaqueReference)
        }
        self.releaseAssetName = releaseAssetName
        self.opaqueReference = opaqueReference
    }
}

/// This protocol boundary is the only place that may retrieve release metadata.
/// It verifies the signed GitHub release feed before returning immutable data.
public protocol SignedInstallerReleaseFeedVerifying: Sendable {
    func latestVerifiedInstallerRelease() async -> Result<VerifiedInstallerReleaseRecord, InstallerSelfUpdateFailure>
}

/// Inspects the active app bundle and returns sealed identity evidence.  It must
/// not infer an installer identity from PATH, the process name, or a source tree.
public protocol CurrentInstallerBundleInspecting: Sendable {
    func inspectCurrentInstallerBundle() async -> Result<CurrentInstallerBundleIdentity, InstallerSelfUpdateFailure>
}

/// Stages exactly one verified GitHub Release asset in an operation-owned
/// location.  It never decides product installation/update behavior.
public protocol InstallerUpdateStaging: Sendable {
    func stageInstallerUpdate(
        for release: VerifiedInstallerReleaseRecord
    ) async -> Result<StagedInstallerAsset, InstallerSelfUpdateFailure>

    func discardStagedInstallerUpdate(
        _ stagedAsset: StagedInstallerAsset
    ) async -> Result<Void, InstallerSelfUpdateFailure>
}

/// Performs independent integrity checks on a staged installer bundle.  Each
/// method receives the immutable signed-feed record, so checks cannot be bound
/// merely to a mutable filename or release version.
public protocol StagedInstallerArtifactVerifying: Sendable {
    func verifySHA256(
        of stagedAsset: StagedInstallerAsset,
        for release: VerifiedInstallerReleaseRecord
    ) async -> Result<Void, InstallerSelfUpdateFailure>

    func verifyCodeSignature(
        of stagedAsset: StagedInstallerAsset,
        for release: VerifiedInstallerReleaseRecord
    ) async -> Result<Void, InstallerSelfUpdateFailure>

    func verifyNotarization(
        of stagedAsset: StagedInstallerAsset,
        for release: VerifiedInstallerReleaseRecord
    ) async -> Result<Void, InstallerSelfUpdateFailure>
}

/// Activates only a fully verified installer bundle.  A concrete implementation
/// must use an atomic handoff, launch the replacement process, and arrange for
/// the old process to exit.  Product component updates remain outside this API.
public protocol InstallerAtomicHandoffPerforming: Sendable {
    func handOffAtomicallyAndRelaunch(
        currentBundle: CurrentInstallerBundleIdentity,
        stagedAsset: StagedInstallerAsset,
        release: VerifiedInstallerReleaseRecord
    ) async -> Result<Void, InstallerSelfUpdateFailure>
}

/// Result of enforcing the startup invariant: this process may only proceed
/// when it is the exact current signed installer release.  A successful update
/// result means the atomic handoff collaborator has started the replacement and
/// arranged termination of this process; callers must not begin platform work.
public enum InstallerSelfUpdateEnforcementResult: Equatable, Sendable {
    case current(VerifiedInstallerRelease)
    case relaunching(VerifiedInstallerRelease)
    case failed(String)
}

/// Native shell coordinator for the Universal Installer's own update lifecycle.
/// It has no product-component, venv, migration, service, provider, or database
/// authority.  Every collaborator is injected so the security-sensitive native
/// operations can be tested without real URLs, credentials, or system changes.
public actor VerifiedInstallerSelfUpdateCoordinator: InstallerWizardCoordinator {
    private let releaseFeed: any SignedInstallerReleaseFeedVerifying
    private let currentBundleInspector: any CurrentInstallerBundleInspecting
    private let staging: any InstallerUpdateStaging
    private let artifactVerifier: any StagedInstallerArtifactVerifying
    private let atomicHandoff: any InstallerAtomicHandoffPerforming

    private var pendingUpdate: PendingUpdate?

    public init(
        releaseFeed: any SignedInstallerReleaseFeedVerifying,
        currentBundleInspector: any CurrentInstallerBundleInspecting,
        staging: any InstallerUpdateStaging,
        artifactVerifier: any StagedInstallerArtifactVerifying,
        atomicHandoff: any InstallerAtomicHandoffPerforming
    ) {
        self.releaseFeed = releaseFeed
        self.currentBundleInspector = currentBundleInspector
        self.staging = staging
        self.artifactVerifier = artifactVerifier
        self.atomicHandoff = atomicHandoff
    }

    public func checkForUpdate(currentVersion: InstallerVersion) async -> SelfUpdateCheckResult {
        pendingUpdate = nil

        switch await releaseFeed.latestVerifiedInstallerRelease() {
        case .success(let latestRelease):
            return await evaluate(latestRelease: latestRelease, currentVersion: currentVersion)
        case .failure(let failure):
            return rejected(failure.code)
        }
    }

    /// Startup callers use this one-shot operation instead of presenting an
    /// update choice.  An older installer downloads, verifies, atomically hands
    /// off to, and relaunches the newest verified installer before any platform
    /// composition can start.
    public func enforceCurrentInstaller(
        currentVersion: InstallerVersion
    ) async -> InstallerSelfUpdateEnforcementResult {
        switch await checkForUpdate(currentVersion: currentVersion) {
        case .rejected(let reason):
            return .failed(reason)
        case .verifiedGitHubRelease(let release):
            if release.version == currentVersion {
                return .current(release)
            }
            switch await handOffSelfUpdate(release) {
            case .relaunching:
                return .relaunching(release)
            case .failed(let reason):
                return .failed(reason)
            }
        }
    }

    private func evaluate(
        latestRelease: VerifiedInstallerReleaseRecord,
        currentVersion: InstallerVersion
    ) async -> SelfUpdateCheckResult {
        let currentBundle: CurrentInstallerBundleIdentity
        switch await currentBundleInspector.inspectCurrentInstallerBundle() {
        case .success(let identity):
            currentBundle = identity
        case .failure(let failure):
            return rejected(failure.code)
        }
        guard currentBundle.version == currentVersion else {
            return rejected(.installerVersionMismatch)
        }
        guard hasExpectedApplicationIdentity(currentBundle, for: latestRelease) else {
            return rejected(.currentBundleIdentityMismatch)
        }

        if latestRelease.release.version == currentBundle.version {
            guard isExactCurrentRelease(currentBundle, latestRelease) else {
                return rejected(.releaseIdentityConflict)
            }
            return .verifiedGitHubRelease(latestRelease.release)
        }

        guard latestRelease.release.version > currentBundle.version,
              latestRelease.sequence > currentBundle.acceptedReleaseSequence else {
            return rejected(.rollbackAttempt)
        }

        pendingUpdate = PendingUpdate(release: latestRelease, checkedCurrentBundle: currentBundle)
        return .verifiedGitHubRelease(latestRelease.release)
    }

    public func handOffSelfUpdate(_ release: VerifiedInstallerRelease) async -> SelfUpdateHandoffResult {
        guard let pendingUpdate, pendingUpdate.release.release == release else {
            return failed(.noVerifiedPendingUpdate)
        }
        guard case .success(let currentBundle) = await currentBundleInspector.inspectCurrentInstallerBundle() else {
            return failed(.currentBundleUnavailable)
        }
        guard currentBundle == pendingUpdate.checkedCurrentBundle else {
            return failed(.currentBundleChanged)
        }
        guard isValidNewerRelease(pendingUpdate.release, than: currentBundle) else {
            return failed(.rollbackAttempt)
        }

        let stagedAsset: StagedInstallerAsset
        switch await staging.stageInstallerUpdate(for: pendingUpdate.release) {
        case .success(let staged):
            stagedAsset = staged
        case .failure(let failure):
            return failed(failure.code)
        }

        guard stagedAsset.releaseAssetName == pendingUpdate.release.githubAsset.assetName else {
            return await discardAndFail(stagedAsset, because: .stagedAssetMismatch)
        }
        guard case .success = await artifactVerifier.verifySHA256(of: stagedAsset, for: pendingUpdate.release) else {
            return await discardAndFail(stagedAsset, because: .sha256VerificationFailed)
        }
        guard case .success = await artifactVerifier.verifyCodeSignature(of: stagedAsset, for: pendingUpdate.release) else {
            return await discardAndFail(stagedAsset, because: .codeSignatureVerificationFailed)
        }
        guard case .success = await artifactVerifier.verifyNotarization(of: stagedAsset, for: pendingUpdate.release) else {
            return await discardAndFail(stagedAsset, because: .notarizationVerificationFailed)
        }

        let currentBundleBeforeHandoff: CurrentInstallerBundleIdentity
        switch await currentBundleInspector.inspectCurrentInstallerBundle() {
        case .success(let inspectedBundle):
            currentBundleBeforeHandoff = inspectedBundle
        case .failure:
            return await discardAndFail(stagedAsset, because: .currentBundleUnavailable)
        }
        guard currentBundleBeforeHandoff == currentBundle else {
            return await discardAndFail(stagedAsset, because: .currentBundleChanged)
        }

        switch await atomicHandoff.handOffAtomicallyAndRelaunch(
            currentBundle: currentBundleBeforeHandoff,
            stagedAsset: stagedAsset,
            release: pendingUpdate.release
        ) {
        case .success:
            self.pendingUpdate = nil
            return .relaunching
        case .failure:
            return await discardAndFail(stagedAsset, because: .atomicHandoffFailed)
        }
    }

    /// Provider workflows are intentionally not folded into installer self
    /// update.  The shell's separate bounded provider coordinator owns them.
    public func performProviderAction(_ action: ProviderAction, for provider: ProviderID) async -> ProviderActionResult {
        .failed("Geen provider-coördinator gekoppeld voor \(provider.displayName).")
    }

    private func hasExpectedApplicationIdentity(
        _ currentBundle: CurrentInstallerBundleIdentity,
        for release: VerifiedInstallerReleaseRecord
    ) -> Bool {
        currentBundle.bundleIdentifier == release.expectedBundleIdentifier
            && currentBundle.teamIdentifier == release.expectedTeamIdentifier
    }

    private func isExactCurrentRelease(
        _ currentBundle: CurrentInstallerBundleIdentity,
        _ release: VerifiedInstallerReleaseRecord
    ) -> Bool {
        hasExpectedApplicationIdentity(currentBundle, for: release)
            && currentBundle.acceptedReleaseSequence == release.sequence
            && currentBundle.sourceRevision == release.sourceRevision
            && currentBundle.codeDirectorySHA256 == release.expectedCodeDirectorySHA256
            && currentBundle.metadataSHA256 == release.metadataSHA256
    }

    private func isValidNewerRelease(
        _ release: VerifiedInstallerReleaseRecord,
        than currentBundle: CurrentInstallerBundleIdentity
    ) -> Bool {
        hasExpectedApplicationIdentity(currentBundle, for: release)
            && release.release.version > currentBundle.version
            && release.sequence > currentBundle.acceptedReleaseSequence
    }

    private func discardAndFail(
        _ stagedAsset: StagedInstallerAsset,
        because code: InstallerSelfUpdateFailureCode
    ) async -> SelfUpdateHandoffResult {
        switch await staging.discardStagedInstallerUpdate(stagedAsset) {
        case .success:
            return failed(code)
        case .failure:
            return failed(.stagingCleanupFailed)
        }
    }

    private func rejected(_ code: InstallerSelfUpdateFailureCode) -> SelfUpdateCheckResult {
        .rejected(code.userFacingMessage)
    }

    private func failed(_ code: InstallerSelfUpdateFailureCode) -> SelfUpdateHandoffResult {
        .failed(code.userFacingMessage)
    }
}

private struct PendingUpdate: Sendable {
    let release: VerifiedInstallerReleaseRecord
    let checkedCurrentBundle: CurrentInstallerBundleIdentity
}

private enum InstallerSelfUpdateValidation {
    static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy(isLowercaseHex)
    }

    static func isGitRevision(_ value: String) -> Bool {
        (value.count == 40 || value.count == 64) && value.unicodeScalars.allSatisfy(isLowercaseHex)
    }

    static func isTeamIdentifier(_ value: String) -> Bool {
        value.count == 10 && value.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57) || (scalar.value >= 65 && scalar.value <= 90)
        }
    }

    static func isBundleIdentifier(_ value: String) -> Bool {
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else {
            return false
        }
        return labels.allSatisfy { label in
            !label.isEmpty && label.unicodeScalars.allSatisfy { scalar in
                (scalar.value >= 48 && scalar.value <= 57)
                    || (scalar.value >= 65 && scalar.value <= 90)
                    || (scalar.value >= 97 && scalar.value <= 122)
                    || scalar.value == 45
            }
        }
    }

    static func isGitHubRepository(_ value: String) -> Bool {
        let labels = value.split(separator: "/", omittingEmptySubsequences: false)
        guard labels.count == 2 else {
            return false
        }
        return labels.allSatisfy { label in
            !label.isEmpty && label.unicodeScalars.allSatisfy(isRepositoryScalar)
        }
    }

    static func isGitHubTag(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy(isRepositoryScalar)
    }

    static func isInstallerArchiveName(_ value: String) -> Bool {
        guard value.hasSuffix(".zip"), !value.contains("/"), !value.contains("\\") else {
            return false
        }
        return value.unicodeScalars.allSatisfy(isRepositoryScalar)
    }

    static func isOpaqueReference(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy { scalar in
            isRepositoryScalar(scalar) || scalar.value == 58
        }
    }

    private static func isLowercaseHex(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 48 && scalar.value <= 57) || (scalar.value >= 97 && scalar.value <= 102)
    }

    private static func isRepositoryScalar(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 48 && scalar.value <= 57)
            || (scalar.value >= 65 && scalar.value <= 90)
            || (scalar.value >= 97 && scalar.value <= 122)
            || scalar.value == 45
            || scalar.value == 46
            || scalar.value == 95
    }
}
