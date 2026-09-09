import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class MacOSTrustedInstallerRuntimeBuilderTests: XCTestCase {
    func testAssemblesOnlyExistingSelfUpdateAdaptersFromOnePrivateRoot() async throws {
        let root = try makeSecureTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let builder = try MacOSTrustedInstallerRuntimeBuilder(stateRoot: root)
        let configuration = try makeConfiguration()
        let provenance = try makeProvenance(configuration: configuration)

        let result = await builder.buildTrustedInstallerRuntime(
            sealedTrustConfiguration: configuration,
            sealedReleaseProvenance: provenance
        )

        guard case .success(let runtime) = result else {
            return XCTFail("A valid sealed configuration and private root should assemble the existing self-update runtime")
        }
        XCTAssertTrue(runtime is VerifiedInstallerSelfUpdateCoordinator)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testMismatchedSealedResourcesNeverAssembleARuntime() async throws {
        let root = try makeSecureTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let builder = try MacOSTrustedInstallerRuntimeBuilder(stateRoot: root)
        let configuration = try makeConfiguration()
        let mismatchedProvenance = try makeProvenance(
            releaseTrustConfigurationSHA256: String(repeating: "f", count: 64)
        )

        let result = await builder.buildTrustedInstallerRuntime(
            sealedTrustConfiguration: configuration,
            sealedReleaseProvenance: mismatchedProvenance
        )

        guard case .failure(let failure) = result else {
            return XCTFail("Mismatched V1/V2 sealed identities must fail before runtime assembly")
        }
        XCTAssertEqual(failure, InstallerSelfUpdateFailure(.sealedReleaseProvenanceMismatch))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testRejectsAbsentPermissiveRegularAndFinalSymlinkStateRootsWithoutProvisioning() throws {
        let container = try makeSecureTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }

        let absent = container.appendingPathComponent("absent-state", isDirectory: true)
        assertInvalidStateRoot(absent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: absent.path))

        let permissive = container.appendingPathComponent("permissive-state", isDirectory: true)
        try makeDirectory(permissive, mode: 0o755)
        assertInvalidStateRoot(permissive)

        let regularFile = container.appendingPathComponent("not-a-directory", isDirectory: false)
        try Data("not a state root".utf8).write(to: regularFile, options: .atomic)
        try setMode(regularFile, mode: 0o600)
        assertInvalidStateRoot(regularFile)

        let target = container.appendingPathComponent("private-target", isDirectory: true)
        try makeDirectory(target, mode: 0o700)
        let finalSymlink = container.appendingPathComponent("state-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: finalSymlink, withDestinationURL: target)
        assertInvalidStateRoot(finalSymlink)
    }

    func testAcceptsACanonicalPrivateRootBehindAnExistingParentAlias() throws {
        let container = try makeSecureTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let physicalParent = container.appendingPathComponent("physical-parent", isDirectory: true)
        try makeDirectory(physicalParent, mode: 0o700)
        let physicalRoot = physicalParent.appendingPathComponent("installer-state", isDirectory: true)
        try makeDirectory(physicalRoot, mode: 0o700)
        let aliasParent = container.appendingPathComponent("parent-alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: aliasParent, withDestinationURL: physicalParent)

        XCTAssertNoThrow(
            try MacOSTrustedInstallerRuntimeBuilder(
                stateRoot: aliasParent.appendingPathComponent("installer-state", isDirectory: true)
            )
        )
    }

    func testRejectsNonFileStateRoot() {
        XCTAssertThrowsError(
            try MacOSTrustedInstallerRuntimeBuilder(
                stateRoot: URL(string: "https://example.invalid/installer-state")!
            )
        ) { error in
            XCTAssertEqual(
                error as? MacOSTrustedInstallerRuntimeBuilderConfigurationError,
                .invalidInstallerStateRoot
            )
        }
    }

    private func assertInvalidStateRoot(_ root: URL) {
        XCTAssertThrowsError(
            try MacOSTrustedInstallerRuntimeBuilder(stateRoot: root)
        ) { error in
            XCTAssertEqual(
                error as? MacOSTrustedInstallerRuntimeBuilderConfigurationError,
                .invalidInstallerStateRoot
            )
        }
    }

    private func makeSecureTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "forge-platform-installer-runtime-builder-tests-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try makeDirectory(directory, mode: 0o700)
        return directory
    }

    private func makeDirectory(_ directory: URL, mode: mode_t) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: mode)]
        )
        try setMode(directory, mode: mode)
    }

    private func setMode(_ url: URL, mode: mode_t) throws {
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.chmod(path, mode)
        }
        guard result == 0 else {
            throw NSError(domain: "MacOSTrustedInstallerRuntimeBuilderTests", code: Int(errno))
        }
    }

    private func makeConfiguration() throws -> SealedInstallerReleaseTrustConfiguration {
        let keys = try [
            SealedInstallerReleaseTrustEd25519PublicKey(
                keyID: "descriptor-key-a",
                publicKeyBase64: Data((0..<32).map(UInt8.init)).base64EncodedString()
            ),
            SealedInstallerReleaseTrustEd25519PublicKey(
                keyID: "descriptor-key-b",
                publicKeyBase64: Data((32..<64).map(UInt8.init)).base64EncodedString()
            ),
        ]
        let repository = "example-owner/example-installer"
        let releaseDescriptorAssetName = "ForgePlatformInstallerReleaseDescriptor.json"
        let expectedBundleIdentifier = "com.example.forge-platform-installer"
        let expectedTeamIdentifier = "AB12CD34EF"
        let signatureThreshold = 2
        return try SealedInstallerReleaseTrustConfiguration(
            configurationSHA256: SealedInstallerReleaseTrustConfiguration.canonicalSHA256(
                repository: repository,
                releaseDescriptorLocator: SealedInstallerReleaseTrustConfiguration.githubReleaseAssetLocator,
                releaseDescriptorAssetName: releaseDescriptorAssetName,
                expectedBundleIdentifier: expectedBundleIdentifier,
                expectedTeamIdentifier: expectedTeamIdentifier,
                signatureThreshold: signatureThreshold,
                ed25519PublicKeys: keys
            ),
            repository: repository,
            releaseDescriptorLocator: SealedInstallerReleaseTrustConfiguration.githubReleaseAssetLocator,
            releaseDescriptorAssetName: releaseDescriptorAssetName,
            expectedBundleIdentifier: expectedBundleIdentifier,
            expectedTeamIdentifier: expectedTeamIdentifier,
            signatureThreshold: signatureThreshold,
            ed25519PublicKeys: keys
        )
    }

    private func makeProvenance(
        configuration: SealedInstallerReleaseTrustConfiguration? = nil,
        releaseTrustConfigurationSHA256: String? = nil
    ) throws -> SealedInstallerReleaseProvenance {
        let installerVersion = try InstallerVersion("1.0.0")
        let trustConfigurationSHA256 = releaseTrustConfigurationSHA256
            ?? configuration?.configurationSHA256
            ?? String(repeating: "e", count: 64)
        let sourceRevision = String(repeating: "a", count: 40)
        let policyRevision = "forge-platform-installer-release-v1"
        let capabilities = ["composition/v1", "provider-gate/v1"]
        return try SealedInstallerReleaseProvenance(
            provenanceSHA256: SealedInstallerReleaseProvenance.canonicalSHA256(
                installerVersion: installerVersion,
                channel: .stable,
                releaseSequence: 1,
                sourceRevision: sourceRevision,
                policyRevision: policyRevision,
                capabilities: capabilities,
                releaseTrustConfigurationSHA256: trustConfigurationSHA256
            ),
            installerVersion: installerVersion,
            channel: .stable,
            releaseSequence: 1,
            sourceRevision: sourceRevision,
            policyRevision: policyRevision,
            capabilities: capabilities,
            releaseTrustConfigurationSHA256: trustConfigurationSHA256
        )
    }
}
