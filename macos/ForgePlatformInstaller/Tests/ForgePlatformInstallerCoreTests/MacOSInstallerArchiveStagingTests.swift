import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class MacOSInstallerArchiveStagingTests: XCTestCase {
    func testStagesOnlyExactGitHubAssetWithPrivateOpaqueReference() async throws {
        let stateRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: stateRoot) }
        let release = try makeReleaseRecord()
        let bytes = Data([0x50, 0x4b, 0x03, 0x04, 0x01, 0x02, 0x03])
        let downloader = ArchiveDownloaderSpy(
            response: .success(
                GitHubInstallerReleaseArchiveReadback(
                    githubAsset: release.githubAsset,
                    bytes: bytes
                )
            )
        )
        let staging = try MacOSInstallerArchiveStaging(
            stateRoot: stateRoot,
            downloader: downloader,
            maximumArchiveBytes: 128
        )

        let result = await staging.stageInstallerUpdate(for: release)
        let staged = try requireSuccess(result)
        let requests = await downloader.requests()

        XCTAssertEqual(requests, [ArchiveDownloadRequest(asset: release.githubAsset, maximumBytes: 128)])
        XCTAssertEqual(staged.releaseAssetName, release.githubAsset.assetName)
        XCTAssertFalse(staged.opaqueReference.contains(stateRoot.path))
        XCTAssertTrue(staged.opaqueReference.hasPrefix("forge-platform-installer-archive-v1:"))
        XCTAssertEqual(staged.fileIdentity.byteCount, UInt64(bytes.count))

        let inspected = try requireSuccess(await staging.inspectStagedInstallerAssetIdentity(staged))
        XCTAssertEqual(inspected, staged.fileIdentity)

        let archiveURL = try requireSuccess(await staging.resolveStagedInstallerArchive(staged))
        XCTAssertEqual(archiveURL.lastPathComponent, "installer-update.zip")
        XCTAssertEqual(try Data(contentsOf: archiveURL), bytes)
        XCTAssertEqual(try fileMode(at: archiveURL), mode_t(0o600))

        let discardResult = await staging.discardStagedInstallerUpdate(staged)
        XCTAssertNil(failureCode(discardResult))
        let postDiscardResolution = await staging.resolveStagedInstallerArchive(staged)
        XCTAssertEqual(
            failureCode(postDiscardResolution),
            .stagedAssetIdentityChanged
        )
    }

    func testRejectsArchiveReadbackForDifferentGitHubReleaseAssetBeforeWriting() async throws {
        let stateRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: stateRoot) }
        let release = try makeReleaseRecord()
        let differentAsset = try GitHubInstallerReleaseAsset(
            repository: release.githubAsset.repository,
            tag: "installer-v9.9.9",
            assetName: release.githubAsset.assetName
        )
        let downloader = ArchiveDownloaderSpy(
            response: .success(
                GitHubInstallerReleaseArchiveReadback(
                    githubAsset: differentAsset,
                    bytes: Data([0x50, 0x4b])
                )
            )
        )
        let staging = try MacOSInstallerArchiveStaging(
            stateRoot: stateRoot,
            downloader: downloader,
            maximumArchiveBytes: 128
        )

        let stageResult = await staging.stageInstallerUpdate(for: release)
        XCTAssertEqual(failureCode(stageResult), .stagingFailed)
        let contents = try FileManager.default.contentsOfDirectory(
            at: stateRoot.appendingPathComponent(MacOSInstallerArchiveStaging.stagingDirectoryName),
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(contents.isEmpty)
    }

    func testRejectsOversizedArchiveBeforeItReachesPrivateState() async throws {
        let stateRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: stateRoot) }
        let release = try makeReleaseRecord()
        let downloader = ArchiveDownloaderSpy(
            response: .success(
                GitHubInstallerReleaseArchiveReadback(
                    githubAsset: release.githubAsset,
                    bytes: Data(repeating: 0x5a, count: 17)
                )
            )
        )
        let staging = try MacOSInstallerArchiveStaging(
            stateRoot: stateRoot,
            downloader: downloader,
            maximumArchiveBytes: 16
        )

        let stageResult = await staging.stageInstallerUpdate(for: release)
        XCTAssertEqual(failureCode(stageResult), .stagingFailed)
        let contents = try FileManager.default.contentsOfDirectory(
            at: stateRoot.appendingPathComponent(MacOSInstallerArchiveStaging.stagingDirectoryName),
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(contents.isEmpty)
    }

    func testOpaqueReferenceIsBoundToTheSignedReleaseAssetName() async throws {
        let stateRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: stateRoot) }
        let release = try makeReleaseRecord()
        let staging = try makeStaging(
            stateRoot: stateRoot,
            release: release,
            bytes: Data([0x50, 0x4b, 0x03])
        )
        let staged = try requireSuccess(await staging.stageInstallerUpdate(for: release))
        let fields = staged.opaqueReference.split(separator: ":", omittingEmptySubsequences: false)
        XCTAssertEqual(fields.count, 3)
        let forged = try StagedInstallerAsset(
            releaseAssetName: staged.releaseAssetName,
            opaqueReference: "\(fields[0]):\(fields[1]):AnotherInstaller.app.zip",
            fileIdentity: staged.fileIdentity
        )

        let forgedResolution = await staging.resolveStagedInstallerArchive(forged)
        XCTAssertEqual(failureCode(forgedResolution), .stagedAssetIdentityChanged)
        let forgedDiscard = await staging.discardStagedInstallerUpdate(forged)
        XCTAssertEqual(failureCode(forgedDiscard), .stagingCleanupFailed)
        _ = try requireSuccess(await staging.resolveStagedInstallerArchive(staged))
    }

    func testRejectsPermissiveAndSymlinkedStateRootsBeforeDownloading() async throws {
        let parent = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let release = try makeReleaseRecord()

        let permissiveRoot = parent.appendingPathComponent("permissive-root", isDirectory: true)
        try makePrivateDirectory(at: permissiveRoot)
        try setMode(at: permissiveRoot, to: mode_t(0o755))
        let permissiveDownloader = ArchiveDownloaderSpy(
            response: .success(
                GitHubInstallerReleaseArchiveReadback(
                    githubAsset: release.githubAsset,
                    bytes: Data([0x50])
                )
            )
        )
        let permissiveStaging = try MacOSInstallerArchiveStaging(
            stateRoot: permissiveRoot,
            downloader: permissiveDownloader,
            maximumArchiveBytes: 128
        )
        let permissiveResult = await permissiveStaging.stageInstallerUpdate(for: release)
        XCTAssertEqual(failureCode(permissiveResult), .stagingFailed)
        let permissiveRequests = await permissiveDownloader.requests()
        XCTAssertTrue(permissiveRequests.isEmpty)

        let targetRoot = parent.appendingPathComponent("real-root", isDirectory: true)
        try makePrivateDirectory(at: targetRoot)
        let symlinkRoot = parent.appendingPathComponent("root-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: symlinkRoot, withDestinationURL: targetRoot)
        let symlinkDownloader = ArchiveDownloaderSpy(
            response: .success(
                GitHubInstallerReleaseArchiveReadback(
                    githubAsset: release.githubAsset,
                    bytes: Data([0x50])
                )
            )
        )
        let symlinkStaging = try MacOSInstallerArchiveStaging(
            stateRoot: symlinkRoot,
            downloader: symlinkDownloader,
            maximumArchiveBytes: 128
        )
        let symlinkResult = await symlinkStaging.stageInstallerUpdate(for: release)
        XCTAssertEqual(failureCode(symlinkResult), .stagingFailed)
        let symlinkRequests = await symlinkDownloader.requests()
        XCTAssertTrue(symlinkRequests.isEmpty)
    }

    func testReplacementChangesIdentityAndCannotBeResolvedForVerification() async throws {
        let stateRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: stateRoot) }
        let release = try makeReleaseRecord()
        let staging = try makeStaging(
            stateRoot: stateRoot,
            release: release,
            bytes: Data([0x50, 0x4b, 0x01, 0x02])
        )
        let staged = try requireSuccess(await staging.stageInstallerUpdate(for: release))
        let archiveURL = try requireSuccess(await staging.resolveStagedInstallerArchive(staged))

        try FileManager.default.removeItem(at: archiveURL)
        try Data([0x50, 0x4b, 0x07, 0x08]).write(to: archiveURL, options: .atomic)
        try setMode(at: archiveURL, to: mode_t(0o600))

        let observed = try requireSuccess(await staging.inspectStagedInstallerAssetIdentity(staged))
        XCTAssertNotEqual(observed, staged.fileIdentity)
        let resolution = await staging.resolveStagedInstallerArchive(staged)
        XCTAssertEqual(failureCode(resolution), .stagedAssetIdentityChanged)
        let discardResult = await staging.discardStagedInstallerUpdate(staged)
        XCTAssertNil(failureCode(discardResult))
    }

    func testSymlinkedOrPermissiveArchiveFailsClosedWithoutFollowingTarget() async throws {
        let stateRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: stateRoot) }
        let release = try makeReleaseRecord()

        let permissiveStaging = try makeStaging(
            stateRoot: stateRoot,
            release: release,
            bytes: Data([0x50, 0x4b, 0x01])
        )
        let permissiveAsset = try requireSuccess(await permissiveStaging.stageInstallerUpdate(for: release))
        let permissiveURL = try requireSuccess(await permissiveStaging.resolveStagedInstallerArchive(permissiveAsset))
        try setMode(at: permissiveURL, to: mode_t(0o644))
        let permissiveIdentity = await permissiveStaging.inspectStagedInstallerAssetIdentity(permissiveAsset)
        XCTAssertEqual(failureCode(permissiveIdentity), .stagedAssetIdentityChanged)
        let permissiveResolution = await permissiveStaging.resolveStagedInstallerArchive(permissiveAsset)
        XCTAssertEqual(failureCode(permissiveResolution), .stagedAssetIdentityChanged)
        let permissiveDiscard = await permissiveStaging.discardStagedInstallerUpdate(permissiveAsset)
        XCTAssertEqual(failureCode(permissiveDiscard), .stagingCleanupFailed)

        let secondRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: secondRoot) }
        let symlinkStaging = try makeStaging(
            stateRoot: secondRoot,
            release: release,
            bytes: Data([0x50, 0x4b, 0x02])
        )
        let symlinkAsset = try requireSuccess(await symlinkStaging.stageInstallerUpdate(for: release))
        let archiveURL = try requireSuccess(await symlinkStaging.resolveStagedInstallerArchive(symlinkAsset))
        let sentinelURL = secondRoot.appendingPathComponent("sentinel.txt")
        let sentinelBytes = Data("do-not-follow".utf8)
        try sentinelBytes.write(to: sentinelURL)
        try setMode(at: sentinelURL, to: mode_t(0o600))
        try FileManager.default.removeItem(at: archiveURL)
        try FileManager.default.createSymbolicLink(at: archiveURL, withDestinationURL: sentinelURL)

        let symlinkIdentity = await symlinkStaging.inspectStagedInstallerAssetIdentity(symlinkAsset)
        XCTAssertEqual(failureCode(symlinkIdentity), .stagedAssetIdentityChanged)
        let symlinkResolution = await symlinkStaging.resolveStagedInstallerArchive(symlinkAsset)
        XCTAssertEqual(failureCode(symlinkResolution), .stagedAssetIdentityChanged)
        let symlinkDiscard = await symlinkStaging.discardStagedInstallerUpdate(symlinkAsset)
        XCTAssertEqual(failureCode(symlinkDiscard), .stagingCleanupFailed)
        XCTAssertEqual(try Data(contentsOf: sentinelURL), sentinelBytes)
    }

    private func makeStaging(
        stateRoot: URL,
        release: VerifiedInstallerReleaseRecord,
        bytes: Data
    ) throws -> MacOSInstallerArchiveStaging {
        try MacOSInstallerArchiveStaging(
            stateRoot: stateRoot,
            downloader: ArchiveDownloaderSpy(
                response: .success(
                    GitHubInstallerReleaseArchiveReadback(
                        githubAsset: release.githubAsset,
                        bytes: bytes
                    )
                )
            ),
            maximumArchiveBytes: 128
        )
    }

    private func makeReleaseRecord() throws -> VerifiedInstallerReleaseRecord {
        let asset = try GitHubInstallerReleaseAsset(
            repository: "pcvantol/forge-platform",
            tag: "installer-v1.2.3",
            assetName: "ForgePlatformInstaller.app.zip"
        )
        let release = VerifiedInstallerRelease(
            version: try InstallerVersion("1.2.3"),
            releasePage: asset.releasePage,
            assetName: asset.assetName,
            sha256: String(repeating: "f", count: 64),
            signingKeyID: "forge-platform-installer-release-v1"
        )
        return try VerifiedInstallerReleaseRecord(
            release: release,
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

private struct ArchiveDownloadRequest: Equatable, Sendable {
    let asset: GitHubInstallerReleaseAsset
    let maximumBytes: Int
}

private actor ArchiveDownloaderSpy: GitHubInstallerReleaseArchiveDownloading {
    private let response: Result<GitHubInstallerReleaseArchiveReadback, InstallerSelfUpdateFailure>
    private var receivedRequests: [ArchiveDownloadRequest] = []

    init(response: Result<GitHubInstallerReleaseArchiveReadback, InstallerSelfUpdateFailure>) {
        self.response = response
    }

    func downloadInstallerReleaseArchive(
        for githubAsset: GitHubInstallerReleaseAsset,
        maximumBytes: Int
    ) async -> Result<GitHubInstallerReleaseArchiveReadback, InstallerSelfUpdateFailure> {
        receivedRequests.append(
            ArchiveDownloadRequest(asset: githubAsset, maximumBytes: maximumBytes)
        )
        return response
    }

    func requests() -> [ArchiveDownloadRequest] {
        receivedRequests
    }
}

private enum ArchiveStagingTestError: Error {
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
        throw ArchiveStagingTestError.unexpectedResult
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

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("forge-platform-installer-archive-tests-\(UUID().uuidString.lowercased())", isDirectory: true)
    try makePrivateDirectory(at: url)
    return url
}

private func makePrivateDirectory(at url: URL) throws {
    try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: NSNumber(value: 0o700)]
    )
    try setMode(at: url, to: mode_t(0o700))
}

private func setMode(at url: URL, to mode: mode_t) throws {
    let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
        guard let path else { return -1 }
        return Darwin.chmod(path, mode)
    }
    guard result == 0 else {
        throw ArchiveStagingTestError.filesystem
    }
}

private func fileMode(at url: URL) throws -> mode_t {
    var details = stat()
    let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
        guard let path else { return -1 }
        return Darwin.lstat(path, &details)
    }
    guard result == 0 else {
        throw ArchiveStagingTestError.filesystem
    }
    return details.st_mode & mode_t(0o7777)
}
