import CryptoKit
import Foundation
import Security

/// A sealed release package supplies this small, non-secret trust descriptor.
/// The descriptor carries references and digests only; a trusted runtime builder
/// owns the actual signature keys and network transport.  Source builds contain
/// no descriptor and therefore fail closed before the wizard is shown.
///
/// `configurationSHA256` is not an arbitrary self-assertion: it is the SHA-256
/// of a domain-separated canonical representation of every accepted semantic
/// field.  The app bundle's code signature remains the trust boundary for the
/// resource itself; this digest detects malformed/corrupted descriptor content
/// before the runtime builder sees a trust-key reference.
public struct SealedInstallerReleaseTrustConfiguration: Equatable, Sendable {
    public let schemaVersion: Int
    public let configurationSHA256: String
    public let trustKeyReference: String

    public init(
        schemaVersion: Int,
        configurationSHA256: String,
        trustKeyReference: String
    ) throws {
        guard schemaVersion == 1,
              InstallerSelfUpdateValidation.isSHA256(configurationSHA256),
              InstallerSelfUpdateValidation.isOpaqueReference(trustKeyReference) else {
            throw InstallerSelfUpdateMetadataError.invalidRecoveryRecord
        }
        guard configurationSHA256 == Self.canonicalSHA256(
            schemaVersion: schemaVersion,
            trustKeyReference: trustKeyReference
        ) else {
            throw InstallerSelfUpdateMetadataError.invalidRecoveryRecord
        }
        self.schemaVersion = schemaVersion
        self.configurationSHA256 = configurationSHA256
        self.trustKeyReference = trustKeyReference
    }

    /// Release packaging uses this deterministic digest when it emits the
    /// sealed descriptor.  It intentionally covers only fields this type
    /// accepts, and the loader rejects unknown descriptor keys.
    public static func canonicalSHA256(
        schemaVersion: Int,
        trustKeyReference: String
    ) -> String {
        let canonicalPayload = [
            "forge-platform-installer-release-trust-v1",
            String(schemaVersion),
            trustKeyReference,
        ].joined(separator: "\u{0}")
        let digest = SHA256.hash(data: Data(canonicalPayload.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Loads the app-code-signed release trust descriptor.  The loader is separate
/// from release-feed verification so a production builder can reject a missing,
/// unsealed, or unsupported descriptor before any wizard UI exists.
public protocol SealedInstallerReleaseTrustConfigurationLoading: Sendable {
    func loadSealedReleaseTrustConfiguration() async -> Result<SealedInstallerReleaseTrustConfiguration, InstallerSelfUpdateFailure>
}

/// Validates that the containing application bundle is an intact macOS signed
/// code object before a descriptor inside it is accepted.  A runtime builder
/// still owns the expected signing identity and release-feed trust root; this
/// boundary only prevents an altered resource from selecting a different trust
/// key reference.
public protocol SealedInstallerBundleValidating: Sendable {
    func validateSealedInstallerBundle(at bundleURL: URL) -> Result<Void, InstallerSelfUpdateFailure>
}

/// macOS verifies the complete static code object with strict resource
/// validation.  It contains no team ID, signing key, repository or URL, and
/// fails closed on every Security.framework error.
public struct MacOSSealedInstallerBundleValidator: SealedInstallerBundleValidating {
    public init() {}

    public func validateSealedInstallerBundle(at bundleURL: URL) -> Result<Void, InstallerSelfUpdateFailure> {
        var staticCode: SecStaticCode?
        let creationStatus = SecStaticCodeCreateWithPath(bundleURL as CFURL, SecCSFlags(), &staticCode)
        guard creationStatus == errSecSuccess, let staticCode else {
            return .failure(InstallerSelfUpdateFailure(.sealedReleaseTrustConfigurationAbsent))
        }
        let validationStatus = SecStaticCodeCheckValidity(
            staticCode,
            SecCSFlags(rawValue: kSecCSStrictValidate),
            nil
        )
        guard validationStatus == errSecSuccess else {
            return .failure(InstallerSelfUpdateFailure(.sealedReleaseTrustConfigurationAbsent))
        }
        return .success(())
    }
}

/// Bundle-backed loader used by the released app.  No trust key, repository,
/// Apple team, or release URL is embedded here.  The configured app artifact
/// must include and code-sign the resource; otherwise this returns fail-closed.
public struct BundleSealedInstallerReleaseTrustConfigurationLoader: SealedInstallerReleaseTrustConfigurationLoading {
    private let bundle: Bundle
    private let resourceName: String
    private let bundleValidator: any SealedInstallerBundleValidating

    public init(
        bundle: Bundle = .main,
        resourceName: String = "ForgePlatformInstallerReleaseTrust",
        bundleValidator: any SealedInstallerBundleValidating = MacOSSealedInstallerBundleValidator()
    ) {
        self.bundle = bundle
        self.resourceName = resourceName
        self.bundleValidator = bundleValidator
    }

    public func loadSealedReleaseTrustConfiguration() async -> Result<SealedInstallerReleaseTrustConfiguration, InstallerSelfUpdateFailure> {
        do {
            guard case .success = bundleValidator.validateSealedInstallerBundle(at: bundle.bundleURL) else {
                return .failure(InstallerSelfUpdateFailure(.sealedReleaseTrustConfigurationAbsent))
            }
            guard let url = bundle.url(forResource: resourceName, withExtension: "json") else {
                return .failure(InstallerSelfUpdateFailure(.sealedReleaseTrustConfigurationAbsent))
            }
            let data = try Data(contentsOf: url)
            guard let rawValue = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(rawValue.keys) == Set(["schema_version", "configuration_sha256", "trust_key_reference"]),
                  let schemaVersion = rawValue["schema_version"] as? Int,
                  let configurationSHA256 = rawValue["configuration_sha256"] as? String,
                  let trustKeyReference = rawValue["trust_key_reference"] as? String else {
                return .failure(InstallerSelfUpdateFailure(.sealedReleaseTrustConfigurationAbsent))
            }
            return .success(try SealedInstallerReleaseTrustConfiguration(
                schemaVersion: schemaVersion,
                configurationSHA256: configurationSHA256,
                trustKeyReference: trustKeyReference
            ))
        } catch {
            return .failure(InstallerSelfUpdateFailure(.sealedReleaseTrustConfigurationAbsent))
        }
    }
}

/// The startup-only capability required of a trusted Universal Installer
/// runtime.  It is intentionally narrower than a product installation engine.
public protocol InstallerStartupEnforcing: Sendable {
    func enforceCurrentInstaller(
        currentVersion: InstallerVersion
    ) async -> InstallerSelfUpdateEnforcementResult
}

/// A runtime can enter the wizard only after it both enforces self-update and
/// serves the bounded wizard coordinator contract.  `Unavailable...` does not
/// conform, preventing its use in the released startup path.
public protocol TrustedInstallerRuntime: InstallerWizardCoordinator, InstallerStartupEnforcing {}

/// Builds a trusted runtime from sealed release configuration.  Implementations
/// supply the signed-release verifier, bundle inspector, staged downloader,
/// artifact verifier, atomic handoff and durable recovery store.  This core
/// package intentionally provides no live implementation or credentials.
public protocol TrustedInstallerRuntimeBuilding: Sendable {
    func buildTrustedInstallerRuntime(
        sealedTrustConfiguration: SealedInstallerReleaseTrustConfiguration
    ) async -> Result<any TrustedInstallerRuntime, InstallerSelfUpdateFailure>
}

/// Explicitly fail-closed default for source builds and incompletely assembled
/// release artifacts.  It is a startup boundary, not a wizard coordinator.
public struct AbsentTrustedInstallerRuntimeBuilder: TrustedInstallerRuntimeBuilding {
    public init() {}

    public func buildTrustedInstallerRuntime(
        sealedTrustConfiguration: SealedInstallerReleaseTrustConfiguration
    ) async -> Result<any TrustedInstallerRuntime, InstallerSelfUpdateFailure> {
        .failure(InstallerSelfUpdateFailure(.trustedUpdaterUnavailable))
    }
}

public struct ReleasedInstallerWizardSession: Sendable {
    public let runtime: any TrustedInstallerRuntime
    public let currentRelease: VerifiedInstallerRelease

    public init(runtime: any TrustedInstallerRuntime, currentRelease: VerifiedInstallerRelease) {
        self.runtime = runtime
        self.currentRelease = currentRelease
    }
}

/// The only startup outcome allowed to instantiate the platform wizard is
/// `.ready`.  The application must show a fail-closed status for every other
/// case and must not fall back to an unavailable/manual coordinator.
public enum ReleasedInstallerStartupOutcome: Sendable {
    case ready(ReleasedInstallerWizardSession)
    case relaunching(VerifiedInstallerRelease)
    case blocked(String)
}

/// Production composition boundary for the native app.  It does not start a
/// platform installation, create a provider, or make a service change.  Its
/// sole role is requiring sealed trust configuration plus successful automatic
/// self-update enforcement before handing a trusted runtime to the wizard.
public actor ReleasedInstallerStartupBoundary {
    private let trustConfigurationLoader: any SealedInstallerReleaseTrustConfigurationLoading
    private let runtimeBuilder: any TrustedInstallerRuntimeBuilding
    private let concurrentOperationRetryLimit: Int
    private let concurrentOperationRetryNanoseconds: UInt64
    /// Keeps the verified coordinator (and therefore its handoff lease) alive
    /// while the old executable is displaying only its relaunch status.  The
    /// app-owned startup model retains this boundary until process termination.
    private var relaunchingRuntime: (any TrustedInstallerRuntime)?

    public init(
        trustConfigurationLoader: any SealedInstallerReleaseTrustConfigurationLoading,
        runtimeBuilder: any TrustedInstallerRuntimeBuilding,
        concurrentOperationRetryLimit: Int = 8,
        concurrentOperationRetryNanoseconds: UInt64 = 250_000_000
    ) {
        self.trustConfigurationLoader = trustConfigurationLoader
        self.runtimeBuilder = runtimeBuilder
        self.concurrentOperationRetryLimit = min(max(concurrentOperationRetryLimit, 0), 12)
        self.concurrentOperationRetryNanoseconds = min(concurrentOperationRetryNanoseconds, 1_000_000_000)
    }

    public static func bundledFailClosed() -> ReleasedInstallerStartupBoundary {
        ReleasedInstallerStartupBoundary(
            trustConfigurationLoader: BundleSealedInstallerReleaseTrustConfigurationLoader(),
            runtimeBuilder: AbsentTrustedInstallerRuntimeBuilder()
        )
    }

    public func start(currentVersion: InstallerVersion) async -> ReleasedInstallerStartupOutcome {
        guard relaunchingRuntime == nil else {
            return .blocked(InstallerSelfUpdateFailureCode.selfUpdateOperationInProgress.userFacingMessage)
        }
        let sealedTrustConfiguration: SealedInstallerReleaseTrustConfiguration
        switch await trustConfigurationLoader.loadSealedReleaseTrustConfiguration() {
        case .success(let configuration):
            sealedTrustConfiguration = configuration
        case .failure(let failure):
            return .blocked(failure.code.userFacingMessage)
        }

        let runtime: any TrustedInstallerRuntime
        switch await runtimeBuilder.buildTrustedInstallerRuntime(
            sealedTrustConfiguration: sealedTrustConfiguration
        ) {
        case .success(let builtRuntime):
            runtime = builtRuntime
        case .failure(let failure):
            return .blocked(failure.code.userFacingMessage)
        }

        for attempt in 0...concurrentOperationRetryLimit {
            switch await runtime.enforceCurrentInstaller(currentVersion: currentVersion) {
            case .current(let release):
                return .ready(ReleasedInstallerWizardSession(runtime: runtime, currentRelease: release))
            case .relaunching(let release):
                relaunchingRuntime = runtime
                return .relaunching(release)
            case .concurrentOperationInProgress:
                guard attempt < concurrentOperationRetryLimit else {
                    return .blocked(InstallerSelfUpdateFailureCode.selfUpdateOperationInProgress.userFacingMessage)
                }
                do {
                    try await Task.sleep(nanoseconds: concurrentOperationRetryNanoseconds)
                } catch {
                    return .blocked(InstallerSelfUpdateFailureCode.selfUpdateOperationInProgress.userFacingMessage)
                }
            case .failed(let reason):
                return .blocked(reason)
            }
        }
        return .blocked(InstallerSelfUpdateFailureCode.selfUpdateOperationInProgress.userFacingMessage)
    }
}
