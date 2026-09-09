import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ReleasedInstallerStartupTests: XCTestCase {
    func testMissingSealedTrustConfigurationBlocksBeforeRuntimeBuildOrWizard() async throws {
        let builder = TrustedRuntimeBuilderSpy(failure: .trustedUpdaterUnavailable)
        let boundary = ReleasedInstallerStartupBoundary(
            trustConfigurationLoader: SealedTrustLoaderSpy(failure: .sealedReleaseTrustConfigurationAbsent),
            runtimeBuilder: builder
        )

        let outcome = await boundary.start(currentVersion: try InstallerVersion("1.0.0"))
        let builderCallCount = await builder.callCount()

        guard case .blocked(let reason) = outcome else {
            return XCTFail("A wizard session must not exist without sealed trust configuration")
        }
        XCTAssertEqual(
            reason,
            InstallerSelfUpdateFailureCode.sealedReleaseTrustConfigurationAbsent.userFacingMessage
        )
        XCTAssertEqual(builderCallCount, 0)
    }

    func testTrustedRuntimeCanCreateWizardSessionOnlyAfterCurrentEnforcement() async throws {
        let currentVersion = try InstallerVersion("1.0.0")
        let release = try makeRelease("1.0.0")
        let runtime = TrustedRuntimeSpy(enforcement: .current(release))
        let builder = TrustedRuntimeBuilderSpy(runtime: runtime)
        let boundary = ReleasedInstallerStartupBoundary(
            trustConfigurationLoader: SealedTrustLoaderSpy(configuration: try makeConfiguration()),
            runtimeBuilder: builder
        )

        let outcome = await boundary.start(currentVersion: currentVersion)
        let builderCallCount = await builder.callCount()
        let enforcementCallCount = await runtime.enforcementCallCount()

        guard case .ready(let session) = outcome else {
            return XCTFail("A current trusted runtime should be the sole ready outcome")
        }
        XCTAssertEqual(session.currentRelease, release)
        XCTAssertEqual(builderCallCount, 1)
        XCTAssertEqual(enforcementCallCount, 1)
    }

    func testRelaunchingRuntimeNeverCreatesWizardSession() async throws {
        let currentVersion = try InstallerVersion("1.0.0")
        let release = try makeRelease("1.1.0")
        let runtime = TrustedRuntimeSpy(enforcement: .relaunching(release))
        let boundary = ReleasedInstallerStartupBoundary(
            trustConfigurationLoader: SealedTrustLoaderSpy(configuration: try makeConfiguration()),
            runtimeBuilder: TrustedRuntimeBuilderSpy(runtime: runtime)
        )

        let outcome = await boundary.start(currentVersion: currentVersion)

        guard case .relaunching(let actualRelease) = outcome else {
            return XCTFail("Relaunch handoff must keep the old process outside the wizard")
        }
        XCTAssertEqual(actualRelease, release)
    }

    func testBundledLoaderFailsClosedWhenNoSealedResourceExists() async {
        let loader = BundleSealedInstallerReleaseTrustConfigurationLoader(
            bundle: Bundle(for: InstallerStartupTestMarker.self),
            resourceName: "missing-installer-release-trust"
        )

        let result = await loader.loadSealedReleaseTrustConfiguration()

        XCTAssertEqual(
            result,
            .failure(InstallerSelfUpdateFailure(.sealedReleaseTrustConfigurationAbsent))
        )
    }

    private func makeConfiguration() throws -> SealedInstallerReleaseTrustConfiguration {
        try SealedInstallerReleaseTrustConfiguration(
            schemaVersion: 1,
            configurationSHA256: String(repeating: "a", count: 64),
            trustKeyReference: "test-release-trust-key"
        )
    }

    private func makeRelease(_ version: String) throws -> VerifiedInstallerRelease {
        VerifiedInstallerRelease(
            version: try InstallerVersion(version),
            releasePage: "https://github.com/example/installer/releases/tag/installer-v\(version)",
            assetName: "ForgePlatformInstaller.app.zip",
            sha256: String(repeating: "b", count: 64),
            signingKeyID: "test-release-key"
        )
    }
}

private final class InstallerStartupTestMarker: NSObject {}

private actor SealedTrustLoaderSpy: SealedInstallerReleaseTrustConfigurationLoading {
    private let result: Result<SealedInstallerReleaseTrustConfiguration, InstallerSelfUpdateFailure>

    init(configuration: SealedInstallerReleaseTrustConfiguration) {
        result = .success(configuration)
    }

    init(failure: InstallerSelfUpdateFailureCode) {
        result = .failure(InstallerSelfUpdateFailure(failure))
    }

    func loadSealedReleaseTrustConfiguration() async -> Result<SealedInstallerReleaseTrustConfiguration, InstallerSelfUpdateFailure> {
        result
    }
}

private actor TrustedRuntimeBuilderSpy: TrustedInstallerRuntimeBuilding {
    private let runtime: (any TrustedInstallerRuntime)?
    private let failure: InstallerSelfUpdateFailure?
    private var calls = 0

    init(runtime: any TrustedInstallerRuntime) {
        self.runtime = runtime
        failure = nil
    }

    init(failure: InstallerSelfUpdateFailureCode) {
        runtime = nil
        self.failure = InstallerSelfUpdateFailure(failure)
    }

    func buildTrustedInstallerRuntime(
        sealedTrustConfiguration: SealedInstallerReleaseTrustConfiguration
    ) async -> Result<any TrustedInstallerRuntime, InstallerSelfUpdateFailure> {
        calls += 1
        if let runtime {
            return .success(runtime)
        }
        return .failure(failure ?? InstallerSelfUpdateFailure(.trustedUpdaterUnavailable))
    }

    func callCount() -> Int {
        calls
    }
}

private actor TrustedRuntimeSpy: TrustedInstallerRuntime {
    private let enforcement: InstallerSelfUpdateEnforcementResult
    private var calls = 0

    init(enforcement: InstallerSelfUpdateEnforcementResult) {
        self.enforcement = enforcement
    }

    func enforceCurrentInstaller(
        currentVersion: InstallerVersion
    ) async -> InstallerSelfUpdateEnforcementResult {
        calls += 1
        return enforcement
    }

    func checkForUpdate(currentVersion: InstallerVersion) async -> SelfUpdateCheckResult {
        .rejected(InstallerSelfUpdateFailureCode.trustedUpdaterUnavailable.userFacingMessage)
    }

    func handOffSelfUpdate(_ release: VerifiedInstallerRelease) async -> SelfUpdateHandoffResult {
        .failed(InstallerSelfUpdateFailureCode.trustedUpdaterUnavailable.userFacingMessage)
    }

    func performProviderAction(_ action: ProviderAction, for provider: ProviderID) async -> ProviderActionResult {
        .failed(InstallerSelfUpdateFailureCode.trustedUpdaterUnavailable.userFacingMessage)
    }

    func enforcementCallCount() -> Int {
        calls
    }
}
