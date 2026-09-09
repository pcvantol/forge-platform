import Foundation

/// A sealed release package supplies this small, non-secret trust descriptor.
/// The descriptor carries references and digests only; a trusted runtime builder
/// owns the actual signature keys and network transport.  Source builds contain
/// no descriptor and therefore fail closed before the wizard is shown.
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
        self.schemaVersion = schemaVersion
        self.configurationSHA256 = configurationSHA256
        self.trustKeyReference = trustKeyReference
    }
}

/// Loads the app-code-signed release trust descriptor.  The loader is separate
/// from release-feed verification so a production builder can reject a missing,
/// unsealed, or unsupported descriptor before any wizard UI exists.
public protocol SealedInstallerReleaseTrustConfigurationLoading: Sendable {
    func loadSealedReleaseTrustConfiguration() async -> Result<SealedInstallerReleaseTrustConfiguration, InstallerSelfUpdateFailure>
}

/// Bundle-backed loader used by the released app.  No trust key, repository,
/// Apple team, or release URL is embedded here.  The configured app artifact
/// must include and code-sign the resource; otherwise this returns fail-closed.
public struct BundleSealedInstallerReleaseTrustConfigurationLoader: SealedInstallerReleaseTrustConfigurationLoading {
    private let bundle: Bundle
    private let resourceName: String

    public init(bundle: Bundle = .main, resourceName: String = "ForgePlatformInstallerReleaseTrust") {
        self.bundle = bundle
        self.resourceName = resourceName
    }

    public func loadSealedReleaseTrustConfiguration() async -> Result<SealedInstallerReleaseTrustConfiguration, InstallerSelfUpdateFailure> {
        do {
            guard let url = bundle.url(forResource: resourceName, withExtension: "json") else {
                return .failure(InstallerSelfUpdateFailure(.sealedReleaseTrustConfigurationAbsent))
            }
            let data = try Data(contentsOf: url)
            guard let rawValue = try JSONSerialization.jsonObject(with: data) as? [String: Any],
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

    public init(
        trustConfigurationLoader: any SealedInstallerReleaseTrustConfigurationLoading,
        runtimeBuilder: any TrustedInstallerRuntimeBuilding
    ) {
        self.trustConfigurationLoader = trustConfigurationLoader
        self.runtimeBuilder = runtimeBuilder
    }

    public static func bundledFailClosed() -> ReleasedInstallerStartupBoundary {
        ReleasedInstallerStartupBoundary(
            trustConfigurationLoader: BundleSealedInstallerReleaseTrustConfigurationLoader(),
            runtimeBuilder: AbsentTrustedInstallerRuntimeBuilder()
        )
    }

    public func start(currentVersion: InstallerVersion) async -> ReleasedInstallerStartupOutcome {
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

        switch await runtime.enforceCurrentInstaller(currentVersion: currentVersion) {
        case .current(let release):
            return .ready(ReleasedInstallerWizardSession(runtime: runtime, currentRelease: release))
        case .relaunching(let release):
            return .relaunching(release)
        case .failed(let reason):
            return .blocked(reason)
        }
    }
}
