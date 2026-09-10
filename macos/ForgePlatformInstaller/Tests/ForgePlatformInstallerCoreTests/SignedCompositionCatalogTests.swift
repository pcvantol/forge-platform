import CryptoKit
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class SignedCompositionCatalogTests: XCTestCase {
    func testThresholdSignedCatalogReturnsOnlyVerifiedOuterEvidenceAndCandidateAnchor() throws {
        let fixture = try CatalogFixture()
        let bytes = try fixture.signedCatalogBytes()
        let result = fixture.verifier.verify(
            try fixture.readback(bytes),
            for: fixture.currentInstaller,
            acceptedCatalog: nil,
            now: fixture.now
        )

        guard case .success(let catalog) = result else {
            return XCTFail("A complete threshold-signed catalog should be admitted")
        }
        XCTAssertEqual(catalog.channel, .stable)
        XCTAssertEqual(catalog.identity.sequence, 2)
        XCTAssertEqual(catalog.entries.map(\.compositionID), ["forge-ep-workspace-v1"])
        XCTAssertEqual(catalog.entries.first?.manifest.sha256, "sha256:" + String(repeating: "a", count: 64))
        XCTAssertEqual(catalog.componentCombinationCatalog?.sha256, "sha256:" + String(repeating: "b", count: 64))
        XCTAssertEqual(catalog.candidateAcceptance.scope.channel, .stable)
        XCTAssertEqual(catalog.candidateAcceptance.scope.feedURL, fixture.feed.url)
        XCTAssertEqual(
            catalog.candidateAcceptance.scope.installerReleaseTrustConfigurationSHA256,
            fixture.currentInstaller.installerReleaseTrustConfigurationSHA256
        )
        XCTAssertEqual(catalog.candidateAcceptance.identity, catalog.identity)
        XCTAssertNotEqual(catalog.identity.sha256, catalog.componentCombinationCatalog?.sha256)
    }

    func testThresholdSignatureFailuresAndUnknownKeysFailClosed() throws {
        let fixture = try CatalogFixture()
        let cases: [Data] = [
            try fixture.signedCatalogBytes(signingKeyIDs: ["catalog-a"]),
            try fixture.signedCatalogBytes(signingKeyIDs: ["catalog-a", "catalog-a"]),
            try fixture.signedCatalogBytes(signingKeyIDs: ["catalog-untrusted"]),
            fixture.corruptSignature(try fixture.signedCatalogBytes()),
        ]

        for bytes in cases {
            XCTAssertEqual(
                fixture.verifier.verify(
                    try fixture.readback(bytes),
                    for: fixture.currentInstaller,
                    acceptedCatalog: nil,
                    now: fixture.now
                ),
                .failure(.catalogRejected)
            )
        }
    }

    func testStrictShapeDuplicateKeysAndDuplicateCapabilitiesCannotBeSignedIntoAuthority() throws {
        let fixture = try CatalogFixture()
        let unknownUnsigned = fixture.unsignedCatalog(
            extraTopLevelField: "\"unexpected\":true,"
        )
        let duplicateCapabilities = fixture.unsignedCatalog(
            capabilities: ["catalog-component-set/v1", "catalog-component-set/v1"]
        )
        let whitespaceCompositionID = fixture.unsignedCatalog(compositionID: "forge ep workspace v1")
        let overlongCompositionID = fixture.unsignedCatalog(compositionID: String(repeating: "x", count: 257))
        let duplicateRoot = Data(
            "{\"schema\":\"forge-platform.composition-catalog/v1\",\"schema\":\"forge-platform.composition-catalog/v1\"}".utf8
        )
        let cases: [Data] = [
            try fixture.signedCatalogBytes(unsigned: unknownUnsigned),
            try fixture.signedCatalogBytes(unsigned: duplicateCapabilities),
            try fixture.signedCatalogBytes(unsigned: whitespaceCompositionID),
            try fixture.signedCatalogBytes(unsigned: overlongCompositionID),
            duplicateRoot,
        ]

        for bytes in cases {
            XCTAssertEqual(
                fixture.verifier.verify(
                    try fixture.readback(bytes),
                    for: fixture.currentInstaller,
                    acceptedCatalog: nil,
                    now: fixture.now
                ),
                .failure(.catalogRejected)
            )
        }
    }

    func testCatalogRequiresBoundFeedTrustConfigurationAndFreshTrustedClock() throws {
        let fixture = try CatalogFixture()
        let bytes = try fixture.signedCatalogBytes()
        let wrongFeed = try VerifiedCompositionCatalogFeedLocator(url: "https://catalog.example.test/other.json")
        let policyForOtherTrust = try fixture.policy(boundTrustDigest: String(repeating: "e", count: 64))
        let otherVerifier = SignedCompositionCatalogFeedVerifier(signaturePolicy: policyForOtherTrust)

        XCTAssertEqual(
            fixture.verifier.verify(
                try fixture.readback(bytes, feed: wrongFeed),
                for: fixture.currentInstaller,
                acceptedCatalog: nil,
                now: fixture.now
            ),
            .failure(.catalogRejected)
        )
        XCTAssertEqual(
            otherVerifier.verify(
                try fixture.readback(bytes),
                for: fixture.currentInstaller,
                acceptedCatalog: nil,
                now: fixture.now
            ),
            .failure(.catalogRejected)
        )
        XCTAssertEqual(
            fixture.verifier.verify(
                try fixture.readback(bytes, trustedClock: false),
                for: fixture.currentInstaller,
                acceptedCatalog: nil,
                now: fixture.now
            ),
            .failure(.trustedClockUnavailable)
        )
        XCTAssertEqual(
            fixture.verifier.verify(
                try fixture.readback(bytes, freshUntil: fixture.now.addingTimeInterval(1)),
                for: fixture.currentInstaller,
                acceptedCatalog: nil,
                now: fixture.now.addingTimeInterval(1)
            ),
            .failure(.trustedClockUnavailable)
        )
    }

    func testCatalogRejectsWrongChannelExpiredAndFuturePublication() throws {
        let fixture = try CatalogFixture()
        let cases: [Data] = [
            try fixture.signedCatalogBytes(channel: "candidate"),
            try fixture.signedCatalogBytes(expiresAt: "2026-09-10T11:00:00Z"),
            try fixture.signedCatalogBytes(publishedAt: "2026-09-10T12:30:00Z"),
        ]

        for bytes in cases {
            XCTAssertEqual(
                fixture.verifier.verify(
                    try fixture.readback(bytes),
                    for: fixture.currentInstaller,
                    acceptedCatalog: nil,
                    now: fixture.now
                ),
                .failure(.catalogRejected)
            )
        }

        // The catalog was fresh when it was observed, but expired before the
        // still-fresh trusted-clock evidence reached the verifier. It must
        // not remain selectable for the rest of that five-minute window.
        XCTAssertEqual(
            fixture.verifier.verify(
                try fixture.readback(
                    try fixture.signedCatalogBytes(expiresAt: "2026-09-10T11:59:30Z"),
                    observedAt: fixture.now.addingTimeInterval(-60),
                    freshUntil: fixture.now.addingTimeInterval(60)
                ),
                for: fixture.currentInstaller,
                acceptedCatalog: nil,
                now: fixture.now
            ),
            .failure(.catalogRejected)
        )
    }

    func testReplayInputRejectsLowerSequenceAndDifferentBytesUnderSameSequence() throws {
        let fixture = try CatalogFixture()
        let first = fixture.verifier.verify(
            try fixture.readback(try fixture.signedCatalogBytes(sequence: 2)),
            for: fixture.currentInstaller,
            acceptedCatalog: nil,
            now: fixture.now
        )
        guard case .success(let acceptedCatalog) = first else {
            return XCTFail("Initial catalog must produce a candidate acceptance anchor")
        }

        XCTAssertEqual(
            fixture.verifier.verify(
                try fixture.readback(try fixture.signedCatalogBytes(sequence: 1)),
                for: fixture.currentInstaller,
                acceptedCatalog: acceptedCatalog.candidateAcceptance,
                now: fixture.now
            ),
            .failure(.catalogRejected)
        )
        XCTAssertEqual(
            fixture.verifier.verify(
                try fixture.readback(
                    try fixture.signedCatalogBytes(sequence: 2, manifestDigestCharacter: "c")
                ),
                for: fixture.currentInstaller,
                acceptedCatalog: acceptedCatalog.candidateAcceptance,
                now: fixture.now
            ),
            .failure(.catalogRejected)
        )
        guard case .success(let newer) = fixture.verifier.verify(
            try fixture.readback(try fixture.signedCatalogBytes(sequence: 3)),
            for: fixture.currentInstaller,
            acceptedCatalog: acceptedCatalog.candidateAcceptance,
            now: fixture.now
        ) else {
            return XCTFail("A newer signed catalog should remain eligible for later persistence")
        }
        XCTAssertEqual(newer.candidateAcceptance.identity.sequence, 3)
    }

    func testCompositionIdentitiesPreserveExactUnicodeScalarSequences() throws {
        let fixture = try CatalogFixture()
        let composed = "\u{00E9}"
        let decomposed = "e\u{0301}"
        XCTAssertNotEqual(Data(composed.utf8), Data(decomposed.utf8))

        let bytes = try fixture.signedCatalogBytes(
            unsigned: fixture.unsignedCatalog(
                compositionID: composed,
                additionalCompositionID: decomposed
            )
        )
        let result = fixture.verifier.verify(
            try fixture.readback(bytes),
            for: fixture.currentInstaller,
            acceptedCatalog: nil,
            now: fixture.now
        )
        guard case .success(let catalog) = result else {
            return XCTFail("Distinct signed Unicode scalar sequences must not collapse into one identity")
        }
        XCTAssertEqual(catalog.entries.count, 2)
        XCTAssertEqual(Set(catalog.entries.map { Data($0.compositionID.utf8) }).count, 2)
    }

    func testCanonicalUnicodeMatchesPythonEnsureASCIIAndDepthIsBounded() throws {
        let fixture = try CatalogFixture()
        var canonicalReader = try StrictJSONResourceReader(
            data: Data("{\"signatures\":[],\"schema\":\"forge-platform.composition-catalog/v1\",\"note\":\"é🚀\"}".utf8)
        )
        XCTAssertEqual(
            String(
                decoding: try GitHubInstallerReleaseDescriptor.canonicalUnsignedPayload(
                    from: canonicalReader.parseDocument()
                ),
                as: UTF8.self
            ),
            "{\"note\":\"\\u00e9\\ud83d\\ude80\",\"schema\":\"forge-platform.composition-catalog/v1\"}"
        )
        let unsigned = fixture.unsignedCatalog(compositionID: "forge-é-🚀")
        let bytes = try fixture.signedCatalogBytes(unsigned: unsigned)
        let result = fixture.verifier.verify(
            try fixture.readback(bytes),
            for: fixture.currentInstaller,
            acceptedCatalog: nil,
            now: fixture.now
        )
        guard case .success(let catalog) = result else {
            return XCTFail("Unicode in an otherwise valid catalog should be canonicalized before verification")
        }
        XCTAssertEqual(catalog.entries.first?.compositionID, "forge-é-🚀")

        let deepJSON = Data((String(repeating: "[", count: StrictJSONResourceReader.maximumNestingDepth + 1)
            + "0"
            + String(repeating: "]", count: StrictJSONResourceReader.maximumNestingDepth + 1)).utf8)
        var reader = try StrictJSONResourceReader(data: deepJSON)
        XCTAssertThrowsError(try reader.parseDocument())
    }

    func testCatalogLocatorRejectsNonCanonicalURLs() throws {
        XCTAssertEqual(
            try VerifiedCompositionCatalogFeedLocator(
                url: "https://catalog.example.test/feed.json?cursor?"
            ).url,
            "https://catalog.example.test/feed.json?cursor?"
        )
        XCTAssertThrowsError(try VerifiedCompositionCatalogFeedLocator(url: "https://catalog.example.test:"))
        XCTAssertThrowsError(try VerifiedCompositionCatalogFeedLocator(url: "https://user@catalog.example.test/feed.json"))
        XCTAssertThrowsError(try VerifiedCompositionCatalogFeedLocator(url: "https://catalog.example.test/feed%"))
        XCTAssertThrowsError(try VerifiedCompositionCatalogFeedLocator(url: "https://catalog.example.test/feed.json?"))
        XCTAssertThrowsError(
            try VerifiedCompositionCatalogFeedLocator(
                url: "https://catalog.example.test/" + String(repeating: "a", count: 2_025)
            )
        )
    }
}

private struct CatalogFixture {
    private struct SigningKey {
        let id: String
        let key: Curve25519.Signing.PrivateKey
    }

    let now: Date
    let feed: VerifiedCompositionCatalogFeedLocator
    let currentInstaller: CurrentVerifiedInstallerCompositionContext
    let verifier: SignedCompositionCatalogFeedVerifier
    private let signingKeys: [SigningKey]
    private let trustDigest = String(repeating: "d", count: 64)

    init() throws {
        now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-10T12:00:00Z"))
        feed = try VerifiedCompositionCatalogFeedLocator(url: "https://catalog.example.test/catalog.json")
        let first = SigningKey(id: "catalog-a", key: Curve25519.Signing.PrivateKey())
        let second = SigningKey(id: "catalog-b", key: Curve25519.Signing.PrivateKey())
        let untrusted = SigningKey(id: "catalog-untrusted", key: Curve25519.Signing.PrivateKey())
        signingKeys = [first, second, untrusted]
        let catalogKeys = try [first, second].map {
            try CompositionCatalogTrustEd25519PublicKey(
                keyID: $0.id,
                publicKeyBase64: $0.key.publicKey.rawRepresentation.base64EncodedString()
            )
        }
        let catalogPolicy = try CompositionCatalogSignaturePolicy(
            installerReleaseTrustConfigurationSHA256: trustDigest,
            signatureThreshold: 2,
            ed25519PublicKeys: catalogKeys
        )
        verifier = SignedCompositionCatalogFeedVerifier(signaturePolicy: catalogPolicy)

        let asset = try GitHubInstallerReleaseAsset(
            repository: "example-owner/forge-platform-installer",
            tag: "installer-1.0.0",
            assetName: "ForgePlatformInstaller.zip"
        )
        let release = VerifiedInstallerRelease(
            version: try InstallerVersion("1.0.0"),
            releasePage: asset.releasePage,
            assetName: asset.assetName,
            sha256: String(repeating: "a", count: 64),
            signingKeyID: "release-key"
        )
        let record = try VerifiedInstallerReleaseRecord(
            release: release,
            sequence: 7,
            channel: .stable,
            sourceRevision: String(repeating: "b", count: 40),
            expectedBundleIdentifier: "com.example.forge-platform-installer",
            expectedTeamIdentifier: "ABCDE12345",
            expectedCodeDirectorySHA256: String(repeating: "c", count: 64),
            policyRevision: "release-v1",
            capabilities: ["composition/v1", "provider-gate/v1"],
            provenanceSHA256: String(repeating: "e", count: 64),
            expectedReleaseTrustConfigurationSHA256: trustDigest,
            compositionCatalogFeed: feed,
            notarizationReference: "receipt:installer-v1",
            githubAsset: asset
        )
        currentInstaller = CurrentVerifiedInstallerCompositionContext(release: record)
    }

    func policy(boundTrustDigest: String? = nil) throws -> CompositionCatalogSignaturePolicy {
        let keys = try signingKeys.prefix(2).map {
            try CompositionCatalogTrustEd25519PublicKey(
                keyID: $0.id,
                publicKeyBase64: $0.key.publicKey.rawRepresentation.base64EncodedString()
            )
        }
        return try CompositionCatalogSignaturePolicy(
            installerReleaseTrustConfigurationSHA256: boundTrustDigest ?? trustDigest,
            signatureThreshold: 2,
            ed25519PublicKeys: keys
        )
    }

    func readback(
        _ bytes: Data,
        feed: VerifiedCompositionCatalogFeedLocator? = nil,
        observedAt: Date? = nil,
        freshUntil: Date? = nil,
        trustedClock: Bool = true
    ) throws -> CompositionCatalogFeedReadback {
        let readbackObservedAt = observedAt ?? now
        return try CompositionCatalogFeedReadback(
            feed: feed ?? self.feed,
            bytes: bytes,
            observedAt: readbackObservedAt,
            freshUntil: freshUntil ?? readbackObservedAt.addingTimeInterval(60),
            trustedClock: trustedClock
        )
    }

    func unsignedCatalog(
        sequence: UInt64 = 2,
        channel: String = "stable",
        publishedAt: String = "2026-09-10T11:00:00Z",
        expiresAt: String = "2026-09-10T13:00:00Z",
        compositionID: String = "forge-ep-workspace-v1",
        additionalCompositionID: String? = nil,
        manifestDigestCharacter: Character = "a",
        capabilities: [String] = ["catalog-component-set/v1", "composition/v1"],
        extraTopLevelField: String = ""
    ) -> String {
        let capabilityJSON = capabilities.map { "\"\($0)\"" }.joined(separator: ",")
        let manifestDigest = "sha256:" + String(repeating: String(manifestDigestCharacter), count: 64)
        let indexDigest = "sha256:" + String(repeating: "b", count: 64)
        func composition(_ identity: String) -> String {
            "{\"channel\":\"\(channel)\",\"composition_id\":\"\(identity)\",\"digest\":\"\(manifestDigest)\",\"requires_installer\":{\"capabilities\":[\(capabilityJSON)],\"minimum_version\":\"1.0.0\"},\"url\":\"https://catalog.example.test/manifests/forge-ep-workspace-v1.json\"}"
        }
        let compositions = [composition(compositionID)]
            + (additionalCompositionID.map { [composition($0)] } ?? [])
        return "{\"channel\":\"\(channel)\",\"component_combination_catalog\":{\"digest\":\"\(indexDigest)\",\"url\":\"https://catalog.example.test/component-index.json\"},\"compositions\":[\(compositions.joined(separator: ","))],\"expires_at\":\"\(expiresAt)\",\(extraTopLevelField)\"published_at\":\"\(publishedAt)\",\"schema\":\"forge-platform.composition-catalog/v1\",\"sequence\":\(sequence)}"
    }

    func signedCatalogBytes(
        sequence: UInt64 = 2,
        channel: String = "stable",
        publishedAt: String = "2026-09-10T11:00:00Z",
        expiresAt: String = "2026-09-10T13:00:00Z",
        manifestDigestCharacter: Character = "a",
        signingKeyIDs: [String] = ["catalog-a", "catalog-b"]
    ) throws -> Data {
        try signedCatalogBytes(
            unsigned: unsignedCatalog(
                sequence: sequence,
                channel: channel,
                publishedAt: publishedAt,
                expiresAt: expiresAt,
                manifestDigestCharacter: manifestDigestCharacter
            ),
            signingKeyIDs: signingKeyIDs
        )
    }

    func signedCatalogBytes(
        unsigned: String,
        signingKeyIDs: [String] = ["catalog-a", "catalog-b"]
    ) throws -> Data {
        let unsignedWithEmptySignatures = "{\"signatures\":[],\(unsigned.dropFirst())"
        var reader = try StrictJSONResourceReader(data: Data(unsignedWithEmptySignatures.utf8))
        let payload = try GitHubInstallerReleaseDescriptor.canonicalUnsignedPayload(from: reader.parseDocument())
        let envelopes = try signingKeyIDs.map { identifier -> String in
            let signingKey = try XCTUnwrap(signingKeys.first(where: { $0.id == identifier }))
            let signature = try signingKey.key.signature(for: payload)
            return "{\"algorithm\":\"ed25519\",\"key_id\":\"\(identifier)\",\"signature\":\"\(base64URL(signature))\"}"
        }
        let signatureJSON = envelopes.joined(separator: ",")
        return Data("{\"signatures\":[\(signatureJSON)],\(unsigned.dropFirst())".utf8)
    }

    func corruptSignature(_ bytes: Data) -> Data {
        var string = String(decoding: bytes, as: UTF8.self)
        guard let range = string.range(of: "\"signature\":\"") else {
            return bytes
        }
        let index = range.upperBound
        let replacement = string[index] == "A" ? "B" : "A"
        string.replaceSubrange(index...index, with: replacement)
        return Data(string.utf8)
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
