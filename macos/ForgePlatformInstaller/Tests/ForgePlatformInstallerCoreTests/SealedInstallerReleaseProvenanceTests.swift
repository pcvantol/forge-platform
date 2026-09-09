import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class SealedInstallerReleaseProvenanceTests: XCTestCase {
    func testV1CanonicalDigestMatchesExplicitPublicVector() throws {
        let provenance = try makeProvenance()

        XCTAssertEqual(provenance.provenanceSHA256, ProvenanceV1Vector.provenanceSHA256)
        XCTAssertEqual(
            SealedInstallerReleaseProvenance.canonicalSHA256(
                installerVersion: provenance.installerVersion,
                channel: provenance.channel,
                releaseSequence: provenance.releaseSequence,
                sourceRevision: provenance.sourceRevision,
                policyRevision: provenance.policyRevision,
                capabilities: provenance.capabilities,
                releaseTrustConfigurationSHA256: provenance.releaseTrustConfigurationSHA256
            ),
            ProvenanceV1Vector.provenanceSHA256
        )
    }

    func testStrictlyDecodesCompletePublicV1Resource() throws {
        let provenance = try makeProvenance()

        let decoded = try SealedInstallerReleaseProvenance.decodeJSONResource(
            Data(makeProvenanceJSON(provenance).utf8)
        )

        XCTAssertEqual(decoded, provenance)
    }

    func testStrictDecoderAcceptsEscapedUnicodeOnlyWhenSemanticValueRemainsValidASCII() throws {
        let provenance = try makeProvenance()
        let json = makeProvenanceJSON(provenance).replacingOccurrences(
            of: "\"capabilities\":[\"composition/v1\",\"provider-gate/v1\"]",
            with: "\"capabilities\":[\"\\u0063omposition/v1\",\"provider-gate/v1\"]"
        )

        let decoded = try SealedInstallerReleaseProvenance.decodeJSONResource(Data(json.utf8))

        XCTAssertEqual(decoded, provenance)
    }

    func testStrictDecoderRejectsDuplicateUnknownPrivateAndOperationalFields() throws {
        let provenance = try makeProvenance()
        let validJSON = makeProvenanceJSON(provenance)
        let duplicateChannel = String(validJSON.dropLast()) + ",\"channel\":\"candidate\"}"
        let privateKey = String(validJSON.dropLast()) + ",\"private_key\":\"not-a-key\"}"
        let serviceLabel = String(validJSON.dropLast()) + ",\"service_label\":\"com.example.service\"}"

        XCTAssertThrowsError(
            try SealedInstallerReleaseProvenance.decodeJSONResource(Data(duplicateChannel.utf8))
        )
        XCTAssertThrowsError(
            try SealedInstallerReleaseProvenance.decodeJSONResource(Data(privateKey.utf8))
        )
        XCTAssertThrowsError(
            try SealedInstallerReleaseProvenance.decodeJSONResource(Data(serviceLabel.utf8))
        )
    }

    func testStrictDecoderRejectsMalformedUTF8AndOversizedResources() {
        XCTAssertThrowsError(
            try SealedInstallerReleaseProvenance.decodeJSONResource(Data([0xff]))
        )
        XCTAssertThrowsError(
            try SealedInstallerReleaseProvenance.decodeJSONResource(
                Data(repeating: 0x20, count: (32 * 1024) + 1)
            )
        )
    }

    func testStrictDecoderRejectsNonFiniteNonIntegerAndNoncanonicalIntegerForms() throws {
        let provenance = try makeProvenance()
        let validJSON = makeProvenanceJSON(provenance)
        let nonFinite = validJSON.replacingOccurrences(
            of: "\"release_sequence\":42",
            with: "\"release_sequence\":NaN"
        )
        let decimal = validJSON.replacingOccurrences(
            of: "\"release_sequence\":42",
            with: "\"release_sequence\":42.0"
        )
        let exponent = validJSON.replacingOccurrences(
            of: "\"release_sequence\":42",
            with: "\"release_sequence\":42e0"
        )
        let leadingZero = validJSON.replacingOccurrences(
            of: "\"schema_version\":1",
            with: "\"schema_version\":01"
        )
        let negativeZero = validJSON.replacingOccurrences(
            of: "\"release_sequence\":42",
            with: "\"release_sequence\":-0"
        )
        let overflow = validJSON.replacingOccurrences(
            of: "\"release_sequence\":42",
            with: "\"release_sequence\":18446744073709551616"
        )

        for json in [nonFinite, decimal, exponent, leadingZero, negativeZero, overflow] {
            XCTAssertThrowsError(
                try SealedInstallerReleaseProvenance.decodeJSONResource(Data(json.utf8)),
                "Noncanonical or unsupported JSON numeric form must fail closed"
            )
        }
    }

    func testStrictDecoderRejectsUnsupportedChannelAndInvalidPublicSemanticFields() throws {
        let provenance = try makeProvenance()
        let validJSON = makeProvenanceJSON(provenance)
        let unsupportedChannel = validJSON.replacingOccurrences(
            of: "\"channel\":\"candidate\"",
            with: "\"channel\":\"preview\""
        )
        let prereleaseVersion = validJSON.replacingOccurrences(
            of: "\"installer_version\":\"1.2.3\"",
            with: "\"installer_version\":\"1.2.3-beta\""
        )
        let uppercaseRevision = validJSON.replacingOccurrences(
            of: "\"source_revision\":\"\(provenance.sourceRevision)\"",
            with: "\"source_revision\":\"\(provenance.sourceRevision.uppercased())\""
        )
        let invalidPolicy = validJSON.replacingOccurrences(
            of: "\"policy_revision\":\"\(provenance.policyRevision)\"",
            with: "\"policy_revision\":\"Policy/v1\""
        )
        let prefixedDigest = validJSON.replacingOccurrences(
            of: "\"provenance_sha256\":\"\(provenance.provenanceSHA256)\"",
            with: "\"provenance_sha256\":\"sha256:\(provenance.provenanceSHA256)\""
        )

        for json in [unsupportedChannel, prereleaseVersion, uppercaseRevision, invalidPolicy, prefixedDigest] {
            XCTAssertThrowsError(
                try SealedInstallerReleaseProvenance.decodeJSONResource(Data(json.utf8)),
                "Unsupported provenance semantics must fail closed"
            )
        }
    }

    func testProvenanceRejectsEmptyUnsortedOrDuplicateCapabilitiesEvenWithMatchingDigest() throws {
        let version = try InstallerVersion(ProvenanceV1Vector.installerVersion)
        let empty: [String] = []
        let unsorted = ["provider-gate/v1", "composition/v1"]
        let duplicate = ["composition/v1", "composition/v1"]

        XCTAssertThrowsError(
            try SealedInstallerReleaseProvenance(
                provenanceSHA256: SealedInstallerReleaseProvenance.canonicalSHA256(
                    installerVersion: version,
                    channel: .candidate,
                    releaseSequence: ProvenanceV1Vector.releaseSequence,
                    sourceRevision: ProvenanceV1Vector.sourceRevision,
                    policyRevision: ProvenanceV1Vector.policyRevision,
                    capabilities: empty,
                    releaseTrustConfigurationSHA256: ProvenanceV1Vector.releaseTrustConfigurationSHA256
                ),
                installerVersion: version,
                channel: .candidate,
                releaseSequence: ProvenanceV1Vector.releaseSequence,
                sourceRevision: ProvenanceV1Vector.sourceRevision,
                policyRevision: ProvenanceV1Vector.policyRevision,
                capabilities: empty,
                releaseTrustConfigurationSHA256: ProvenanceV1Vector.releaseTrustConfigurationSHA256
            )
        )
        XCTAssertThrowsError(
            try SealedInstallerReleaseProvenance(
                provenanceSHA256: SealedInstallerReleaseProvenance.canonicalSHA256(
                    installerVersion: version,
                    channel: .candidate,
                    releaseSequence: ProvenanceV1Vector.releaseSequence,
                    sourceRevision: ProvenanceV1Vector.sourceRevision,
                    policyRevision: ProvenanceV1Vector.policyRevision,
                    capabilities: unsorted,
                    releaseTrustConfigurationSHA256: ProvenanceV1Vector.releaseTrustConfigurationSHA256
                ),
                installerVersion: version,
                channel: .candidate,
                releaseSequence: ProvenanceV1Vector.releaseSequence,
                sourceRevision: ProvenanceV1Vector.sourceRevision,
                policyRevision: ProvenanceV1Vector.policyRevision,
                capabilities: unsorted,
                releaseTrustConfigurationSHA256: ProvenanceV1Vector.releaseTrustConfigurationSHA256
            )
        )
        XCTAssertThrowsError(
            try SealedInstallerReleaseProvenance(
                provenanceSHA256: SealedInstallerReleaseProvenance.canonicalSHA256(
                    installerVersion: version,
                    channel: .candidate,
                    releaseSequence: ProvenanceV1Vector.releaseSequence,
                    sourceRevision: ProvenanceV1Vector.sourceRevision,
                    policyRevision: ProvenanceV1Vector.policyRevision,
                    capabilities: duplicate,
                    releaseTrustConfigurationSHA256: ProvenanceV1Vector.releaseTrustConfigurationSHA256
                ),
                installerVersion: version,
                channel: .candidate,
                releaseSequence: ProvenanceV1Vector.releaseSequence,
                sourceRevision: ProvenanceV1Vector.sourceRevision,
                policyRevision: ProvenanceV1Vector.policyRevision,
                capabilities: duplicate,
                releaseTrustConfigurationSHA256: ProvenanceV1Vector.releaseTrustConfigurationSHA256
            )
        )
    }

    func testProvenanceRetainsOnlyExactDescriptorIdentityComparison() throws {
        let provenance = try makeProvenance()

        XCTAssertTrue(
            provenance.matchesExpectedDescriptorIdentity(
                expectedProvenanceSHA256: provenance.provenanceSHA256,
                expectedReleaseTrustConfigurationSHA256: provenance.releaseTrustConfigurationSHA256
            )
        )
        XCTAssertFalse(
            provenance.matchesExpectedDescriptorIdentity(
                expectedProvenanceSHA256: String(repeating: "a", count: 64),
                expectedReleaseTrustConfigurationSHA256: provenance.releaseTrustConfigurationSHA256
            )
        )
        XCTAssertFalse(
            provenance.matchesExpectedDescriptorIdentity(
                expectedProvenanceSHA256: provenance.provenanceSHA256,
                expectedReleaseTrustConfigurationSHA256: String(repeating: "b", count: 64)
            )
        )
        XCTAssertFalse(
            provenance.matchesExpectedDescriptorIdentity(
                expectedProvenanceSHA256: "invalid",
                expectedReleaseTrustConfigurationSHA256: provenance.releaseTrustConfigurationSHA256
            )
        )
    }

    func testSourceBuildWithoutProvenanceFailsClosedAfterSealedBundleValidation() async {
        let validator = ProvenanceBundleValidatorSpy(result: .success(()))
        let loader = BundleSealedInstallerReleaseProvenanceLoader(
            bundle: Bundle(for: InstallerReleaseProvenanceTestMarker.self),
            resourceName: "missing-installer-release-provenance",
            bundleValidator: validator
        )

        let result = await loader.loadSealedReleaseProvenance()

        XCTAssertEqual(
            result,
            .failure(InstallerSelfUpdateFailure(.sealedReleaseProvenanceAbsent))
        )
        XCTAssertEqual(validator.callCount(), 1)
    }

    func testProvenanceLoaderRejectsBeforeReadingResourceWhenBundleIsNotSealed() async {
        let validator = ProvenanceBundleValidatorSpy(result: .failure(
            InstallerSelfUpdateFailure(.sealedReleaseTrustConfigurationAbsent)
        ))
        let loader = BundleSealedInstallerReleaseProvenanceLoader(
            bundle: Bundle(for: InstallerReleaseProvenanceTestMarker.self),
            resourceName: "missing-installer-release-provenance",
            bundleValidator: validator
        )

        let result = await loader.loadSealedReleaseProvenance()

        XCTAssertEqual(
            result,
            .failure(InstallerSelfUpdateFailure(.sealedReleaseProvenanceAbsent))
        )
        XCTAssertEqual(validator.callCount(), 1)
    }

    private func makeProvenance() throws -> SealedInstallerReleaseProvenance {
        let installerVersion = try InstallerVersion(ProvenanceV1Vector.installerVersion)
        return try SealedInstallerReleaseProvenance(
            provenanceSHA256: ProvenanceV1Vector.provenanceSHA256,
            installerVersion: installerVersion,
            channel: .candidate,
            releaseSequence: ProvenanceV1Vector.releaseSequence,
            sourceRevision: ProvenanceV1Vector.sourceRevision,
            policyRevision: ProvenanceV1Vector.policyRevision,
            capabilities: ProvenanceV1Vector.capabilities,
            releaseTrustConfigurationSHA256: ProvenanceV1Vector.releaseTrustConfigurationSHA256
        )
    }

    private func makeProvenanceJSON(_ provenance: SealedInstallerReleaseProvenance) -> String {
        let capabilities = provenance.capabilities.map { "\"\($0)\"" }.joined(separator: ",")
        return "{"
            + "\"schema_version\":1,"
            + "\"provenance_sha256\":\"\(provenance.provenanceSHA256)\","
            + "\"installer_version\":\"\(provenance.installerVersion.description)\","
            + "\"channel\":\"\(provenance.channel.rawValue)\","
            + "\"release_sequence\":\(provenance.releaseSequence),"
            + "\"source_revision\":\"\(provenance.sourceRevision)\","
            + "\"policy_revision\":\"\(provenance.policyRevision)\","
            + "\"capabilities\":[\(capabilities)],"
            + "\"release_trust_configuration_sha256\":\"\(provenance.releaseTrustConfigurationSHA256)\""
            + "}"
    }
}

private enum ProvenanceV1Vector {
    static let installerVersion = "1.2.3"
    static let releaseSequence: UInt64 = 42
    static let sourceRevision = "0123456789abcdef0123456789abcdef01234567"
    static let policyRevision = "forge-platform-installer-release-v1"
    static let capabilities = ["composition/v1", "provider-gate/v1"]
    static let releaseTrustConfigurationSHA256 = "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"
    static let provenanceSHA256 = "729e5463b3be32799a97ab13109f38552b46cf8c56c17ce8595e58bc5d585159"
}

private final class InstallerReleaseProvenanceTestMarker: NSObject {}

private final class ProvenanceBundleValidatorSpy: SealedInstallerBundleValidating, @unchecked Sendable {
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
