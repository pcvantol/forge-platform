import CryptoKit
import Foundation
import Darwin

/// The GitHub lookup is only a locator.  It returns a tag plus the server time
/// observed over HTTPS; neither fact is a release trust root.  A caller must
/// still download and verify the descriptor under the code-signed public-key
/// policy before it can construct an installer release record.
public struct GitHubInstallerReleaseTagReadback: Equatable, Sendable {
    public let tag: String
    public let observedAt: Date

    public init(tag: String, observedAt: Date) throws {
        guard InstallerSelfUpdateValidation.isGitHubTag(tag) else {
            throw InstallerSelfUpdateMetadataError.invalidTag(tag)
        }
        self.tag = tag
        self.observedAt = observedAt
    }
}

/// Exact descriptor bytes returned by a GitHub Release asset.  The concrete
/// transport owns its redirect/HTTPS policy; the feed below owns strict JSON,
/// signature, expiry and anti-replay validation.
public struct GitHubInstallerReleaseDescriptorReadback: Sendable {
    public let bytes: Data
    public let observedAt: Date

    public init(bytes: Data, observedAt: Date) throws {
        guard !bytes.isEmpty, bytes.count <= GitHubInstallerReleaseDescriptor.maximumDescriptorBytes else {
            throw InstallerSelfUpdateMetadataError.invalidRecoveryRecord
        }
        self.bytes = bytes
        self.observedAt = observedAt
    }
}

/// The only transport seam used by the native signed-release feed.  It carries
/// no credentials, arbitrary endpoint, raw redirect target or product data.
/// A concrete implementation may contact GitHub, while tests can inject a
/// deterministic readback without network access.
public protocol GitHubInstallerReleaseDescriptorFetching: Sendable {
    func latestReleaseTag(
        for repository: String
    ) async -> Result<GitHubInstallerReleaseTagReadback, InstallerSelfUpdateFailure>

    func releaseDescriptor(
        repository: String,
        tag: String,
        descriptorAssetName: String
    ) async -> Result<GitHubInstallerReleaseDescriptorReadback, InstallerSelfUpdateFailure>
}

/// Durable anti-replay anchor for a signed installer descriptor.  It stores no
/// URL, path, token, provider state or product installation identity.  A
/// restart seeing a lower sequence, or different descriptor bytes under one
/// accepted sequence, must fail closed before the wizard is reachable.
public struct InstallerReleaseAcceptance: Codable, Equatable, Sendable {
    public let sequence: UInt64
    public let descriptorSHA256: String

    public init(sequence: UInt64, descriptorSHA256: String) throws {
        guard sequence > 0, InstallerSelfUpdateValidation.isSHA256(descriptorSHA256) else {
            throw InstallerSelfUpdateMetadataError.invalidRecoveryRecord
        }
        self.sequence = sequence
        self.descriptorSHA256 = descriptorSHA256
    }
}

/// Persistent implementations must use an installer-owned location outside
/// product stores.  The updater's host-wide self-update lock serializes calls
/// to this store; this API additionally makes the required monotonic state
/// explicit for testable replay behavior.
public protocol InstallerReleaseAcceptanceStoring: Sendable {
    func loadHighestAcceptedInstallerRelease() async -> Result<InstallerReleaseAcceptance?, InstallerSelfUpdateFailure>

    func saveHighestAcceptedInstallerRelease(
        _ acceptance: InstallerReleaseAcceptance
    ) async -> Result<Void, InstallerSelfUpdateFailure>
}

/// Small test/development implementation.  A released runtime must inject a
/// durable store; this actor intentionally loses its state on process exit and
/// is therefore not assembled by any released startup path.
public actor InMemoryInstallerReleaseAcceptanceStore: InstallerReleaseAcceptanceStoring {
    private var acceptance: InstallerReleaseAcceptance?

    public init(acceptance: InstallerReleaseAcceptance? = nil) {
        self.acceptance = acceptance
    }

    public func loadHighestAcceptedInstallerRelease() async -> Result<InstallerReleaseAcceptance?, InstallerSelfUpdateFailure> {
        .success(acceptance)
    }

    public func saveHighestAcceptedInstallerRelease(
        _ acceptance: InstallerReleaseAcceptance
    ) async -> Result<Void, InstallerSelfUpdateFailure> {
        self.acceptance = acceptance
        return .success(())
    }
}

/// Durable acceptance anchor for a released native installer.  The selected
/// directory is installer-owned and separate from every product data root.
/// The host-wide update lease serializes writers; strict readback makes a
/// corrupt, symlinked, foreign-owned or permissive anchor a fail-closed state
/// rather than an opportunity to silently forget an accepted release.
public struct FileInstallerReleaseAcceptanceStore: InstallerReleaseAcceptanceStoring {
    private static let fileName = "highest-accepted-installer-release.json"

    private let rootDirectory: URL

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory.standardizedFileURL.resolvingSymlinksInPath()
    }

    public func loadHighestAcceptedInstallerRelease() async -> Result<InstallerReleaseAcceptance?, InstallerSelfUpdateFailure> {
        do {
            let manager = FileManager.default
            guard manager.fileExists(atPath: acceptanceURL.path) else {
                return .success(nil)
            }
            guard try isSecureRegularFile(at: acceptanceURL) else {
                throw FileInstallerReleaseAcceptanceStoreError.insecure
            }
            let decoded = try JSONDecoder().decode(InstallerReleaseAcceptance.self, from: Data(contentsOf: acceptanceURL))
            let validated = try InstallerReleaseAcceptance(
                sequence: decoded.sequence,
                descriptorSHA256: decoded.descriptorSHA256
            )
            return .success(validated)
        } catch {
            return .failure(InstallerSelfUpdateFailure(.recoveryLoadFailed))
        }
    }

    public func saveHighestAcceptedInstallerRelease(
        _ acceptance: InstallerReleaseAcceptance
    ) async -> Result<Void, InstallerSelfUpdateFailure> {
        do {
            try ensureSecureRootDirectory()
            let validated = try InstallerReleaseAcceptance(
                sequence: acceptance.sequence,
                descriptorSHA256: acceptance.descriptorSHA256
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(validated)
            try data.write(to: acceptanceURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: acceptanceURL.path)
            guard try isSecureRegularFile(at: acceptanceURL) else {
                throw FileInstallerReleaseAcceptanceStoreError.insecure
            }
            return .success(())
        } catch {
            return .failure(InstallerSelfUpdateFailure(.recoveryPersistenceFailed))
        }
    }

    private var acceptanceURL: URL {
        rootDirectory.appendingPathComponent(Self.fileName, isDirectory: false)
    }

    private func ensureSecureRootDirectory() throws {
        let manager = FileManager.default
        try manager.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let attributes = try manager.attributesOfItem(atPath: rootDirectory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              attributes[.ownerAccountID] as? NSNumber == NSNumber(value: Darwin.geteuid()),
              let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o077 == 0 else {
            throw FileInstallerReleaseAcceptanceStoreError.insecure
        }
    }

    private func isSecureRegularFile(at url: URL) throws -> Bool {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              attributes[.ownerAccountID] as? NSNumber == NSNumber(value: Darwin.geteuid()),
              let permissions = attributes[.posixPermissions] as? NSNumber else {
            return false
        }
        return permissions.intValue & 0o077 == 0
    }
}

private enum FileInstallerReleaseAcceptanceStoreError: Error {
    case insecure
}

/// Concrete `SignedInstallerReleaseFeedVerifying` implementation for the
/// native bootstrap boundary.  GitHub identifies the current release tag, but
/// only the sealed key threshold verifies the descriptor itself.  The returned
/// record has no mutable URL and is later bound to a separately staged archive
/// by the self-update coordinator.
public actor GitHubSignedInstallerReleaseFeed: SignedInstallerReleaseFeedVerifying {
    private let trustConfiguration: SealedInstallerReleaseTrustConfiguration
    private let sealedReleaseProvenance: SealedInstallerReleaseProvenance
    private let architecture: String
    private let fetcher: any GitHubInstallerReleaseDescriptorFetching
    private let acceptanceStore: any InstallerReleaseAcceptanceStoring

    public init(
        trustConfiguration: SealedInstallerReleaseTrustConfiguration,
        sealedReleaseProvenance: SealedInstallerReleaseProvenance,
        architecture: String,
        fetcher: any GitHubInstallerReleaseDescriptorFetching,
        acceptanceStore: any InstallerReleaseAcceptanceStoring
    ) throws {
        guard GitHubInstallerReleaseDescriptor.isSupportedArchitecture(architecture) else {
            throw InstallerSelfUpdateMetadataError.invalidRecoveryRecord
        }
        self.trustConfiguration = trustConfiguration
        self.sealedReleaseProvenance = sealedReleaseProvenance
        self.architecture = architecture
        self.fetcher = fetcher
        self.acceptanceStore = acceptanceStore
    }

    public func latestVerifiedInstallerRelease() async -> Result<VerifiedInstallerReleaseRecord, InstallerSelfUpdateFailure> {
        let tagReadback: GitHubInstallerReleaseTagReadback
        switch await fetcher.latestReleaseTag(for: trustConfiguration.repository) {
        case .success(let readback):
            tagReadback = readback
        case .failure(let failure):
            return .failure(failure)
        }

        let descriptorReadback: GitHubInstallerReleaseDescriptorReadback
        switch await fetcher.releaseDescriptor(
            repository: trustConfiguration.repository,
            tag: tagReadback.tag,
            descriptorAssetName: trustConfiguration.releaseDescriptorAssetName
        ) {
        case .success(let readback):
            descriptorReadback = readback
        case .failure(let failure):
            return .failure(failure)
        }

        let descriptor: GitHubInstallerReleaseDescriptor
        do {
            descriptor = try GitHubInstallerReleaseDescriptor.decode(
                bytes: descriptorReadback.bytes,
                trustConfiguration: trustConfiguration,
                expectedChannel: sealedReleaseProvenance.channel,
                expectedTag: tagReadback.tag,
                observedAt: descriptorReadback.observedAt
            )
        } catch {
            return .failure(InstallerSelfUpdateFailure(.releaseMetadataRejected))
        }

        let descriptorSHA256 = GitHubInstallerReleaseDescriptor.sha256(of: descriptorReadback.bytes)
        let accepted: InstallerReleaseAcceptance?
        switch await acceptanceStore.loadHighestAcceptedInstallerRelease() {
        case .success(let stored):
            accepted = stored
        case .failure(let failure):
            return .failure(failure)
        }

        if let accepted {
            guard descriptor.sequence >= accepted.sequence else {
                return .failure(InstallerSelfUpdateFailure(.releaseMetadataRejected))
            }
            if descriptor.sequence == accepted.sequence,
               descriptorSHA256 != accepted.descriptorSHA256 {
                return .failure(InstallerSelfUpdateFailure(.releaseMetadataRejected))
            }
        }

        if accepted?.sequence != descriptor.sequence {
            do {
                let nextAcceptance = try InstallerReleaseAcceptance(
                    sequence: descriptor.sequence,
                    descriptorSHA256: descriptorSHA256
                )
                guard case .success = await acceptanceStore.saveHighestAcceptedInstallerRelease(nextAcceptance) else {
                    return .failure(InstallerSelfUpdateFailure(.recoveryPersistenceFailed))
                }
            } catch {
                return .failure(InstallerSelfUpdateFailure(.recoveryPersistenceFailed))
            }
        }

        guard let record = descriptor.verifiedReleaseRecord(for: architecture) else {
            return .failure(InstallerSelfUpdateFailure(.releaseMetadataRejected))
        }
        return .success(record)
    }
}

/// Strict decoded release descriptor.  It is deliberately internal: callers
/// only receive the already-verified immutable `VerifiedInstallerReleaseRecord`.
/// The wire format mirrors `forge-platform.installer-release/v1` and its
/// release-side Python canonicalization.
struct GitHubInstallerReleaseDescriptor: Sendable {
    static let schema = "forge-platform.installer-release/v1"
    static let maximumDescriptorBytes = 128 * 1024
    private static let maximumFuturePublicationSkew: TimeInterval = 5 * 60

    let sequence: UInt64
    let channel: InstallerReleaseChannel
    let version: InstallerVersion
    let sourceRevision: String
    let policyRevision: String
    let capabilities: [String]
    let expectedReleaseTrustConfigurationSHA256: String
    let provenanceSHA256: String
    let githubRepository: String
    let githubTag: String
    let descriptorAssetName: String
    let signingKeyID: String
    let assets: [Asset]

    struct Asset: Sendable {
        let architecture: String
        let assetName: String
        let archiveSHA256: String
        let bundleIdentifier: String
        let teamIdentifier: String
        let codeDirectorySHA256: String
        let notarizationReceiptReference: String
    }

    static func decode(
        bytes: Data,
        trustConfiguration: SealedInstallerReleaseTrustConfiguration,
        expectedChannel: InstallerReleaseChannel,
        expectedTag: String,
        observedAt: Date
    ) throws -> GitHubInstallerReleaseDescriptor {
        guard !bytes.isEmpty, bytes.count <= maximumDescriptorBytes,
              InstallerSelfUpdateValidation.isGitHubTag(expectedTag) else {
            throw GitHubInstallerReleaseDescriptorError.invalid
        }

        var reader = try StrictJSONResourceReader(data: bytes)
        let root = try reader.parseDocument()
        guard let fields = root.objectValue,
              Set(fields.keys) == Set([
                  "schema", "sequence", "channel", "published_at", "expires_at", "github_release",
                  "installer", "composition_catalog", "signatures",
              ]),
              fields["schema"]?.stringValue == schema,
              let sequence = fields["sequence"]?.positiveUInt64Value,
              let channelRaw = fields["channel"]?.stringValue,
              let channel = InstallerReleaseChannel(rawValue: channelRaw),
              channel == expectedChannel,
              let publishedAtRaw = fields["published_at"]?.stringValue,
              let expiresAtRaw = fields["expires_at"]?.stringValue,
              let publishedAt = parseRFC3339(publishedAtRaw),
              let expiresAt = parseRFC3339(expiresAtRaw),
              expiresAt > publishedAt,
              expiresAt > observedAt,
              publishedAt <= observedAt.addingTimeInterval(maximumFuturePublicationSkew),
              let githubRelease = fields["github_release"]?.objectValue,
              let installer = fields["installer"]?.objectValue,
              let catalog = fields["composition_catalog"]?.objectValue,
              let signatures = fields["signatures"]?.arrayValue else {
            throw GitHubInstallerReleaseDescriptorError.invalid
        }

        guard Set(githubRelease.keys) == Set(["repository", "tag", "descriptor_asset_name"]),
              let githubRepository = githubRelease["repository"]?.stringValue,
              githubRepository == trustConfiguration.repository,
              let githubTag = githubRelease["tag"]?.stringValue,
              githubTag == expectedTag,
              InstallerSelfUpdateValidation.isGitHubTag(githubTag),
              let descriptorAssetName = githubRelease["descriptor_asset_name"]?.stringValue,
              descriptorAssetName == trustConfiguration.releaseDescriptorAssetName,
              GitHubInstallerReleaseDescriptorValidation.isDescriptorAssetName(descriptorAssetName) else {
            throw GitHubInstallerReleaseDescriptorError.invalid
        }

        guard Set(installer.keys) == Set([
            "version", "source_revision", "policy_revision", "release_trust_configuration_sha256",
            "provenance_sha256", "capabilities", "assets",
        ]),
              let versionRaw = installer["version"]?.stringValue,
              let version = try? InstallerVersion(versionRaw),
              let sourceRevision = installer["source_revision"]?.stringValue,
              InstallerSelfUpdateValidation.isGitRevision(sourceRevision),
              let policyRevision = installer["policy_revision"]?.stringValue,
              GitHubInstallerReleaseDescriptorValidation.isPublicIdentifier(policyRevision),
              let releaseTrustConfigurationSHA256 = installer["release_trust_configuration_sha256"]?.stringValue,
              InstallerSelfUpdateValidation.isSHA256(releaseTrustConfigurationSHA256),
              let provenanceSHA256 = installer["provenance_sha256"]?.stringValue,
              InstallerSelfUpdateValidation.isSHA256(provenanceSHA256),
              let capabilities = installer["capabilities"]?.arrayValue,
              let assets = installer["assets"]?.arrayValue else {
            throw GitHubInstallerReleaseDescriptorError.invalid
        }

        let parsedCapabilities = try capabilities.map { value -> String in
            guard let capability = value.stringValue,
                  GitHubInstallerReleaseDescriptorValidation.isPublicIdentifier(capability) else {
                throw GitHubInstallerReleaseDescriptorError.invalid
            }
            return capability
        }
        guard GitHubInstallerReleaseDescriptorValidation.hasStrictlyAscendingUnique(parsedCapabilities) else {
            throw GitHubInstallerReleaseDescriptorError.invalid
        }

        guard Set(catalog.keys) == Set(["url"]),
              let catalogURL = catalog["url"]?.stringValue,
              GitHubInstallerReleaseDescriptorValidation.isHTTPSURL(catalogURL) else {
            throw GitHubInstallerReleaseDescriptorError.invalid
        }

        let parsedAssets = try assets.map(parseAsset)
        guard !parsedAssets.isEmpty,
              Set(parsedAssets.map { $0.architecture }).count == parsedAssets.count,
              Set(parsedAssets.map { $0.assetName }).count == parsedAssets.count else {
            throw GitHubInstallerReleaseDescriptorError.invalid
        }

        let signatureEnvelopes = try signatures.map(parseSignature)
        let canonicalPayload = try canonicalUnsignedPayload(from: root)
        let verifiedKeyIDs = try verifySignatures(
            signatureEnvelopes,
            canonicalPayload: canonicalPayload,
            trustConfiguration: trustConfiguration
        )
        guard let signingKeyID = verifiedKeyIDs.sorted().first else {
            throw GitHubInstallerReleaseDescriptorError.invalid
        }

        // The descriptor is authorized by the currently sealed key threshold,
        // locator and bundle/team policy.  Its target trust-config digest is
        // intentionally not required to equal that current configuration: a
        // verified target may rotate the config.  The staged target bundle is
        // checked against this exact digest before any handoff.
        return GitHubInstallerReleaseDescriptor(
            sequence: sequence,
            channel: channel,
            version: version,
            sourceRevision: sourceRevision,
            policyRevision: policyRevision,
            capabilities: parsedCapabilities,
            expectedReleaseTrustConfigurationSHA256: releaseTrustConfigurationSHA256,
            provenanceSHA256: provenanceSHA256,
            githubRepository: githubRepository,
            githubTag: githubTag,
            descriptorAssetName: descriptorAssetName,
            signingKeyID: signingKeyID,
            assets: parsedAssets
        )
    }

    func verifiedReleaseRecord(for architecture: String) -> VerifiedInstallerReleaseRecord? {
        guard let asset = assets.first(where: { $0.architecture == architecture }) else {
            return nil
        }
        do {
            let githubAsset = try GitHubInstallerReleaseAsset(
                repository: githubRepository,
                tag: githubTag,
                assetName: asset.assetName
            )
            let release = VerifiedInstallerRelease(
                version: version,
                releasePage: githubAsset.releasePage,
                assetName: asset.assetName,
                sha256: asset.archiveSHA256,
                signingKeyID: signingKeyID
            )
            return try VerifiedInstallerReleaseRecord(
                release: release,
                sequence: sequence,
                channel: channel,
                sourceRevision: sourceRevision,
                expectedBundleIdentifier: asset.bundleIdentifier,
                expectedTeamIdentifier: asset.teamIdentifier,
                expectedCodeDirectorySHA256: asset.codeDirectorySHA256,
                policyRevision: policyRevision,
                capabilities: capabilities,
                provenanceSHA256: provenanceSHA256,
                expectedReleaseTrustConfigurationSHA256: expectedReleaseTrustConfigurationSHA256,
                notarizationReference: asset.notarizationReceiptReference,
                githubAsset: githubAsset
            )
        } catch {
            return nil
        }
    }

    static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func isSupportedArchitecture(_ value: String) -> Bool {
        value == "arm64" || value == "x86_64"
    }

    private static func parseAsset(_ value: StrictJSONResourceValue) throws -> Asset {
        guard let fields = value.objectValue,
              Set(fields.keys) == Set([
                  "operating_system", "architecture", "asset_name", "digest", "bundle_identifier",
                  "team_identifier", "code_directory_sha256", "notarization_receipt_reference",
              ]),
              fields["operating_system"]?.stringValue == "macos",
              let architecture = fields["architecture"]?.stringValue,
              isSupportedArchitecture(architecture),
              let assetName = fields["asset_name"]?.stringValue,
              InstallerSelfUpdateValidation.isInstallerArchiveName(assetName),
              let digest = fields["digest"]?.stringValue,
              let archiveSHA256 = GitHubInstallerReleaseDescriptorValidation.rawDigest(fromTaggedDigest: digest),
              let bundleIdentifier = fields["bundle_identifier"]?.stringValue,
              InstallerSelfUpdateValidation.isBundleIdentifier(bundleIdentifier),
              let teamIdentifier = fields["team_identifier"]?.stringValue,
              InstallerSelfUpdateValidation.isTeamIdentifier(teamIdentifier),
              let codeDirectorySHA256 = fields["code_directory_sha256"]?.stringValue,
              InstallerSelfUpdateValidation.isSHA256(codeDirectorySHA256),
              let notarizationReceiptReference = fields["notarization_receipt_reference"]?.stringValue,
              InstallerSelfUpdateValidation.isNotarizationReceiptReference(notarizationReceiptReference) else {
            throw GitHubInstallerReleaseDescriptorError.invalid
        }
        return Asset(
            architecture: architecture,
            assetName: assetName,
            archiveSHA256: archiveSHA256,
            bundleIdentifier: bundleIdentifier,
            teamIdentifier: teamIdentifier,
            codeDirectorySHA256: codeDirectorySHA256,
            notarizationReceiptReference: notarizationReceiptReference
        )
    }

    private static func parseSignature(_ value: StrictJSONResourceValue) throws -> SignatureEnvelope {
        guard let fields = value.objectValue,
              Set(fields.keys) == Set(["algorithm", "key_id", "signature"]),
              fields["algorithm"]?.stringValue == "ed25519",
              let keyID = fields["key_id"]?.stringValue,
              GitHubInstallerReleaseDescriptorValidation.isKeyID(keyID),
              let signature = fields["signature"]?.stringValue,
              let rawSignature = GitHubInstallerReleaseDescriptorValidation.decodeCanonicalBase64URL(signature),
              rawSignature.count == 64 else {
            throw GitHubInstallerReleaseDescriptorError.invalid
        }
        return SignatureEnvelope(keyID: keyID, rawSignature: rawSignature)
    }

    private static func verifySignatures(
        _ signatures: [SignatureEnvelope],
        canonicalPayload: Data,
        trustConfiguration: SealedInstallerReleaseTrustConfiguration
    ) throws -> Set<String> {
        guard !signatures.isEmpty,
              signatures.count <= trustConfiguration.ed25519PublicKeys.count else {
            throw GitHubInstallerReleaseDescriptorError.invalid
        }
        let trustedKeys = Dictionary(uniqueKeysWithValues: trustConfiguration.ed25519PublicKeys.map {
            ($0.keyID, $0.publicKeyBase64)
        })
        var observedKeyIDs: Set<String> = []
        var verifiedKeyIDs: Set<String> = []
        for signature in signatures {
            guard observedKeyIDs.insert(signature.keyID).inserted,
                  let publicKeyBase64 = trustedKeys[signature.keyID],
                  let rawPublicKey = Data(base64Encoded: publicKeyBase64),
                  rawPublicKey.count == 32 else {
                throw GitHubInstallerReleaseDescriptorError.invalid
            }
            let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: rawPublicKey)
            guard publicKey.isValidSignature(signature.rawSignature, for: canonicalPayload) else {
                throw GitHubInstallerReleaseDescriptorError.invalid
            }
            verifiedKeyIDs.insert(signature.keyID)
        }
        guard verifiedKeyIDs.count >= trustConfiguration.signatureThreshold else {
            throw GitHubInstallerReleaseDescriptorError.invalid
        }
        return verifiedKeyIDs
    }

    static func canonicalUnsignedPayload(from root: StrictJSONResourceValue) throws -> Data {
        guard case .object(var fields) = root else {
            throw GitHubInstallerReleaseDescriptorError.invalid
        }
        guard fields.removeValue(forKey: "signatures") != nil else {
            throw GitHubInstallerReleaseDescriptorError.invalid
        }
        return Data(canonicalJSON(.object(fields)).utf8)
    }

    /// Matches Python's `json.dumps(..., sort_keys=True, separators=(",", ":"),
    /// ensure_ascii=True, allow_nan=False)` for the strict JSON value domain.
    private static func canonicalJSON(_ value: StrictJSONResourceValue) -> String {
        switch value {
        case .object(let fields):
            let encoded = fields.keys.sorted().map { key in
                canonicalString(key) + ":" + canonicalJSON(fields[key]!)
            }
            return "{" + encoded.joined(separator: ",") + "}"
        case .array(let values):
            return "[" + values.map(canonicalJSON).joined(separator: ",") + "]"
        case .string(let value):
            return canonicalString(value)
        case .integer(let value):
            return value
        case .boolean(let value):
            return value ? "true" : "false"
        case .null:
            return "null"
        }
    }

    private static func canonicalString(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 34:
                result += "\\\""
            case 92:
                result += "\\\\"
            case 8:
                result += "\\b"
            case 12:
                result += "\\f"
            case 10:
                result += "\\n"
            case 13:
                result += "\\r"
            case 9:
                result += "\\t"
            case 0...31:
                result += unicodeEscape(scalar.value)
            case 32...126:
                result.unicodeScalars.append(scalar)
            case 127...0xFFFF:
                result += unicodeEscape(scalar.value)
            default:
                let planeValue = scalar.value - 0x10000
                let high = 0xD800 + (planeValue >> 10)
                let low = 0xDC00 + (planeValue & 0x3FF)
                result += unicodeEscape(high)
                result += unicodeEscape(low)
            }
        }
        result += "\""
        return result
    }

    private static func unicodeEscape(_ value: UInt32) -> String {
        "\\u" + String(value, radix: 16, uppercase: false).leftPadding(to: 4, with: "0")
    }

    private static func parseRFC3339(_ value: String) -> Date? {
        guard GitHubInstallerReleaseDescriptorValidation.isASCII(value) else {
            return nil
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }

    private struct SignatureEnvelope: Sendable {
        let keyID: String
        let rawSignature: Data
    }
}

private enum GitHubInstallerReleaseDescriptorError: Error {
    case invalid
}

enum GitHubInstallerReleaseDescriptorValidation {
    static func isKeyID(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 128,
              let first = value.unicodeScalars.first,
              isLowercaseLetterOrDigit(first) else {
            return false
        }
        return value.unicodeScalars.allSatisfy { scalar in
            isLowercaseLetterOrDigit(scalar) || scalar.value == 45 || scalar.value == 46 || scalar.value == 95
        }
    }

    static func isDescriptorAssetName(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128, value.hasSuffix(".json") else {
            return false
        }
        let stem = value.dropLast(5)
        guard !stem.isEmpty,
              let first = stem.unicodeScalars.first,
              isASCIILetterOrDigit(first) else {
            return false
        }
        return stem.unicodeScalars.allSatisfy(isRepositoryScalar)
    }

    static func isPublicIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 128,
              let first = value.unicodeScalars.first,
              isLowercaseLetterOrDigit(first) else {
            return false
        }
        return value.unicodeScalars.allSatisfy { scalar in
            isLowercaseLetterOrDigit(scalar)
                || scalar.value == 45
                || scalar.value == 46
                || scalar.value == 95
                || scalar.value == 47
        }
    }

    static func hasStrictlyAscendingUnique(_ values: [String]) -> Bool {
        guard !values.isEmpty else {
            return false
        }
        return zip(values, values.dropFirst()).allSatisfy { current, next in current < next }
    }

    static func rawDigest(fromTaggedDigest value: String) -> String? {
        guard value.hasPrefix("sha256:") else {
            return nil
        }
        let raw = String(value.dropFirst("sha256:".count))
        return InstallerSelfUpdateValidation.isSHA256(raw) ? raw : nil
    }

    static func decodeCanonicalBase64URL(_ value: String) -> Data? {
        guard value.count == 86,
              value.unicodeScalars.allSatisfy({ scalar in
                  (48...57).contains(scalar.value)
                      || (65...90).contains(scalar.value)
                      || (97...122).contains(scalar.value)
                      || scalar.value == 45
                      || scalar.value == 95
              }),
              let decoded = Data(base64Encoded: value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "=="),
              decoded.count == 64 else {
            return nil
        }
        let encoded = decoded.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return encoded == value ? decoded : nil
    }

    static func isHTTPSURL(_ value: String) -> Bool {
        guard isASCII(value),
              let components = URLComponents(string: value),
              components.scheme == "https",
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              components.port == nil || components.port == 443,
              let url = components.url,
              url.absoluteString == value else {
            return false
        }
        return true
    }

    static func isASCII(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { $0.value <= 0x7F }
    }

    private static func isLowercaseLetterOrDigit(_ scalar: Unicode.Scalar) -> Bool {
        (48...57).contains(scalar.value) || (97...122).contains(scalar.value)
    }

    private static func isASCIILetterOrDigit(_ scalar: Unicode.Scalar) -> Bool {
        (48...57).contains(scalar.value)
            || (65...90).contains(scalar.value)
            || (97...122).contains(scalar.value)
    }

    private static func isRepositoryScalar(_ scalar: Unicode.Scalar) -> Bool {
        (48...57).contains(scalar.value)
            || (65...90).contains(scalar.value)
            || (97...122).contains(scalar.value)
            || scalar.value == 45
            || scalar.value == 46
            || scalar.value == 95
    }
}

private extension String {
    func leftPadding(to length: Int, with character: Character) -> String {
        guard count < length else {
            return self
        }
        return String(repeating: String(character), count: length - count) + self
    }
}
