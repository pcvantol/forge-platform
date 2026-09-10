import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class MacOSStagedInstallerArchiveDigestVerifierTests: XCTestCase {
    func testHashesTheExactPrivateArchiveBoundToTheSignedRelease() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("verified-installer-archive".utf8)
        let release = try releaseRecord(archiveSHA256: sha256(bytes))
        let staging = try staging(root: root, release: release, bytes: bytes)
        let staged = try requireSuccess(await staging.stageInstallerUpdate(for: release))
        let verifier = try MacOSStagedInstallerArchiveDigestVerifier(
            archiveResolver: staging,
            maximumArchiveBytes: 1024
        )

        let result = await verifier.verifyStagedInstallerArchiveSHA256(staged, for: release)

        XCTAssertNil(failureCode(result))
    }

    func testRejectsDigestMismatchWithoutTreatingTheArchiveAsVerified() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("different-installer-archive".utf8)
        let release = try releaseRecord(archiveSHA256: String(repeating: "a", count: 64))
        let staging = try staging(root: root, release: release, bytes: bytes)
        let staged = try requireSuccess(await staging.stageInstallerUpdate(for: release))
        let verifier = try MacOSStagedInstallerArchiveDigestVerifier(
            archiveResolver: staging,
            maximumArchiveBytes: 1024
        )

        let result = await verifier.verifyStagedInstallerArchiveSHA256(staged, for: release)

        XCTAssertEqual(failureCode(result), .sha256VerificationFailed)
    }

    func testRejectsAChangedArchiveAfterThePrivateResolverReadback() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("original-installer-archive".utf8)
        let release = try releaseRecord(archiveSHA256: sha256(bytes))
        let staging = try staging(root: root, release: release, bytes: bytes)
        let staged = try requireSuccess(await staging.stageInstallerUpdate(for: release))
        let resolver = ArchiveMutatingResolver(staging: staging) { archiveURL in
            try FileManager.default.removeItem(at: archiveURL)
            try Data("replaced-installer-archive".utf8).write(to: archiveURL, options: .atomic)
            try setMode(archiveURL, to: mode_t(0o600))
        }
        let verifier = try MacOSStagedInstallerArchiveDigestVerifier(
            archiveResolver: resolver,
            maximumArchiveBytes: 1024
        )

        let result = await verifier.verifyStagedInstallerArchiveSHA256(staged, for: release)

        XCTAssertEqual(failureCode(result), .sha256VerificationFailed)
        let identity = await staging.inspectStagedInstallerAssetIdentity(staged)
        XCTAssertNotEqual(try requireSuccess(identity), staged.fileIdentity)
    }

    func testRejectsAResolverResultWhoseFinalFileIsPermissive() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("mode-sensitive-installer-archive".utf8)
        let release = try releaseRecord(archiveSHA256: sha256(bytes))
        let staging = try staging(root: root, release: release, bytes: bytes)
        let staged = try requireSuccess(await staging.stageInstallerUpdate(for: release))
        let resolver = ArchiveMutatingResolver(staging: staging) { archiveURL in
            try setMode(archiveURL, to: mode_t(0o644))
        }
        let verifier = try MacOSStagedInstallerArchiveDigestVerifier(
            archiveResolver: resolver,
            maximumArchiveBytes: 1024
        )

        let result = await verifier.verifyStagedInstallerArchiveSHA256(staged, for: release)

        XCTAssertEqual(failureCode(result), .sha256VerificationFailed)
    }

    func testRejectsIncorrectAssetNameOrByteBoundBeforeResolving() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("bounded-installer-archive".utf8)
        let release = try releaseRecord(archiveSHA256: sha256(bytes))
        let staging = try staging(root: root, release: release, bytes: bytes)
        let staged = try requireSuccess(await staging.stageInstallerUpdate(for: release))
        let verifier = try MacOSStagedInstallerArchiveDigestVerifier(
            archiveResolver: staging,
            maximumArchiveBytes: bytes.count - 1
        )
        let forged = try StagedInstallerAsset(
            releaseAssetName: "OtherInstaller.app.zip",
            opaqueReference: staged.opaqueReference,
            fileIdentity: staged.fileIdentity
        )

        let tooLargeResult = await verifier.verifyStagedInstallerArchiveSHA256(staged, for: release)
        let wrongNameResult = await verifier.verifyStagedInstallerArchiveSHA256(forged, for: release)

        XCTAssertEqual(failureCode(tooLargeResult), .sha256VerificationFailed)
        XCTAssertEqual(failureCode(wrongNameResult), .sha256VerificationFailed)
    }

    private func staging(
        root: URL,
        release: VerifiedInstallerReleaseRecord,
        bytes: Data
    ) throws -> MacOSInstallerArchiveStaging {
        try MacOSInstallerArchiveStaging(
            stateRoot: root,
            downloader: ArchiveDownloader(
                readback: GitHubInstallerReleaseArchiveReadback(
                    githubAsset: release.githubAsset,
                    bytes: bytes
                )
            ),
            maximumArchiveBytes: 1024
        )
    }

    private func releaseRecord(archiveSHA256: String) throws -> VerifiedInstallerReleaseRecord {
        let asset = try GitHubInstallerReleaseAsset(
            repository: "pcvantol/forge-platform",
            tag: "installer-v1.2.3",
            assetName: "ForgePlatformInstaller.app.zip"
        )
        return try VerifiedInstallerReleaseRecord(
            release: VerifiedInstallerRelease(
                version: try InstallerVersion("1.2.3"),
                releasePage: asset.releasePage,
                assetName: asset.assetName,
                sha256: archiveSHA256,
                signingKeyID: "forge-platform-installer-release-v1"
            ),
            sequence: 12,
            channel: .stable,
            sourceRevision: String(repeating: "a", count: 40),
            expectedBundleIdentifier: "com.example.forge-platform-installer",
            expectedTeamIdentifier: "ABCDE12345",
            expectedCodeDirectorySHA256: String(repeating: "b", count: 64),
            policyRevision: "release/v1",
            capabilities: ["composition/v1", "provider-gate/v1"],
            provenanceSHA256: String(repeating: "c", count: 64),
            expectedReleaseTrustConfigurationSHA256: String(repeating: "d", count: 64),
            compositionCatalogFeed: try VerifiedCompositionCatalogFeedLocator(
                url: "https://catalog.example.invalid/forge-platform/stable.json"
            ),
            notarizationReference: "receipt:notarization-ticket-v1",
            githubAsset: asset
        )
    }
}

private actor ArchiveDownloader: GitHubInstallerReleaseArchiveDownloading {
    private let readback: GitHubInstallerReleaseArchiveReadback

    init(readback: GitHubInstallerReleaseArchiveReadback) {
        self.readback = readback
    }

    func downloadInstallerReleaseArchive(
        for githubAsset: GitHubInstallerReleaseAsset,
        maximumBytes: Int
    ) async -> Result<GitHubInstallerReleaseArchiveReadback, InstallerSelfUpdateFailure> {
        .success(readback)
    }
}

private struct ArchiveMutatingResolver: MacOSInstallerArchiveStagingResolving {
    let staging: MacOSInstallerArchiveStaging
    let mutation: @Sendable (URL) throws -> Void

    func resolveStagedInstallerArchive(
        _ stagedAsset: StagedInstallerAsset
    ) async -> Result<URL, InstallerSelfUpdateFailure> {
        switch await staging.resolveStagedInstallerArchive(stagedAsset) {
        case .success(let url):
            do {
                try mutation(url)
                return .success(url)
            } catch {
                return .failure(InstallerSelfUpdateFailure(.stagedAssetIdentityChanged))
            }
        case .failure(let failure):
            return .failure(failure)
        }
    }
}

private enum ArchiveDigestVerifierTestError: Error {
    case unexpectedResult
    case filesystem
}

private func requireSuccess<Value>(
    _ result: Result<Value, InstallerSelfUpdateFailure>,
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> Value {
    switch result {
    case .success(let value):
        return value
    case .failure(let failure):
        XCTFail("Expected success, got \(failure.code)", file: file, line: line)
        throw ArchiveDigestVerifierTestError.unexpectedResult
    }
}

private func failureCode<Value>(
    _ result: Result<Value, InstallerSelfUpdateFailure>
) -> InstallerSelfUpdateFailureCode? {
    switch result {
    case .success:
        return nil
    case .failure(let failure):
        return failure.code
    }
}

private func temporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("forge-platform-installer-digest-tests-\(UUID().uuidString.lowercased())", isDirectory: true)
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: NSNumber(value: 0o700)]
    )
    try setMode(root, to: mode_t(0o700))
    return root
}

private func setMode(_ url: URL, to mode: mode_t) throws {
    let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
        guard let path else { return -1 }
        return Darwin.chmod(path, mode)
    }
    guard result == 0 else {
        throw ArchiveDigestVerifierTestError.filesystem
    }
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
