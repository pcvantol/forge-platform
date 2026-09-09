import Foundation

/// Resolves a post-extraction app bundle only from an existing opaque staged
/// asset.  A future extractor owns the private extraction directory and must
/// re-check its file-system boundary before returning this URL.  Neither the
/// wizard nor a product component can supply a bundle path here.
public protocol MacOSStagedInstallerBundleResolving: Sendable {
    func resolveStagedInstallerBundle(
        _ stagedAsset: StagedInstallerAsset
    ) async -> Result<URL, InstallerSelfUpdateFailure>
}

/// The signed, public facts read from one statically validated staged app
/// bundle.  The facts remain deliberately narrower than a general signing
/// report: no certificate chain, filesystem path, command output, credential,
/// or product state reaches the update coordinator.
public struct MacOSStagedInstallerBundleEvidence: Equatable, Sendable {
    public let codeSigning: MacOSInstallerBundleCodeSigningEvidence
    public let releaseTrustConfiguration: SealedInstallerReleaseTrustConfiguration
    public let releaseProvenance: SealedInstallerReleaseProvenance

    public init(
        codeSigning: MacOSInstallerBundleCodeSigningEvidence,
        releaseTrustConfiguration: SealedInstallerReleaseTrustConfiguration,
        releaseProvenance: SealedInstallerReleaseProvenance
    ) {
        self.codeSigning = codeSigning
        self.releaseTrustConfiguration = releaseTrustConfiguration
        self.releaseProvenance = releaseProvenance
    }
}

/// Reads and binds only the code-signed evidence necessary for a staged app
/// verification.  It intentionally does not launch, move, activate, or
/// notarize the bundle.
public protocol MacOSStagedInstallerBundleInspecting: Sendable {
    func inspectStagedInstallerBundle(
        at bundleURL: URL
    ) async -> Result<MacOSStagedInstallerBundleEvidence, InstallerSelfUpdateFailure>
}

/// Native inspector used after a future trusted extractor has supplied a
/// private staged `.app`.  It requires a valid static code object before and
/// while reading both sealed resources.  The resource loaders independently
/// revalidate the same bundle, so a replacement between these observations
/// fails closed.
public struct MacOSStagedInstallerBundleEvidenceInspector: MacOSStagedInstallerBundleInspecting {
    private let codeSigningInspector: any MacOSInstallerBundleCodeSigningInspecting
    private let bundleValidator: any SealedInstallerBundleValidating

    public init(
        codeSigningInspector: any MacOSInstallerBundleCodeSigningInspecting = MacOSInstallerBundleCodeSigningInspector(),
        bundleValidator: any SealedInstallerBundleValidating = MacOSSealedInstallerBundleValidator()
    ) {
        self.codeSigningInspector = codeSigningInspector
        self.bundleValidator = bundleValidator
    }

    public func inspectStagedInstallerBundle(
        at bundleURL: URL
    ) async -> Result<MacOSStagedInstallerBundleEvidence, InstallerSelfUpdateFailure> {
        guard isAppBundleDirectory(bundleURL), let bundle = Bundle(url: bundleURL) else {
            return .failure(InstallerSelfUpdateFailure(.codeSignatureVerificationFailed))
        }
        let signing: MacOSInstallerBundleCodeSigningEvidence
        switch await codeSigningInspector.inspectSealedInstallerBundle(at: bundleURL) {
        case .success(let evidence):
            signing = evidence
        case .failure:
            return .failure(InstallerSelfUpdateFailure(.codeSignatureVerificationFailed))
        }
        let trustLoader = BundleSealedInstallerReleaseTrustConfigurationLoader(
            bundle: bundle,
            bundleValidator: bundleValidator
        )
        let provenanceLoader = BundleSealedInstallerReleaseProvenanceLoader(
            bundle: bundle,
            bundleValidator: bundleValidator
        )
        let trust: SealedInstallerReleaseTrustConfiguration
        switch await trustLoader.loadSealedReleaseTrustConfiguration() {
        case .success(let value):
            trust = value
        case .failure:
            return .failure(InstallerSelfUpdateFailure(.sealedReleaseTrustConfigurationMismatch))
        }
        let provenance: SealedInstallerReleaseProvenance
        switch await provenanceLoader.loadSealedReleaseProvenance() {
        case .success(let value):
            provenance = value
        case .failure:
            return .failure(InstallerSelfUpdateFailure(.sealedReleaseProvenanceMismatch))
        }
        return .success(MacOSStagedInstallerBundleEvidence(
            codeSigning: signing,
            releaseTrustConfiguration: trust,
            releaseProvenance: provenance
        ))
    }

    private func isAppBundleDirectory(_ url: URL) -> Bool {
        guard url.isFileURL,
              url.pathExtension.lowercased() == "app" else {
            return false
        }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}

/// Notarization is deliberately a distinct check from static signature
/// validity.  A released assembly must inject a dedicated Apple-assessment
/// implementation; a missing assessor cannot be treated as a successful
/// signature or a reason to launch the staged bundle.
public protocol MacOSInstallerNotarizationAssessing: Sendable {
    func assessNotarization(
        of bundleURL: URL,
        receiptReference: String
    ) async -> Result<Void, InstallerSelfUpdateFailure>
}

public struct UnavailableMacOSInstallerNotarizationAssessor: MacOSInstallerNotarizationAssessing {
    public init() {}

    public func assessNotarization(
        of bundleURL: URL,
        receiptReference: String
    ) async -> Result<Void, InstallerSelfUpdateFailure> {
        .failure(InstallerSelfUpdateFailure(.notarizationVerificationFailed))
    }
}

/// Full staged-artifact verifier assembled from independently bounded seams:
/// archive digest, post-extraction bundle resolution, static code/sealed
/// resource inspection, and notarization assessment.  Each public method is
/// invoked by `VerifiedInstallerSelfUpdateCoordinator` with the exact signed
/// release record, so no filename, display version, current bundle, or PATH
/// observation can substitute for release identity.
public struct MacOSStagedInstallerArtifactVerifier: StagedInstallerArtifactVerifying {
    private let archiveDigestVerifier: any StagedInstallerArchiveDigestVerifying
    private let bundleResolver: any MacOSStagedInstallerBundleResolving
    private let bundleInspector: any MacOSStagedInstallerBundleInspecting
    private let notarizationAssessor: any MacOSInstallerNotarizationAssessing

    public init(
        archiveDigestVerifier: any StagedInstallerArchiveDigestVerifying,
        bundleResolver: any MacOSStagedInstallerBundleResolving,
        bundleInspector: any MacOSStagedInstallerBundleInspecting = MacOSStagedInstallerBundleEvidenceInspector(),
        notarizationAssessor: any MacOSInstallerNotarizationAssessing = UnavailableMacOSInstallerNotarizationAssessor()
    ) {
        self.archiveDigestVerifier = archiveDigestVerifier
        self.bundleResolver = bundleResolver
        self.bundleInspector = bundleInspector
        self.notarizationAssessor = notarizationAssessor
    }

    public func verifySHA256(
        of stagedAsset: StagedInstallerAsset,
        for release: VerifiedInstallerReleaseRecord
    ) async -> Result<Void, InstallerSelfUpdateFailure> {
        await archiveDigestVerifier.verifyStagedInstallerArchiveSHA256(stagedAsset, for: release)
    }

    public func verifyCodeSignature(
        of stagedAsset: StagedInstallerAsset,
        for release: VerifiedInstallerReleaseRecord
    ) async -> Result<Void, InstallerSelfUpdateFailure> {
        switch await resolveAndInspect(stagedAsset) {
        case .success((_, let evidence)):
            return matchesCodeIdentity(evidence.codeSigning, release: release)
                ? .success(())
                : .failure(InstallerSelfUpdateFailure(.codeSignatureVerificationFailed))
        case .failure:
            return .failure(InstallerSelfUpdateFailure(.codeSignatureVerificationFailed))
        }
    }

    public func verifySealedReleaseTrustConfiguration(
        of stagedAsset: StagedInstallerAsset,
        for release: VerifiedInstallerReleaseRecord
    ) async -> Result<Void, InstallerSelfUpdateFailure> {
        switch await resolveAndInspect(stagedAsset) {
        case .success((_, let evidence)):
            guard matchesCodeIdentity(evidence.codeSigning, release: release),
                  evidence.releaseTrustConfiguration.configurationSHA256
                    == release.expectedReleaseTrustConfigurationSHA256,
                  evidence.releaseTrustConfiguration.expectedBundleIdentifier
                    == release.expectedBundleIdentifier,
                  evidence.releaseTrustConfiguration.expectedTeamIdentifier
                    == release.expectedTeamIdentifier else {
                return .failure(InstallerSelfUpdateFailure(.sealedReleaseTrustConfigurationMismatch))
            }
            return .success(())
        case .failure:
            return .failure(InstallerSelfUpdateFailure(.sealedReleaseTrustConfigurationMismatch))
        }
    }

    public func verifySealedReleaseProvenance(
        of stagedAsset: StagedInstallerAsset,
        for release: VerifiedInstallerReleaseRecord
    ) async -> Result<Void, InstallerSelfUpdateFailure> {
        switch await resolveAndInspect(stagedAsset) {
        case .success((_, let evidence)):
            guard matchesCodeIdentity(evidence.codeSigning, release: release),
                  evidence.releaseTrustConfiguration.configurationSHA256
                    == release.expectedReleaseTrustConfigurationSHA256,
                  evidence.releaseProvenance.matches(release.provenanceExpectation),
                  evidence.releaseProvenance.releaseTrustConfigurationSHA256
                    == evidence.releaseTrustConfiguration.configurationSHA256 else {
                return .failure(InstallerSelfUpdateFailure(.sealedReleaseProvenanceMismatch))
            }
            return .success(())
        case .failure:
            return .failure(InstallerSelfUpdateFailure(.sealedReleaseProvenanceMismatch))
        }
    }

    public func verifyNotarization(
        of stagedAsset: StagedInstallerAsset,
        for release: VerifiedInstallerReleaseRecord
    ) async -> Result<Void, InstallerSelfUpdateFailure> {
        switch await resolveAndInspect(stagedAsset) {
        case .success((let bundleURL, let evidence)):
            guard matchesCodeIdentity(evidence.codeSigning, release: release) else {
                return .failure(InstallerSelfUpdateFailure(.notarizationVerificationFailed))
            }
            switch await notarizationAssessor.assessNotarization(
                of: bundleURL,
                receiptReference: release.notarizationReference
            ) {
            case .success:
                return .success(())
            case .failure:
                return .failure(InstallerSelfUpdateFailure(.notarizationVerificationFailed))
            }
        case .failure:
            return .failure(InstallerSelfUpdateFailure(.notarizationVerificationFailed))
        }
    }

    private func resolveAndInspect(
        _ stagedAsset: StagedInstallerAsset
    ) async -> Result<(URL, MacOSStagedInstallerBundleEvidence), InstallerSelfUpdateFailure> {
        let bundleURL: URL
        switch await bundleResolver.resolveStagedInstallerBundle(stagedAsset) {
        case .success(let url):
            bundleURL = url
        case .failure(let failure):
            return .failure(failure)
        }
        switch await bundleInspector.inspectStagedInstallerBundle(at: bundleURL) {
        case .success(let evidence):
            return .success((bundleURL, evidence))
        case .failure(let failure):
            return .failure(failure)
        }
    }

    private func matchesCodeIdentity(
        _ evidence: MacOSInstallerBundleCodeSigningEvidence,
        release: VerifiedInstallerReleaseRecord
    ) -> Bool {
        evidence.bundleIdentifier == release.expectedBundleIdentifier
            && evidence.teamIdentifier == release.expectedTeamIdentifier
            && evidence.installerVersion == release.release.version
            && evidence.codeDirectorySHA256 == release.expectedCodeDirectorySHA256
    }
}
