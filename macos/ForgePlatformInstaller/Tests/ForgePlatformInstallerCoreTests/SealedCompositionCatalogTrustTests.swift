import CryptoKit
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class SealedCompositionCatalogTrustTests: XCTestCase {
    func testMatchesThePublicCrossLanguageCanonicalVector() throws {
        let keys = try [
            CompositionCatalogTrustEd25519PublicKey(
                keyID: "catalog-key-a",
                publicKeyBase64: Data((0..<32).map { UInt8($0) }).base64EncodedString()
            ),
            CompositionCatalogTrustEd25519PublicKey(
                keyID: "catalog-key-b",
                publicKeyBase64: Data((32..<64).map { UInt8($0) }).base64EncodedString()
            ),
        ]
        let digest = SealedCompositionCatalogTrustConfiguration.canonicalSHA256(
            installerReleaseTrustConfigurationSHA256: String(repeating: "a", count: 64),
            signatureThreshold: 2,
            ed25519PublicKeys: keys
        )

        XCTAssertEqual(digest, "029134bfeafb6d804ed86c94a9845deec4881d2497e3bbcf85c6a611eaa690d7")
    }

    func testStrictlyDecodesCanonicalCatalogTrustResource() throws {
        let fixture = try CatalogTrustFixture()
        let configuration = try fixture.configuration()
        let decoded = try SealedCompositionCatalogTrustConfiguration.decodeJSONResource(
            Data(fixture.json(for: configuration).utf8)
        )

        XCTAssertEqual(decoded, configuration)
        XCTAssertEqual(
            decoded.signaturePolicy.installerReleaseTrustConfigurationSHA256,
            fixture.installerTrustDigest
        )
        XCTAssertEqual(decoded.signaturePolicy.signatureThreshold, 2)
        XCTAssertEqual(decoded.signaturePolicy.ed25519PublicKeys.map(\.keyID), ["catalog-a", "catalog-b"])
    }

    func testRejectsWrongDigestThresholdOrderAndStrictShape() throws {
        let fixture = try CatalogTrustFixture()
        let configuration = try fixture.configuration()

        XCTAssertThrowsError(
            try SealedCompositionCatalogTrustConfiguration(
                configurationSHA256: String(repeating: "0", count: 64),
                installerReleaseTrustConfigurationSHA256: fixture.installerTrustDigest,
                signatureThreshold: 2,
                ed25519PublicKeys: fixture.keys
            )
        )
        XCTAssertThrowsError(
            try SealedCompositionCatalogTrustConfiguration(
                configurationSHA256: SealedCompositionCatalogTrustConfiguration.canonicalSHA256(
                    installerReleaseTrustConfigurationSHA256: fixture.installerTrustDigest,
                    signatureThreshold: 2,
                    ed25519PublicKeys: Array(fixture.keys.reversed())
                ),
                installerReleaseTrustConfigurationSHA256: fixture.installerTrustDigest,
                signatureThreshold: 2,
                ed25519PublicKeys: Array(fixture.keys.reversed())
            )
        )
        XCTAssertThrowsError(
            try SealedCompositionCatalogTrustConfiguration.decodeJSONResource(
                Data(fixture.json(for: configuration).replacingOccurrences(
                    of: "\"schema_version\":1",
                    with: "\"unexpected\":true,\"schema_version\":1"
                ).utf8)
            )
        )
        XCTAssertThrowsError(
            try SealedCompositionCatalogTrustConfiguration.decodeJSONResource(
                Data(repeating: 0x20, count: SealedCompositionCatalogTrustConfiguration.maximumResourceBytes + 1)
            )
        )
    }

    func testBundleLoaderFailsClosedWithoutAnIntactNamedResource() async throws {
        let absent = BundleSealedCompositionCatalogTrustConfigurationLoader(
            bundle: Bundle(for: CatalogTrustTestMarker.self),
            resourceName: "missing-composition-catalog-trust",
            bundleValidator: StaticCatalogTrustBundleValidator(.success(()))
        )
        let absentResult = await absent.loadSealedCompositionCatalogTrustConfiguration()
        XCTAssertEqual(absentResult, .failure(.unavailable))

        let unsealed = BundleSealedCompositionCatalogTrustConfigurationLoader(
            bundle: Bundle(for: CatalogTrustTestMarker.self),
            resourceName: "missing-composition-catalog-trust",
            bundleValidator: StaticCatalogTrustBundleValidator(
                .failure(InstallerSelfUpdateFailure(.sealedReleaseTrustConfigurationAbsent))
            )
        )
        let unsealedResult = await unsealed.loadSealedCompositionCatalogTrustConfiguration()
        XCTAssertEqual(unsealedResult, .failure(.unavailable))
    }
}

private struct CatalogTrustFixture {
    let installerTrustDigest = String(repeating: "d", count: 64)
    let keys: [CompositionCatalogTrustEd25519PublicKey]

    init() throws {
        let first = Curve25519.Signing.PrivateKey()
        let second = Curve25519.Signing.PrivateKey()
        keys = try [
            CompositionCatalogTrustEd25519PublicKey(
                keyID: "catalog-a",
                publicKeyBase64: first.publicKey.rawRepresentation.base64EncodedString()
            ),
            CompositionCatalogTrustEd25519PublicKey(
                keyID: "catalog-b",
                publicKeyBase64: second.publicKey.rawRepresentation.base64EncodedString()
            ),
        ]
    }

    func configuration() throws -> SealedCompositionCatalogTrustConfiguration {
        try SealedCompositionCatalogTrustConfiguration(
            configurationSHA256: SealedCompositionCatalogTrustConfiguration.canonicalSHA256(
                installerReleaseTrustConfigurationSHA256: installerTrustDigest,
                signatureThreshold: 2,
                ed25519PublicKeys: keys
            ),
            installerReleaseTrustConfigurationSHA256: installerTrustDigest,
            signatureThreshold: 2,
            ed25519PublicKeys: keys
        )
    }

    func json(for configuration: SealedCompositionCatalogTrustConfiguration) -> String {
        let keyJSON = configuration.signaturePolicy.ed25519PublicKeys.map {
            "{\"key_id\":\"\($0.keyID)\",\"public_key_base64\":\"\($0.publicKeyBase64)\"}"
        }.joined(separator: ",")
        return "{\"configuration_sha256\":\"\(configuration.configurationSHA256)\",\"ed25519_public_keys\":[\(keyJSON)],\"installer_release_trust_configuration_sha256\":\"\(configuration.signaturePolicy.installerReleaseTrustConfigurationSHA256)\",\"schema_version\":1,\"signature_threshold\":\(configuration.signaturePolicy.signatureThreshold)}"
    }
}

private final class CatalogTrustTestMarker: NSObject {}

private struct StaticCatalogTrustBundleValidator: SealedInstallerBundleValidating {
    let result: Result<Void, InstallerSelfUpdateFailure>

    init(_ result: Result<Void, InstallerSelfUpdateFailure>) {
        self.result = result
    }

    func validateSealedInstallerBundle(at bundleURL: URL) -> Result<Void, InstallerSelfUpdateFailure> {
        _ = bundleURL
        return result
    }
}
