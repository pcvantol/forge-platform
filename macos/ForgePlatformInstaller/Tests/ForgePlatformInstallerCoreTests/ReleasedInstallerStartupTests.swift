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

    func testSealedConfigurationRejectsAChangedPublicPolicyWithAnOldDigest() throws {
        let configuration = try makeConfiguration()

        XCTAssertThrowsError(
            try SealedInstallerReleaseTrustConfiguration(
                configurationSHA256: configuration.configurationSHA256,
                repository: "other-owner/example-installer",
                releaseDescriptorLocator: configuration.releaseDescriptorLocator,
                releaseDescriptorAssetName: configuration.releaseDescriptorAssetName,
                expectedBundleIdentifier: configuration.expectedBundleIdentifier,
                expectedTeamIdentifier: configuration.expectedTeamIdentifier,
                signatureThreshold: configuration.signatureThreshold,
                ed25519PublicKeys: configuration.ed25519PublicKeys
            )
        )
    }

    func testSealedConfigurationV2CanonicalDigestMatchesPublicVector() throws {
        let configuration = try makeConfiguration()

        XCTAssertEqual(
            configuration.configurationSHA256,
            "5988f1dd473caef0a2963f3a6cec06099007e740eced84e3a03fc0e04f343b19"
        )
    }

    func testSealedConfigurationStrictlyDecodesACompletePublicV2Resource() throws {
        let configuration = try makeConfiguration()

        let decoded = try SealedInstallerReleaseTrustConfiguration.decodeJSONResource(
            Data(makeConfigurationJSON(configuration).utf8)
        )

        XCTAssertEqual(decoded, configuration)
    }

    func testSealedConfigurationStrictlyDecodesEscapedUnicodeWhenItRepresentsValidASCII() throws {
        let configuration = try makeConfiguration()
        let json = makeConfigurationJSON(configuration).replacingOccurrences(
            of: "\"repository\":\"example-owner/example-installer\"",
            with: "\"repository\":\"\\u0065xample-owner/example-installer\""
        )

        let decoded = try SealedInstallerReleaseTrustConfiguration.decodeJSONResource(Data(json.utf8))

        XCTAssertEqual(decoded, configuration)
    }

    func testSealedConfigurationRejectsDuplicateKeysAndNonFiniteJSONConstants() throws {
        let configuration = try makeConfiguration()
        let validJSON = makeConfigurationJSON(configuration)
        let duplicateRepository = String(validJSON.dropLast())
            + ",\"repository\":\"example-owner/example-installer\"}"
        let nonFiniteThreshold = validJSON.replacingOccurrences(
            of: "\"signature_threshold\":2",
            with: "\"signature_threshold\":NaN"
        )

        XCTAssertThrowsError(
            try SealedInstallerReleaseTrustConfiguration.decodeJSONResource(Data(duplicateRepository.utf8))
        )
        XCTAssertThrowsError(
            try SealedInstallerReleaseTrustConfiguration.decodeJSONResource(Data(nonFiniteThreshold.utf8))
        )
    }

    func testSealedConfigurationRejectsMalformedUTF8AndOversizedResources() {
        XCTAssertThrowsError(
            try SealedInstallerReleaseTrustConfiguration.decodeJSONResource(Data([0xff]))
        )
        XCTAssertThrowsError(
            try SealedInstallerReleaseTrustConfiguration.decodeJSONResource(
                Data(repeating: 0x20, count: (32 * 1024) + 1)
            )
        )
    }

    func testSealedConfigurationRejectsNonIntegerAndNonCanonicalIntegerForms() throws {
        let configuration = try makeConfiguration()
        let validJSON = makeConfigurationJSON(configuration)
        let decimalThreshold = validJSON.replacingOccurrences(
            of: "\"signature_threshold\":2",
            with: "\"signature_threshold\":2.0"
        )
        let exponentThreshold = validJSON.replacingOccurrences(
            of: "\"signature_threshold\":2",
            with: "\"signature_threshold\":2e0"
        )
        let leadingZeroSchema = validJSON.replacingOccurrences(
            of: "\"schema_version\":2",
            with: "\"schema_version\":02"
        )

        XCTAssertThrowsError(
            try SealedInstallerReleaseTrustConfiguration.decodeJSONResource(Data(decimalThreshold.utf8))
        )
        XCTAssertThrowsError(
            try SealedInstallerReleaseTrustConfiguration.decodeJSONResource(Data(exponentThreshold.utf8))
        )
        XCTAssertThrowsError(
            try SealedInstallerReleaseTrustConfiguration.decodeJSONResource(Data(leadingZeroSchema.utf8))
        )
    }

    func testSealedConfigurationRejectsUppercaseOrDuplicatePublicKeyIdentity() throws {
        let keys = try makePublicKeys()

        XCTAssertThrowsError(
            try SealedInstallerReleaseTrustEd25519PublicKey(
                keyID: "Descriptor-key-a",
                publicKeyBase64: keys[0].publicKeyBase64
            )
        )
        XCTAssertThrowsError(
            try makeConfiguration(ed25519PublicKeys: [keys[0], keys[0]])
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

    private func makeConfiguration(
        ed25519PublicKeys: [SealedInstallerReleaseTrustEd25519PublicKey]? = nil
    ) throws -> SealedInstallerReleaseTrustConfiguration {
        let keys = try ed25519PublicKeys ?? makePublicKeys()
        let repository = "example-owner/example-installer"
        let releaseDescriptorLocator = SealedInstallerReleaseTrustConfiguration.githubReleaseAssetLocator
        let releaseDescriptorAssetName = "ForgePlatformInstallerReleaseDescriptor.json"
        let expectedBundleIdentifier = "com.example.forge-platform-installer"
        let expectedTeamIdentifier = "AB12CD34EF"
        let signatureThreshold = 2
        return try SealedInstallerReleaseTrustConfiguration(
            configurationSHA256: SealedInstallerReleaseTrustConfiguration.canonicalSHA256(
                repository: repository,
                releaseDescriptorLocator: releaseDescriptorLocator,
                releaseDescriptorAssetName: releaseDescriptorAssetName,
                expectedBundleIdentifier: expectedBundleIdentifier,
                expectedTeamIdentifier: expectedTeamIdentifier,
                signatureThreshold: signatureThreshold,
                ed25519PublicKeys: keys
            ),
            repository: repository,
            releaseDescriptorLocator: releaseDescriptorLocator,
            releaseDescriptorAssetName: releaseDescriptorAssetName,
            expectedBundleIdentifier: expectedBundleIdentifier,
            expectedTeamIdentifier: expectedTeamIdentifier,
            signatureThreshold: signatureThreshold,
            ed25519PublicKeys: keys
        )
    }

    private func makePublicKeys() throws -> [SealedInstallerReleaseTrustEd25519PublicKey] {
        [
            try SealedInstallerReleaseTrustEd25519PublicKey(
                keyID: "descriptor-key-a",
                publicKeyBase64: Data((0..<32).map { UInt8($0) }).base64EncodedString()
            ),
            try SealedInstallerReleaseTrustEd25519PublicKey(
                keyID: "descriptor-key-b",
                publicKeyBase64: Data((32..<64).map { UInt8($0) }).base64EncodedString()
            ),
        ]
    }

    private func makeConfigurationJSON(_ configuration: SealedInstallerReleaseTrustConfiguration) -> String {
        let keys = configuration.ed25519PublicKeys.map { key in
            "{\"key_id\":\"\(key.keyID)\",\"public_key_base64\":\"\(key.publicKeyBase64)\"}"
        }.joined(separator: ",")
        return "{"
            + "\"schema_version\":2,"
            + "\"configuration_sha256\":\"\(configuration.configurationSHA256)\","
            + "\"repository\":\"\(configuration.repository)\","
            + "\"release_descriptor_locator\":\"\(configuration.releaseDescriptorLocator)\","
            + "\"release_descriptor_asset_name\":\"\(configuration.releaseDescriptorAssetName)\","
            + "\"expected_bundle_identifier\":\"\(configuration.expectedBundleIdentifier)\","
            + "\"expected_team_identifier\":\"\(configuration.expectedTeamIdentifier)\","
            + "\"signature_threshold\":\(configuration.signatureThreshold),"
            + "\"ed25519_public_keys\":[\(keys)]"
            + "}"
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
