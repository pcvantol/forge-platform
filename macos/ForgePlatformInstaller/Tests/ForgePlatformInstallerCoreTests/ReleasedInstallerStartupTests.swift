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
        let repeatedOutcome = await boundary.start(currentVersion: currentVersion)

        guard case .relaunching(let actualRelease) = outcome else {
            return XCTFail("Relaunch handoff must keep the old process outside the wizard")
        }
        XCTAssertEqual(actualRelease, release)
        guard case .blocked(let reason) = repeatedOutcome else {
            return XCTFail("The handoff runtime and its lease must remain retained until old-process exit")
        }
        XCTAssertEqual(reason, InstallerSelfUpdateFailureCode.selfUpdateOperationInProgress.userFacingMessage)
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

    func testSealedConfigurationRejectsAChangedTrustSelectorWithAnOldDigest() {
        let digest = SealedInstallerReleaseTrustConfiguration.canonicalSHA256(
            schemaVersion: 1,
            trustKeyReference: "test-release-trust-key-a"
        )

        XCTAssertThrowsError(
            try SealedInstallerReleaseTrustConfiguration(
                schemaVersion: 1,
                configurationSHA256: digest,
                trustKeyReference: "test-release-trust-key-b"
            )
        )
    }

    func testBundledLoaderFailsClosedWhenStaticBundleValidationFails() async {
        let validator = BundleValidatorSpy(result: .failure(
            InstallerSelfUpdateFailure(.sealedReleaseTrustConfigurationAbsent)
        ))
        let loader = BundleSealedInstallerReleaseTrustConfigurationLoader(
            bundle: Bundle(for: InstallerStartupTestMarker.self),
            resourceName: "missing-installer-release-trust",
            bundleValidator: validator
        )

        let result = await loader.loadSealedReleaseTrustConfiguration()

        XCTAssertEqual(
            result,
            .failure(InstallerSelfUpdateFailure(.sealedReleaseTrustConfigurationAbsent))
        )
        XCTAssertEqual(validator.callCount(), 1)
    }

    func testStartupRetriesOnlyTheTypedConcurrentHandoffWindowBeforeOpeningWizard() async throws {
        let currentVersion = try InstallerVersion("1.0.0")
        let release = try makeRelease("1.0.0")
        let runtime = TrustedRuntimeSpy(enforcements: [
            .concurrentOperationInProgress,
            .current(release),
        ])
        let boundary = ReleasedInstallerStartupBoundary(
            trustConfigurationLoader: SealedTrustLoaderSpy(configuration: try makeConfiguration()),
            runtimeBuilder: TrustedRuntimeBuilderSpy(runtime: runtime),
            concurrentOperationRetryLimit: 1,
            concurrentOperationRetryNanoseconds: 0
        )

        let outcome = await boundary.start(currentVersion: currentVersion)
        let calls = await runtime.enforcementCallCount()

        guard case .ready(let session) = outcome else {
            return XCTFail("A bounded retry should admit the successor only after CURRENT")
        }
        XCTAssertEqual(session.currentRelease, release)
        XCTAssertEqual(calls, 2)
    }

    private func makeConfiguration() throws -> SealedInstallerReleaseTrustConfiguration {
        let trustKeyReference = "test-release-trust-key"
        return try SealedInstallerReleaseTrustConfiguration(
            schemaVersion: 1,
            configurationSHA256: SealedInstallerReleaseTrustConfiguration.canonicalSHA256(
                schemaVersion: 1,
                trustKeyReference: trustKeyReference
            ),
            trustKeyReference: trustKeyReference
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

private final class BundleValidatorSpy: SealedInstallerBundleValidating, @unchecked Sendable {
    private let stateLock = NSLock()
    private let result: Result<Void, InstallerSelfUpdateFailure>
    private var calls = 0

    init(result: Result<Void, InstallerSelfUpdateFailure>) {
        self.result = result
    }

    func validateSealedInstallerBundle(at bundleURL: URL) -> Result<Void, InstallerSelfUpdateFailure> {
        stateLock.lock()
        calls += 1
        stateLock.unlock()
        return result
    }

    func callCount() -> Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return calls
    }
}

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
    private var enforcements: [InstallerSelfUpdateEnforcementResult]
    private var calls = 0

    init(enforcement: InstallerSelfUpdateEnforcementResult) {
        enforcements = [enforcement]
    }

    init(enforcements: [InstallerSelfUpdateEnforcementResult]) {
        self.enforcements = enforcements
    }

    func enforceCurrentInstaller(
        currentVersion: InstallerVersion
    ) async -> InstallerSelfUpdateEnforcementResult {
        calls += 1
        guard !enforcements.isEmpty else {
            return .failed(InstallerSelfUpdateFailureCode.trustedUpdaterUnavailable.userFacingMessage)
        }
        return enforcements.removeFirst()
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
