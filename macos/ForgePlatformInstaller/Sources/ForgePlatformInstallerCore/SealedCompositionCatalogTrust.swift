import CryptoKit
import Foundation

/// Public, code-signed policy for the separately signed composition catalog.
/// It is intentionally distinct from the installer self-update trust policy:
/// the latter never implicitly authorizes catalog signatures. Source builds
/// contain no resource, so this loader is not assembled into a wizard path.
struct SealedCompositionCatalogTrustConfiguration: Equatable, Sendable {
    static let schemaVersion = 1
    static let maximumResourceBytes = 32 * 1024
    private static let canonicalDomain = "forge-platform-installer-composition-catalog-trust-v1"

    /// Tamper-evident semantic identity of this public resource. It is not an
    /// anti-replay scope: catalog acceptance remains scoped only by the
    /// installer trust digest, channel and exact feed locator.
    let configurationSHA256: String
    let signaturePolicy: CompositionCatalogSignaturePolicy

    init(
        configurationSHA256: String,
        installerReleaseTrustConfigurationSHA256: String,
        signatureThreshold: Int,
        ed25519PublicKeys: [CompositionCatalogTrustEd25519PublicKey]
    ) throws {
        guard InstallerSelfUpdateValidation.isSHA256(configurationSHA256) else {
            throw SealedCompositionCatalogTrustConfigurationError.invalid
        }

        let policy: CompositionCatalogSignaturePolicy
        do {
            policy = try CompositionCatalogSignaturePolicy(
                installerReleaseTrustConfigurationSHA256: installerReleaseTrustConfigurationSHA256,
                signatureThreshold: signatureThreshold,
                ed25519PublicKeys: ed25519PublicKeys
            )
        } catch {
            throw SealedCompositionCatalogTrustConfigurationError.invalid
        }

        guard configurationSHA256 == Self.canonicalSHA256(
            installerReleaseTrustConfigurationSHA256: installerReleaseTrustConfigurationSHA256,
            signatureThreshold: signatureThreshold,
            ed25519PublicKeys: ed25519PublicKeys
        ) else {
            throw SealedCompositionCatalogTrustConfigurationError.invalid
        }
        self.configurationSHA256 = configurationSHA256
        signaturePolicy = policy
    }

    /// This digest uses a domain-separated, NUL-delimited UTF-8 representation
    /// of every semantic field. Ordered key entries are part of the public
    /// contract, so a reordering or duplicate cannot preserve the identity.
    static func canonicalSHA256(
        installerReleaseTrustConfigurationSHA256: String,
        signatureThreshold: Int,
        ed25519PublicKeys: [CompositionCatalogTrustEd25519PublicKey]
    ) -> String {
        var fields = [
            canonicalDomain,
            "schema_version=\(schemaVersion)",
            "installer_release_trust_configuration_sha256=\(installerReleaseTrustConfigurationSHA256)",
            "signature_threshold=\(signatureThreshold)",
            "ed25519_public_key_count=\(ed25519PublicKeys.count)",
        ]
        for key in ed25519PublicKeys {
            fields.append("ed25519_public_key_id=\(key.keyID)")
            fields.append("ed25519_public_key_base64=\(key.publicKeyBase64)")
        }
        return SHA256.hash(data: Data(fields.joined(separator: "\u{0}").utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func decodeJSONResource(_ data: Data) throws -> SealedCompositionCatalogTrustConfiguration {
        guard !data.isEmpty, data.count <= Self.maximumResourceBytes else {
            throw SealedCompositionCatalogTrustConfigurationError.invalid
        }
        var reader = try StrictJSONResourceReader(data: data)
        let root = try reader.parseDocument()
        guard let fields = root.objectValue,
              Set(fields.keys) == Set([
                  "schema_version",
                  "configuration_sha256",
                  "installer_release_trust_configuration_sha256",
                  "signature_threshold",
                  "ed25519_public_keys",
              ]),
              let schemaVersion = fields["schema_version"]?.integerValue,
              schemaVersion == Self.schemaVersion,
              let configurationSHA256 = fields["configuration_sha256"]?.stringValue,
              let installerReleaseTrustConfigurationSHA256 = fields["installer_release_trust_configuration_sha256"]?.stringValue,
              let signatureThreshold = fields["signature_threshold"]?.integerValue,
              let keyValues = fields["ed25519_public_keys"]?.arrayValue else {
            throw SealedCompositionCatalogTrustConfigurationError.invalid
        }

        let keys = try keyValues.map { value -> CompositionCatalogTrustEd25519PublicKey in
            guard let keyFields = value.objectValue,
                  Set(keyFields.keys) == Set(["key_id", "public_key_base64"]),
                  let keyID = keyFields["key_id"]?.stringValue,
                  let publicKeyBase64 = keyFields["public_key_base64"]?.stringValue else {
                throw SealedCompositionCatalogTrustConfigurationError.invalid
            }
            do {
                return try CompositionCatalogTrustEd25519PublicKey(
                    keyID: keyID,
                    publicKeyBase64: publicKeyBase64
                )
            } catch {
                throw SealedCompositionCatalogTrustConfigurationError.invalid
            }
        }

        return try SealedCompositionCatalogTrustConfiguration(
            configurationSHA256: configurationSHA256,
            installerReleaseTrustConfigurationSHA256: installerReleaseTrustConfigurationSHA256,
            signatureThreshold: signatureThreshold,
            ed25519PublicKeys: keys
        )
    }
}

enum SealedCompositionCatalogTrustConfigurationError: Error, Equatable, Sendable {
    case invalid
}

/// The policy loader is intentionally separate from startup/runtime assembly.
/// A later coordinator may consume it only after current-installer enforcement;
/// until then, an absent resource has no fallback key set or wizard behavior.
protocol SealedCompositionCatalogTrustConfigurationLoading: Sendable {
    func loadSealedCompositionCatalogTrustConfiguration() async -> Result<SealedCompositionCatalogTrustConfiguration, SealedCompositionCatalogTrustLoadingFailure>
}

enum SealedCompositionCatalogTrustLoadingFailure: Error, Equatable, Sendable {
    case unavailable
}

/// Reads one named public resource from an intact signed app bundle. The
/// enclosing code object is validated before and after the secure descriptor
/// read; no caller can supply a path, key, endpoint or fallback policy.
struct BundleSealedCompositionCatalogTrustConfigurationLoader: SealedCompositionCatalogTrustConfigurationLoading {
    private let bundle: Bundle
    private let resourceName: String
    private let bundleValidator: any SealedInstallerBundleValidating

    init(
        bundle: Bundle = .main,
        resourceName: String = "ForgePlatformInstallerCompositionCatalogTrust",
        bundleValidator: any SealedInstallerBundleValidating = MacOSSealedInstallerBundleValidator()
    ) {
        self.bundle = bundle
        self.resourceName = resourceName
        self.bundleValidator = bundleValidator
    }

    func loadSealedCompositionCatalogTrustConfiguration() async -> Result<SealedCompositionCatalogTrustConfiguration, SealedCompositionCatalogTrustLoadingFailure> {
        do {
            guard case .success = bundleValidator.validateSealedInstallerBundle(at: bundle.bundleURL),
                  let url = bundle.url(forResource: resourceName, withExtension: "json") else {
                return .failure(.unavailable)
            }
            let data = try SealedInstallerResourceFileReader.read(
                at: url,
                maximumBytes: SealedCompositionCatalogTrustConfiguration.maximumResourceBytes
            )
            guard case .success = bundleValidator.validateSealedInstallerBundle(at: bundle.bundleURL) else {
                return .failure(.unavailable)
            }
            return .success(try SealedCompositionCatalogTrustConfiguration.decodeJSONResource(data))
        } catch {
            return .failure(.unavailable)
        }
    }
}
