import CryptoKit
import Foundation
import Security

/// One public Ed25519 descriptor-signing key embedded in the code-signed
/// installer release.  It is intentionally a public 32-byte raw key, never a
/// private key, seed, credential, or opaque lookup reference.
public struct SealedInstallerReleaseTrustEd25519PublicKey: Equatable, Sendable {
    public let keyID: String
    public let publicKeyBase64: String

    public init(keyID: String, publicKeyBase64: String) throws {
        guard InstallerReleaseTrustValidation.isKeyID(keyID),
              let rawPublicKey = Data(base64Encoded: publicKeyBase64),
              rawPublicKey.count == 32,
              rawPublicKey.base64EncodedString() == publicKeyBase64 else {
            throw InstallerSelfUpdateMetadataError.invalidRecoveryRecord
        }
        self.keyID = keyID
        self.publicKeyBase64 = publicKeyBase64
    }
}

/// A sealed release package supplies this strict, public v2 trust descriptor.
/// It binds the future GitHub Release descriptor convention, expected macOS app
/// identity, and the complete threshold public-key policy to the app bundle.
/// Source builds contain no descriptor and therefore fail closed before the
/// wizard is shown.
///
/// `configurationSHA256` is not an arbitrary self-assertion: it is SHA-256 of
/// a domain-separated, NUL-delimited canonical UTF-8 representation of every
/// accepted semantic field, including every ordered key ID/public-key pair.
/// The app bundle's code signature remains the trust boundary for the resource
/// itself; this digest detects malformed/corrupted descriptor content before a
/// runtime builder receives the public release-trust policy.
public struct SealedInstallerReleaseTrustConfiguration: Equatable, Sendable {
    public static let schemaVersion = 2
    public static let githubReleaseAssetLocator = "github-release-asset-v1"

    public let configurationSHA256: String
    public let repository: String
    public let releaseDescriptorLocator: String
    public let releaseDescriptorAssetName: String
    public let expectedBundleIdentifier: String
    public let expectedTeamIdentifier: String
    public let signatureThreshold: Int
    /// Ordered by strictly ascending `keyID`; no duplicate ID or public key is
    /// admitted, so a threshold cannot be satisfied by duplicate entries.
    public let ed25519PublicKeys: [SealedInstallerReleaseTrustEd25519PublicKey]

    public init(
        configurationSHA256: String,
        repository: String,
        releaseDescriptorLocator: String,
        releaseDescriptorAssetName: String,
        expectedBundleIdentifier: String,
        expectedTeamIdentifier: String,
        signatureThreshold: Int,
        ed25519PublicKeys: [SealedInstallerReleaseTrustEd25519PublicKey]
    ) throws {
        guard InstallerSelfUpdateValidation.isSHA256(configurationSHA256),
              InstallerSelfUpdateValidation.isGitHubRepository(repository),
              releaseDescriptorLocator == Self.githubReleaseAssetLocator,
              InstallerReleaseTrustValidation.isDescriptorAssetName(releaseDescriptorAssetName),
              InstallerSelfUpdateValidation.isBundleIdentifier(expectedBundleIdentifier),
              InstallerSelfUpdateValidation.isTeamIdentifier(expectedTeamIdentifier),
              !ed25519PublicKeys.isEmpty,
              ed25519PublicKeys.count <= InstallerReleaseTrustValidation.maximumPublicKeyCount,
              signatureThreshold > 0,
              signatureThreshold <= ed25519PublicKeys.count,
              InstallerReleaseTrustValidation.hasStrictlyAscendingUniqueKeys(ed25519PublicKeys) else {
            throw InstallerSelfUpdateMetadataError.invalidRecoveryRecord
        }
        guard configurationSHA256 == Self.canonicalSHA256(
            repository: repository,
            releaseDescriptorLocator: releaseDescriptorLocator,
            releaseDescriptorAssetName: releaseDescriptorAssetName,
            expectedBundleIdentifier: expectedBundleIdentifier,
            expectedTeamIdentifier: expectedTeamIdentifier,
            signatureThreshold: signatureThreshold,
            ed25519PublicKeys: ed25519PublicKeys
        ) else {
            throw InstallerSelfUpdateMetadataError.invalidRecoveryRecord
        }
        self.configurationSHA256 = configurationSHA256
        self.repository = repository
        self.releaseDescriptorLocator = releaseDescriptorLocator
        self.releaseDescriptorAssetName = releaseDescriptorAssetName
        self.expectedBundleIdentifier = expectedBundleIdentifier
        self.expectedTeamIdentifier = expectedTeamIdentifier
        self.signatureThreshold = signatureThreshold
        self.ed25519PublicKeys = ed25519PublicKeys
    }

    /// Release packaging uses this deterministic digest when it emits the
    /// sealed descriptor.  The token order is part of the public v2 contract:
    /// key entries are accepted only in strictly ascending key-ID order.
    public static func canonicalSHA256(
        repository: String,
        releaseDescriptorLocator: String,
        releaseDescriptorAssetName: String,
        expectedBundleIdentifier: String,
        expectedTeamIdentifier: String,
        signatureThreshold: Int,
        ed25519PublicKeys: [SealedInstallerReleaseTrustEd25519PublicKey]
    ) -> String {
        var canonicalFields = [
            "forge-platform-installer-release-trust-v2",
            "schema_version=2",
            "repository=\(repository)",
            "release_descriptor_locator=\(releaseDescriptorLocator)",
            "release_descriptor_asset_name=\(releaseDescriptorAssetName)",
            "expected_bundle_identifier=\(expectedBundleIdentifier)",
            "expected_team_identifier=\(expectedTeamIdentifier)",
            "signature_threshold=\(signatureThreshold)",
            "ed25519_public_key_count=\(ed25519PublicKeys.count)",
        ]
        for key in ed25519PublicKeys {
            canonicalFields.append("ed25519_public_key_id=\(key.keyID)")
            canonicalFields.append("ed25519_public_key_base64=\(key.publicKeyBase64)")
        }
        let digest = SHA256.hash(data: Data(canonicalFields.joined(separator: "\u{0}").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Strictly decodes the resource format emitted by the Python bundle
    /// packager.  Duplicate/unknown JSON keys, non-integer numbers, malformed
    /// UTF-8 and non-public fields all fail before a runtime builder sees them.
    static func decodeJSONResource(_ data: Data) throws -> SealedInstallerReleaseTrustConfiguration {
        guard data.count <= InstallerReleaseTrustValidation.maximumResourceBytes else {
            throw InstallerSelfUpdateMetadataError.invalidRecoveryRecord
        }
        var reader = try StrictJSONResourceReader(data: data)
        let root = try reader.parseDocument()
        guard let fields = root.objectValue,
              Set(fields.keys) == Set([
                  "schema_version",
                  "configuration_sha256",
                  "repository",
                  "release_descriptor_locator",
                  "release_descriptor_asset_name",
                  "expected_bundle_identifier",
                  "expected_team_identifier",
                  "signature_threshold",
                  "ed25519_public_keys",
              ]),
              let schemaVersion = fields["schema_version"]?.integerValue,
              schemaVersion == Self.schemaVersion,
              let configurationSHA256 = fields["configuration_sha256"]?.stringValue,
              let repository = fields["repository"]?.stringValue,
              let releaseDescriptorLocator = fields["release_descriptor_locator"]?.stringValue,
              let releaseDescriptorAssetName = fields["release_descriptor_asset_name"]?.stringValue,
              let expectedBundleIdentifier = fields["expected_bundle_identifier"]?.stringValue,
              let expectedTeamIdentifier = fields["expected_team_identifier"]?.stringValue,
              let signatureThreshold = fields["signature_threshold"]?.integerValue,
              let keyValues = fields["ed25519_public_keys"]?.arrayValue else {
            throw InstallerSelfUpdateMetadataError.invalidRecoveryRecord
        }

        let keys = try keyValues.map { keyValue -> SealedInstallerReleaseTrustEd25519PublicKey in
            guard let keyFields = keyValue.objectValue,
                  Set(keyFields.keys) == Set(["key_id", "public_key_base64"]),
                  let keyID = keyFields["key_id"]?.stringValue,
                  let publicKeyBase64 = keyFields["public_key_base64"]?.stringValue else {
                throw InstallerSelfUpdateMetadataError.invalidRecoveryRecord
            }
            return try SealedInstallerReleaseTrustEd25519PublicKey(
                keyID: keyID,
                publicKeyBase64: publicKeyBase64
            )
        }

        return try SealedInstallerReleaseTrustConfiguration(
            configurationSHA256: configurationSHA256,
            repository: repository,
            releaseDescriptorLocator: releaseDescriptorLocator,
            releaseDescriptorAssetName: releaseDescriptorAssetName,
            expectedBundleIdentifier: expectedBundleIdentifier,
            expectedTeamIdentifier: expectedTeamIdentifier,
            signatureThreshold: signatureThreshold,
            ed25519PublicKeys: keys
        )
    }
}

/// Loads the app-code-signed release trust descriptor.  The loader is separate
/// from release-feed verification so a production builder can reject a missing,
/// unsealed, or unsupported descriptor before any wizard UI exists.
public protocol SealedInstallerReleaseTrustConfigurationLoading: Sendable {
    func loadSealedReleaseTrustConfiguration() async -> Result<SealedInstallerReleaseTrustConfiguration, InstallerSelfUpdateFailure>
}

/// Validates that the containing application bundle is an intact macOS signed
/// code object before a descriptor inside it is accepted.  The descriptor
/// itself carries the expected app identity and public release-trust policy;
/// this boundary prevents an altered resource from selecting another policy.
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

/// Bundle-backed loader used by the released app.  Only explicit, public v2
/// metadata is accepted: repository, descriptor convention, expected app/team
/// identity and threshold Ed25519 public keys.  The configured app artifact
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
            let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey])
            guard let fileSize = resourceValues.fileSize,
                  fileSize <= InstallerReleaseTrustValidation.maximumResourceBytes else {
                return .failure(InstallerSelfUpdateFailure(.sealedReleaseTrustConfigurationAbsent))
            }
            let data = try Data(contentsOf: url)
            return .success(try SealedInstallerReleaseTrustConfiguration.decodeJSONResource(data))
        } catch {
            return .failure(InstallerSelfUpdateFailure(.sealedReleaseTrustConfigurationAbsent))
        }
    }
}

private enum InstallerReleaseTrustValidation {
    static let maximumPublicKeyCount = 16
    static let maximumResourceBytes = 32 * 1024

    static func isKeyID(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 128,
              let first = value.unicodeScalars.first,
              isLowercaseLetterOrDigit(first) else {
            return false
        }
        return value.unicodeScalars.allSatisfy { scalar in
            isMetadataScalar(scalar)
        }
    }

    static func isDescriptorAssetName(_ value: String) -> Bool {
        guard value.hasSuffix(".json"), value.count > ".json".count, value.count <= 128,
              !value.contains("/"), !value.contains("\\") else {
            return false
        }
        return value.unicodeScalars.allSatisfy { scalar in
            isMetadataScalar(scalar)
        }
    }

    static func hasStrictlyAscendingUniqueKeys(
        _ keys: [SealedInstallerReleaseTrustEd25519PublicKey]
    ) -> Bool {
        guard Set(keys.map(\.keyID)).count == keys.count,
              Set(keys.map(\.publicKeyBase64)).count == keys.count else {
            return false
        }
        return zip(keys, keys.dropFirst()).allSatisfy { current, next in
            current.keyID < next.keyID
        }
    }

    private static func isMetadataScalar(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 48 && scalar.value <= 57)
            || (scalar.value >= 65 && scalar.value <= 90)
            || (scalar.value >= 97 && scalar.value <= 122)
            || scalar.value == 45
            || scalar.value == 46
            || scalar.value == 95
    }

    private static func isLowercaseLetterOrDigit(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 48 && scalar.value <= 57)
            || (scalar.value >= 97 && scalar.value <= 122)
    }
}

private indirect enum StrictJSONResourceValue {
    case object([String: StrictJSONResourceValue])
    case array([StrictJSONResourceValue])
    case string(String)
    case integer(Int)
    case boolean(Bool)
    case null

    var objectValue: [String: StrictJSONResourceValue]? {
        guard case .object(let value) = self else {
            return nil
        }
        return value
    }

    var arrayValue: [StrictJSONResourceValue]? {
        guard case .array(let value) = self else {
            return nil
        }
        return value
    }

    var stringValue: String? {
        guard case .string(let value) = self else {
            return nil
        }
        return value
    }

    var integerValue: Int? {
        guard case .integer(let value) = self else {
            return nil
        }
        return value
    }
}

private enum StrictJSONResourceError: Error {
    case invalid
}

/// Small strict JSON reader for the sealed trust resource. Foundation's
/// general JSON decoding intentionally accepts duplicate object keys, which is
/// unsuitable for a code-signed trust-policy input. This reader rejects them
/// at every object depth before semantic validation occurs.
private struct StrictJSONResourceReader {
    private let scalars: [Unicode.Scalar]
    private var position = 0

    init(data: Data) throws {
        guard let source = String(data: data, encoding: .utf8) else {
            throw StrictJSONResourceError.invalid
        }
        scalars = Array(source.unicodeScalars)
    }

    mutating func parseDocument() throws -> StrictJSONResourceValue {
        skipWhitespace()
        let value = try parseValue()
        skipWhitespace()
        guard current == nil else {
            throw StrictJSONResourceError.invalid
        }
        return value
    }

    private var current: Unicode.Scalar? {
        guard position < scalars.count else {
            return nil
        }
        return scalars[position]
    }

    private mutating func parseValue() throws -> StrictJSONResourceValue {
        skipWhitespace()
        guard let scalar = current else {
            throw StrictJSONResourceError.invalid
        }
        switch scalar.value {
        case 34:
            return .string(try parseString())
        case 123:
            return try parseObject()
        case 91:
            return try parseArray()
        case 116:
            try consumeLiteral("true")
            return .boolean(true)
        case 102:
            try consumeLiteral("false")
            return .boolean(false)
        case 110:
            try consumeLiteral("null")
            return .null
        case 45, 48...57:
            return .integer(try parseInteger())
        default:
            throw StrictJSONResourceError.invalid
        }
    }

    private mutating func parseObject() throws -> StrictJSONResourceValue {
        try consume(123)
        skipWhitespace()
        if current?.value == 125 {
            position += 1
            return .object([:])
        }

        var members: [String: StrictJSONResourceValue] = [:]
        while true {
            skipWhitespace()
            guard current?.value == 34 else {
                throw StrictJSONResourceError.invalid
            }
            let key = try parseString()
            guard members[key] == nil else {
                throw StrictJSONResourceError.invalid
            }
            skipWhitespace()
            try consume(58)
            let value = try parseValue()
            members[key] = value
            skipWhitespace()
            guard let delimiter = current else {
                throw StrictJSONResourceError.invalid
            }
            if delimiter.value == 125 {
                position += 1
                return .object(members)
            }
            try consume(44)
        }
    }

    private mutating func parseArray() throws -> StrictJSONResourceValue {
        try consume(91)
        skipWhitespace()
        if current?.value == 93 {
            position += 1
            return .array([])
        }

        var members: [StrictJSONResourceValue] = []
        while true {
            members.append(try parseValue())
            skipWhitespace()
            guard let delimiter = current else {
                throw StrictJSONResourceError.invalid
            }
            if delimiter.value == 93 {
                position += 1
                return .array(members)
            }
            try consume(44)
        }
    }

    private mutating func parseString() throws -> String {
        try consume(34)
        var value = String.UnicodeScalarView()
        while let scalar = current {
            position += 1
            switch scalar.value {
            case 34:
                return String(value)
            case 92:
                for escaped in try parseEscapedScalars() {
                    value.append(escaped)
                }
            case 0...31:
                throw StrictJSONResourceError.invalid
            default:
                value.append(scalar)
            }
        }
        throw StrictJSONResourceError.invalid
    }

    private mutating func parseEscapedScalars() throws -> [Unicode.Scalar] {
        guard let escaped = current else {
            throw StrictJSONResourceError.invalid
        }
        position += 1
        switch escaped.value {
        case 34, 92, 47:
            return [escaped]
        case 98:
            return [Unicode.Scalar(8)!]
        case 102:
            return [Unicode.Scalar(12)!]
        case 110:
            return [Unicode.Scalar(10)!]
        case 114:
            return [Unicode.Scalar(13)!]
        case 116:
            return [Unicode.Scalar(9)!]
        case 117:
            let highOrScalar = try parseHexadecimalQuad()
            if (0xD800...0xDBFF).contains(highOrScalar) {
                try consume(92)
                try consume(117)
                let low = try parseHexadecimalQuad()
                guard (0xDC00...0xDFFF).contains(low),
                      let scalar = Unicode.Scalar(0x10000 + ((highOrScalar - 0xD800) << 10) + (low - 0xDC00)) else {
                    throw StrictJSONResourceError.invalid
                }
                return [scalar]
            }
            guard !(0xDC00...0xDFFF).contains(highOrScalar),
                  let scalar = Unicode.Scalar(highOrScalar) else {
                throw StrictJSONResourceError.invalid
            }
            return [scalar]
        default:
            throw StrictJSONResourceError.invalid
        }
    }

    private mutating func parseHexadecimalQuad() throws -> UInt32 {
        var result: UInt32 = 0
        for _ in 0..<4 {
            guard let scalar = current else {
                throw StrictJSONResourceError.invalid
            }
            position += 1
            let digit: UInt32
            switch scalar.value {
            case 48...57:
                digit = scalar.value - 48
            case 65...70:
                digit = scalar.value - 65 + 10
            case 97...102:
                digit = scalar.value - 97 + 10
            default:
                throw StrictJSONResourceError.invalid
            }
            result = result * 16 + digit
        }
        return result
    }

    private mutating func parseInteger() throws -> Int {
        var literal = ""
        if current?.value == 45 {
            literal.append("-")
            position += 1
        }
        guard let first = current else {
            throw StrictJSONResourceError.invalid
        }
        if first.value == 48 {
            literal.append("0")
            position += 1
            guard current?.value != 48 else {
                throw StrictJSONResourceError.invalid
            }
        } else {
            guard (49...57).contains(first.value) else {
                throw StrictJSONResourceError.invalid
            }
            while let scalar = current, (48...57).contains(scalar.value) {
                literal.unicodeScalars.append(scalar)
                position += 1
            }
        }
        guard current?.value != 46, current?.value != 69, current?.value != 101,
              let integer = Int(literal) else {
            throw StrictJSONResourceError.invalid
        }
        return integer
    }

    private mutating func consumeLiteral(_ expected: String) throws {
        for scalar in expected.unicodeScalars {
            try consume(scalar.value)
        }
    }

    private mutating func consume(_ expected: UInt32) throws {
        guard current?.value == expected else {
            throw StrictJSONResourceError.invalid
        }
        position += 1
    }

    private mutating func skipWhitespace() {
        while let scalar = current, scalar.value == 32 || scalar.value == 9 || scalar.value == 10 || scalar.value == 13 {
            position += 1
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
