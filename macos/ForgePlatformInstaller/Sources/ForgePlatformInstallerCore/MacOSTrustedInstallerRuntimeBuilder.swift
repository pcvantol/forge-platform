import Darwin
import Foundation

/// Configuration failures for the concrete native self-update runtime
/// assembly.  The builder intentionally has no default state location: a
/// released, privileged installer controller must supply the one fixed
/// machine-scoped location used by every installer process on that host.
public enum MacOSTrustedInstallerRuntimeBuilderConfigurationError: Error, Equatable, Sendable {
    /// The supplied root was not an existing, absolute, effective-user-owned
    /// private directory.  In particular, an absent root, a final symlink,
    /// a non-directory, or a group/world-accessible directory is never
    /// provisioned or adopted by this builder.
    case invalidInstallerStateRoot
    /// The running native process did not report an architecture supported by
    /// the already sealed installer-release descriptor contract.
    case unsupportedHostArchitecture
}

/// Concrete assembly of the native, installer-only self-update runtime.
///
/// This is deliberately an assembly boundary rather than another update
/// engine.  It wires the individually bounded, sealed-trust adapters already
/// present in this package: GitHub descriptor verification, exact archive
/// transport, private staging, archive digest verification, stored-ZIP
/// extraction, staged-bundle evidence and notarization, atomic handoff,
/// durable recovery, and the cross-process update lease.
///
/// `stateRoot` is supplied by a trusted packaged-runtime/controller boundary,
/// never discovered from `PATH`, a UI field, a product data root, or a product
/// component.  The root must already exist and be an effective-user-owned
/// `0700` directory.  The caller must use the same machine-scoped root for
/// every released installer process; this source-level builder cannot turn a
/// per-user location into evidence of cross-account uniqueness.
///
/// It does not wire application startup, select a composition, install a
/// product, launch a provider command, or create a service.  Until the app is
/// explicitly wired through this builder by a separately qualified release,
/// `ReleasedInstallerStartupBoundary.bundledFailClosed()` remains the active
/// source-build boundary.
public struct MacOSTrustedInstallerRuntimeBuilder: TrustedInstallerRuntimeBuilding {
    private let stateRoot: URL
    private let architecture: String

    /// Creates a builder only for an existing private installer-owned root.
    /// The root is canonicalised through `realpath(3)` after rejecting a final
    /// symlink, so `/tmp`-style compatibility aliases and their canonical
    /// locations cannot create distinct installer state islands.
    public init(stateRoot: URL) throws {
        self.stateRoot = try MacOSInstallerOwnedStateRoot.validatedCanonicalURL(from: stateRoot)
        guard let architecture = MacOSInstallerHostArchitecture.current,
              GitHubInstallerReleaseDescriptor.isSupportedArchitecture(architecture) else {
            throw MacOSTrustedInstallerRuntimeBuilderConfigurationError.unsupportedHostArchitecture
        }
        self.architecture = architecture
    }

    /// Assembles only the existing sealed-trust adapters.  The startup
    /// boundary has already loaded both values from the code-signed current
    /// bundle; this repeat binding prevents a caller from pairing a valid V1
    /// provenance record with a different V2 trust configuration.
    public func buildTrustedInstallerRuntime(
        sealedTrustConfiguration: SealedInstallerReleaseTrustConfiguration,
        sealedReleaseProvenance: SealedInstallerReleaseProvenance
    ) async -> Result<any TrustedInstallerRuntime, InstallerSelfUpdateFailure> {
        guard sealedReleaseProvenance.releaseTrustConfigurationSHA256
            == sealedTrustConfiguration.configurationSHA256 else {
            return .failure(InstallerSelfUpdateFailure(.sealedReleaseProvenanceMismatch))
        }

        do {
            let acceptanceStore = FileInstallerReleaseAcceptanceStore(rootDirectory: stateRoot)
            let releaseFeed = try GitHubSignedInstallerReleaseFeed(
                trustConfiguration: sealedTrustConfiguration,
                sealedReleaseProvenance: sealedReleaseProvenance,
                architecture: architecture,
                fetcher: GitHubReleaseDescriptorTransport(),
                acceptanceStore: acceptanceStore
            )

            let staging = try MacOSInstallerArchiveStaging(
                stateRoot: stateRoot,
                downloader: GitHubInstallerReleaseArchiveTransport()
            )
            let archiveDigestVerifier = try MacOSStagedInstallerArchiveDigestVerifier(
                archiveResolver: staging
            )
            let bundleResolver = try MacOSStagedInstallerArchiveExtractor(
                extractionRoot: stateRoot,
                archiveResolver: staging
            )
            let bundleInspector = MacOSStagedInstallerBundleEvidenceInspector()
            let notarizationAssessor = MacOSStapledInstallerNotarizationAssessor()
            let artifactVerifier = MacOSStagedInstallerArtifactVerifier(
                archiveDigestVerifier: archiveDigestVerifier,
                bundleResolver: bundleResolver,
                bundleInspector: bundleInspector,
                notarizationAssessor: notarizationAssessor
            )
            let atomicHandoff = MacOSVerifiedInstallerAtomicHandoff(
                stagedAssetIdentityInspector: staging,
                bundleResolver: bundleResolver,
                bundleInspector: bundleInspector,
                notarizationAssessor: notarizationAssessor
            )

            return .success(VerifiedInstallerSelfUpdateCoordinator(
                releaseFeed: releaseFeed,
                currentBundleInspector: MacOSCurrentInstallerBundleInspector(),
                staging: staging,
                artifactVerifier: artifactVerifier,
                atomicHandoff: atomicHandoff,
                recoveryStore: FileInstallerSelfUpdateRecoveryStore(rootDirectory: stateRoot),
                operationLock: FileInstallerSelfUpdateOperationLock(rootDirectory: stateRoot)
            ))
        } catch {
            // Do not leak a filesystem location, architecture detail, network
            // endpoint, or tool diagnostic into the wizard.  A malformed
            // assembly remains unavailable rather than falling back to a
            // weaker updater or a manual composition path.
            return .failure(InstallerSelfUpdateFailure(.trustedUpdaterUnavailable))
        }
    }
}

private enum MacOSInstallerHostArchitecture {
    static var current: String? {
        var information = utsname()
        guard uname(&information) == 0 else {
            return nil
        }
        let machineByteCount = MemoryLayout.size(ofValue: information.machine)
        return withUnsafePointer(to: &information.machine) { pointer in
            pointer.withMemoryRebound(
                to: CChar.self,
                capacity: machineByteCount
            ) {
                String(validatingCString: $0)
            }
        }
    }
}

private enum MacOSInstallerOwnedStateRoot {
    static func validatedCanonicalURL(from input: URL) throws -> URL {
        guard input.isFileURL else {
            throw MacOSTrustedInstallerRuntimeBuilderConfigurationError.invalidInstallerStateRoot
        }

        let inputPath = input.path
        guard inputPath.hasPrefix("/"), inputPath != "/" else {
            throw MacOSTrustedInstallerRuntimeBuilderConfigurationError.invalidInstallerStateRoot
        }

        let originalDetails = try secureDirectoryDetails(at: inputPath)
        let canonicalPath = try canonicalPath(for: inputPath)
        let canonicalDetails = try secureDirectoryDetails(at: canonicalPath)
        guard originalDetails.st_dev == canonicalDetails.st_dev,
              originalDetails.st_ino == canonicalDetails.st_ino else {
            throw MacOSTrustedInstallerRuntimeBuilderConfigurationError.invalidInstallerStateRoot
        }

        return URL(fileURLWithPath: canonicalPath, isDirectory: true)
    }

    private static func secureDirectoryDetails(at path: String) throws -> stat {
        var details = stat()
        let status = path.withCString { pathPointer in
            Darwin.lstat(pathPointer, &details)
        }
        guard status == 0,
              (details.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              (details.st_mode & mode_t(S_IFLNK)) == 0,
              details.st_uid == Darwin.geteuid(),
              (details.st_mode & mode_t(0o7777)) == mode_t(0o700) else {
            throw MacOSTrustedInstallerRuntimeBuilderConfigurationError.invalidInstallerStateRoot
        }
        return details
    }

    private static func canonicalPath(for path: String) throws -> String {
        let resolvedPath: UnsafeMutablePointer<CChar>? = path.withCString { pathPointer in
            Darwin.realpath(pathPointer, nil)
        }
        guard let resolvedPath else {
            throw MacOSTrustedInstallerRuntimeBuilderConfigurationError.invalidInstallerStateRoot
        }
        defer { Darwin.free(resolvedPath) }
        return String(cString: resolvedPath)
    }
}
