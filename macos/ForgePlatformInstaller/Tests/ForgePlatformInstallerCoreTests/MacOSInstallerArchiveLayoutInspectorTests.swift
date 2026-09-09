import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class MacOSInstallerArchiveLayoutInspectorTests: XCTestCase {
    func testAdmitsOneBoundedAppBundleLayoutThroughOpaqueStagingResolver() async throws {
        let archive = try makeArchiveFixture(entries: validAppBundleEntries())
        defer { try? FileManager.default.removeItem(at: archive.directory) }
        let stagedAsset = try makeStagedAsset(byteCount: archive.byteCount)
        let resolver = ArchiveLayoutResolver(
            responses: [.success(archive.url), .success(archive.url)]
        )
        let inspector = try makeInspector()

        let result = await inspector.inspectStagedInstallerArchive(
            stagedAsset,
            using: resolver
        )
        let layout = try requireLayoutSuccess(result)
        let resolutionCount = await resolver.resolutionCount()

        XCTAssertEqual(resolutionCount, 2)
        XCTAssertEqual(layout.appBundleRoot, "ForgePlatformInstaller.app")
        XCTAssertEqual(layout.archiveByteCount, archive.byteCount)
        XCTAssertEqual(
            layout.entries.map(\.logicalPath),
            [
                "ForgePlatformInstaller.app",
                "ForgePlatformInstaller.app/Contents",
                "ForgePlatformInstaller.app/Contents/Info.plist",
                "ForgePlatformInstaller.app/Contents/MacOS",
                "ForgePlatformInstaller.app/Contents/MacOS/ForgePlatformInstaller",
                "ForgePlatformInstaller.app/Contents/Resources",
                "ForgePlatformInstaller.app/Contents/Resources/installer-release.json"
            ]
        )
        XCTAssertEqual(
            layout.totalUncompressedByteCount,
            UInt64("<plist/>binary{}".utf8.count)
        )
    }

    func testRejectsZip64EncryptionSymlinkTraversalPermissiveAndAmbiguousLayouts() async throws {
        let root = "ForgePlatformInstaller.app"
        let malformedArchives: [(String, Data)] = [
            (
                "zip64-eocd",
                makeZIPArchive(
                    entries: validAppBundleEntries(),
                    totalEntryCountOverride: UInt16.max
                )
            ),
            (
                "zip64-extra",
                makeZIPArchive(
                    entries: validAppBundleEntries(
                        overriding: [
                            ZIPFixtureEntry.file(
                                "\(root)/Contents/Info.plist",
                                bytes: Data("<plist/>".utf8),
                                centralExtra: Data([0x01, 0x00, 0x00, 0x00])
                            )
                        ]
                    )
                )
            ),
            (
                "zip64-local-extra",
                makeZIPArchive(
                    entries: validAppBundleEntries(
                        overriding: [
                            ZIPFixtureEntry.file(
                                "\(root)/Contents/Info.plist",
                                bytes: Data("<plist/>".utf8),
                                localExtra: Data([0x01, 0x00, 0x00, 0x00])
                            )
                        ]
                    )
                )
            ),
            (
                "encrypted",
                makeZIPArchive(
                    entries: validAppBundleEntries(
                        overriding: [
                            ZIPFixtureEntry.file(
                                "\(root)/Contents/Info.plist",
                                bytes: Data("<plist/>".utf8),
                                flags: 0x0001
                            )
                        ]
                    )
                )
            ),
            (
                "descriptor-flag",
                makeZIPArchive(
                    entries: validAppBundleEntries(
                        overriding: [
                            ZIPFixtureEntry.file(
                                "\(root)/Contents/Info.plist",
                                bytes: Data("<plist/>".utf8),
                                flags: 0x0008
                            )
                        ]
                    )
                )
            ),
            (
                "symlink",
                makeZIPArchive(
                    entries: validAppBundleEntries(
                        overriding: [
                            ZIPFixtureEntry.file(
                                "\(root)/Contents/MacOS/ForgePlatformInstaller",
                                bytes: Data("binary".utf8),
                                mode: 0o120755
                            )
                        ]
                    )
                )
            ),
            (
                "permissive-entry",
                makeZIPArchive(
                    entries: validAppBundleEntries(
                        overriding: [
                            ZIPFixtureEntry.file(
                                "\(root)/Contents/Info.plist",
                                bytes: Data("<plist/>".utf8),
                                mode: 0o100666
                            )
                        ]
                    )
                )
            ),
            (
                "traversal",
                makeZIPArchive(
                    entries: validAppBundleEntries() + [
                        .file("\(root)/Contents/../MacOS/escape", bytes: Data("x".utf8))
                    ]
                )
            ),
            (
                "second-app-root",
                makeZIPArchive(
                    entries: validAppBundleEntries() + [.directory("Other.app")]
                )
            ),
            (
                "macos-metadata-sidecar",
                makeZIPArchive(
                    entries: validAppBundleEntries() + [
                        .directory("__MACOSX"),
                        .file("__MACOSX/metadata", bytes: Data("ignored".utf8))
                    ]
                )
            ),
            (
                "nested-app-root",
                makeZIPArchive(
                    entries: validAppBundleEntries() + [
                        .directory("\(root)/Contents/Resources/Nested.app")
                    ]
                )
            ),
            (
                "missing-explicit-macos-directory",
                makeZIPArchive(
                    entries: validAppBundleEntries().filter {
                        $0.centralName != "\(root)/Contents/MacOS/"
                    }
                )
            ),
            (
                "duplicate-canonical-path",
                makeZIPArchive(
                    entries: validAppBundleEntries() + [
                        .file("\(root)/Contents/Info.plist", bytes: Data("other".utf8))
                    ]
                )
            ),
            (
                "case-folded-duplicate",
                makeZIPArchive(
                    entries: validAppBundleEntries() + [
                        .file("\(root)/Contents/Resources/README", bytes: Data("a".utf8)),
                        .file("\(root)/Contents/Resources/readme", bytes: Data("b".utf8))
                    ]
                )
            ),
            (
                "declared-expansion-over-limit",
                makeZIPArchive(
                    entries: validAppBundleEntries(
                        overriding: [
                            ZIPFixtureEntry.file(
                                "\(root)/Contents/Info.plist",
                                bytes: Data("compressed".utf8),
                                compressionMethod: 8,
                                declaredUncompressedByteCount: 32_768
                            )
                        ]
                    )
                )
            )
        ]

        for (name, bytes) in malformedArchives {
            let archive = try makeArchiveFixture(bytes: bytes, label: name)
            defer { try? FileManager.default.removeItem(at: archive.directory) }
            let stagedAsset = try makeStagedAsset(byteCount: archive.byteCount)
            let resolver = ArchiveLayoutResolver(
                responses: [.success(archive.url), .success(archive.url)]
            )
            let inspector = try makeInspector()

            let result = await inspector.inspectStagedInstallerArchive(
                stagedAsset,
                using: resolver
            )

            XCTAssertEqual(
                archiveLayoutFailureCode(result),
                .stagingFailed,
                "Expected \(name) archive to fail closed"
            )
        }
    }

    func testRejectsOversizedArchiveAndFilesystemIdentityChanges() async throws {
        let archive = try makeArchiveFixture(entries: validAppBundleEntries())
        defer { try? FileManager.default.removeItem(at: archive.directory) }
        let stagedAsset = try makeStagedAsset(byteCount: archive.byteCount)
        let smallInspector = try makeInspector(
            maximumArchiveBytes: 64,
            maximumCentralDirectoryBytes: 64
        )
        let smallResolver = ArchiveLayoutResolver(
            responses: [.success(archive.url), .success(archive.url)]
        )

        let oversizedResult = await smallInspector.inspectStagedInstallerArchive(
            stagedAsset,
            using: smallResolver
        )
        XCTAssertEqual(archiveLayoutFailureCode(oversizedResult), .stagingFailed)

        try setArchiveMode(at: archive.url, to: mode_t(0o644))
        let insecureResolver = ArchiveLayoutResolver(
            responses: [.success(archive.url), .success(archive.url)]
        )
        let inspector = try makeInspector()
        let insecureResult = await inspector.inspectStagedInstallerArchive(
            stagedAsset,
            using: insecureResolver
        )
        XCTAssertEqual(
            archiveLayoutFailureCode(insecureResult),
            .stagedAssetIdentityChanged
        )

        try setArchiveMode(at: archive.url, to: mode_t(0o600))
        try FileManager.default.removeItem(at: archive.url)
        try FileManager.default.createSymbolicLink(
            at: archive.url,
            withDestinationURL: archive.directory.appendingPathComponent("outside.zip")
        )
        let symlinkResolver = ArchiveLayoutResolver(
            responses: [.success(archive.url), .success(archive.url)]
        )
        let symlinkResult = await inspector.inspectStagedInstallerArchive(
            stagedAsset,
            using: symlinkResolver
        )
        XCTAssertEqual(
            archiveLayoutFailureCode(symlinkResult),
            .stagedAssetIdentityChanged
        )
    }

    func testRejectsResolverSwitchAndArchiveTamperingBeforeReturningLayout() async throws {
        let firstArchive = try makeArchiveFixture(entries: validAppBundleEntries(), label: "first")
        defer { try? FileManager.default.removeItem(at: firstArchive.directory) }
        let secondArchive = try makeArchiveFixture(entries: validAppBundleEntries(), label: "second")
        defer { try? FileManager.default.removeItem(at: secondArchive.directory) }
        let stagedAsset = try makeStagedAsset(byteCount: firstArchive.byteCount)
        let inspector = try makeInspector()

        let switchingResolver = ArchiveLayoutResolver(
            responses: [.success(firstArchive.url), .success(secondArchive.url)]
        )
        let switchedResult = await inspector.inspectStagedInstallerArchive(
            stagedAsset,
            using: switchingResolver
        )
        XCTAssertEqual(
            archiveLayoutFailureCode(switchedResult),
            .stagedAssetIdentityChanged
        )

        let tamperingResolver = TamperingArchiveLayoutResolver(
            archiveURL: firstArchive.url,
            replacementBytes: makeZIPArchive(entries: validAppBundleEntries() + [
                .file(
                    "ForgePlatformInstaller.app/Contents/Resources/tampered.json",
                    bytes: Data("changed".utf8)
                )
            ])
        )
        let tamperedResult = await inspector.inspectStagedInstallerArchive(
            stagedAsset,
            using: tamperingResolver
        )
        XCTAssertEqual(
            archiveLayoutFailureCode(tamperedResult),
            .stagedAssetIdentityChanged
        )
    }

    func testRejectsCentralDirectoryEntryWhoseLocalHeaderNameDoesNotMatch() async throws {
        let root = "ForgePlatformInstaller.app"
        let entries = validAppBundleEntries(
            overriding: [
                ZIPFixtureEntry.file(
                    "\(root)/Contents/Info.plist",
                    localName: "\(root)/Contents/Other.plist",
                    bytes: Data("<plist/>".utf8)
                )
            ]
        )
        let archive = try makeArchiveFixture(entries: entries)
        defer { try? FileManager.default.removeItem(at: archive.directory) }
        let stagedAsset = try makeStagedAsset(byteCount: archive.byteCount)
        let resolver = ArchiveLayoutResolver(
            responses: [.success(archive.url), .success(archive.url)]
        )
        let inspector = try makeInspector()

        let result = await inspector.inspectStagedInstallerArchive(
            stagedAsset,
            using: resolver
        )

        XCTAssertEqual(archiveLayoutFailureCode(result), .stagingFailed)
    }

    private func makeInspector(
        maximumArchiveBytes: Int = 16 * 1024,
        maximumCentralDirectoryBytes: Int = 8 * 1024,
        maximumEntryCount: Int = 64,
        maximumPathBytes: Int = 256,
        maximumTotalUncompressedBytes: UInt64 = 32 * 1024
    ) throws -> MacOSInstallerArchiveLayoutInspector {
        try MacOSInstallerArchiveLayoutInspector(
            maximumArchiveBytes: maximumArchiveBytes,
            maximumCentralDirectoryBytes: maximumCentralDirectoryBytes,
            maximumEntryCount: maximumEntryCount,
            maximumPathBytes: maximumPathBytes,
            maximumTotalUncompressedBytes: maximumTotalUncompressedBytes
        )
    }
}

final class MacOSStagedInstallerArchiveExtractorTests: XCTestCase {
    func testExtractsStoredBundleWithSpacesAndResolvesOnlyReadyBundleIdempotently() async throws {
        let appRoot = "Forge Platform Installer.app"
        let archive = try makeArchiveFixture(
            entries: validAppBundleEntries(root: appRoot),
            label: "stored-spaces"
        )
        defer { try? FileManager.default.removeItem(at: archive.directory) }
        let extractionRoot = archive.directory.appendingPathComponent(
            "private extraction root",
            isDirectory: true
        )
        let stagedAsset = try makeStagedAsset(byteCount: archive.byteCount)
        let resolver = ArchiveLayoutResolver(
            responses: Array(repeating: .success(archive.url), count: 4)
        )
        let extractor = try makeArchiveExtractor(
            extractionRoot: extractionRoot,
            resolver: resolver
        )

        let firstBundleURL = try requireExtractedBundleSuccess(
            await extractor.resolveStagedInstallerBundle(stagedAsset)
        )
        XCTAssertEqual(firstBundleURL.lastPathComponent, appRoot)
        XCTAssertTrue(firstBundleURL.path.contains("/ready/"))
        XCTAssertFalse(firstBundleURL.path.contains("/candidate/"))
        XCTAssertEqual(
            try Data(contentsOf: firstBundleURL.appendingPathComponent("Contents/Info.plist")),
            Data("<plist/>".utf8)
        )
        XCTAssertEqual(try posixMode(at: extractionRoot), mode_t(0o700))
        XCTAssertEqual(try posixMode(at: firstBundleURL.deletingLastPathComponent()), mode_t(0o700))
        XCTAssertEqual(
            try posixMode(at: firstBundleURL.appendingPathComponent("Contents/Info.plist")),
            mode_t(0o600)
        )
        XCTAssertEqual(
            try posixMode(at: firstBundleURL.appendingPathComponent("Contents/MacOS/ForgePlatformInstaller")),
            mode_t(0o700)
        )

        let secondBundleURL = try requireExtractedBundleSuccess(
            await extractor.resolveStagedInstallerBundle(stagedAsset)
        )
        let resolutionCount = await resolver.resolutionCount()
        XCTAssertEqual(secondBundleURL, firstBundleURL)
        XCTAssertEqual(resolutionCount, 4)
    }

    func testRejectsDeflateTraversalAndZipSymlinkWithoutCreatingReadyBundle() async throws {
        let root = "ForgePlatformInstaller.app"
        let malformedArchives: [(String, Data)] = [
            (
                "deflate",
                makeZIPArchive(
                    entries: validAppBundleEntries(
                        overriding: [
                            .file(
                                "\(root)/Contents/Info.plist",
                                bytes: Data("<plist/>".utf8),
                                compressionMethod: 8
                            )
                        ]
                    )
                )
            ),
            (
                "traversal",
                makeZIPArchive(
                    entries: validAppBundleEntries() + [
                        .file("\(root)/Contents/../MacOS/escape", bytes: Data("x".utf8))
                    ]
                )
            ),
            (
                "zip-symlink",
                makeZIPArchive(
                    entries: validAppBundleEntries(
                        overriding: [
                            .file(
                                "\(root)/Contents/MacOS/ForgePlatformInstaller",
                                bytes: Data("binary".utf8),
                                mode: 0o120755
                            )
                        ]
                    )
                )
            )
        ]

        for (label, bytes) in malformedArchives {
            let archive = try makeArchiveFixture(bytes: bytes, label: "extract-\(label)")
            defer { try? FileManager.default.removeItem(at: archive.directory) }
            let extractionRoot = archive.directory.appendingPathComponent("private extraction", isDirectory: true)
            let stagedAsset = try makeStagedAsset(byteCount: archive.byteCount)
            let resolver = ArchiveLayoutResolver(responses: [.success(archive.url)])
            let extractor = try makeArchiveExtractor(
                extractionRoot: extractionRoot,
                resolver: resolver
            )

            let result = await extractor.resolveStagedInstallerBundle(stagedAsset)
            XCTAssertEqual(
                extractedBundleFailureCode(result),
                .stagingFailed,
                "Expected \(label) archive to fail closed"
            )
            XCTAssertFalse(try containsDirectory(named: "ready", below: extractionRoot))
        }
    }

    func testRejectsSymlinkedStagedArchiveBeforeAnyBundleCanBeReady() async throws {
        let archive = try makeArchiveFixture(entries: validAppBundleEntries(), label: "archive-symlink")
        defer { try? FileManager.default.removeItem(at: archive.directory) }
        let outsideArchive = archive.directory.appendingPathComponent("outside.zip")
        try makeZIPArchive(entries: validAppBundleEntries()).write(to: outsideArchive)
        try setArchiveMode(at: outsideArchive, to: mode_t(0o600))
        try FileManager.default.removeItem(at: archive.url)
        try FileManager.default.createSymbolicLink(at: archive.url, withDestinationURL: outsideArchive)

        let extractionRoot = archive.directory.appendingPathComponent("private extraction", isDirectory: true)
        let stagedAsset = try makeStagedAsset(byteCount: archive.byteCount)
        let resolver = ArchiveLayoutResolver(responses: [.success(archive.url)])
        let extractor = try makeArchiveExtractor(
            extractionRoot: extractionRoot,
            resolver: resolver
        )

        let result = await extractor.resolveStagedInstallerBundle(stagedAsset)
        XCTAssertEqual(extractedBundleFailureCode(result), .stagedAssetIdentityChanged)
        XCTAssertFalse(try containsDirectory(named: "ready", below: extractionRoot))
    }

    func testRejectsPermissiveAndSymlinkedPrivateExtractionRoots() async throws {
        let archive = try makeArchiveFixture(entries: validAppBundleEntries(), label: "unsafe-root")
        defer { try? FileManager.default.removeItem(at: archive.directory) }
        let stagedAsset = try makeStagedAsset(byteCount: archive.byteCount)

        let permissiveRoot = archive.directory.appendingPathComponent("permissive extraction", isDirectory: true)
        try FileManager.default.createDirectory(
            at: permissiveRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o755)]
        )
        try setArchiveMode(at: permissiveRoot, to: mode_t(0o755))
        let permissiveResolver = ArchiveLayoutResolver(responses: [.success(archive.url)])
        let permissiveExtractor = try makeArchiveExtractor(
            extractionRoot: permissiveRoot,
            resolver: permissiveResolver
        )
        let permissiveResult = await permissiveExtractor.resolveStagedInstallerBundle(stagedAsset)
        XCTAssertEqual(extractedBundleFailureCode(permissiveResult), .stagingFailed)

        let privateTarget = archive.directory.appendingPathComponent("private target", isDirectory: true)
        try FileManager.default.createDirectory(
            at: privateTarget,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        try setArchiveMode(at: privateTarget, to: mode_t(0o700))
        let symlinkedRoot = archive.directory.appendingPathComponent("symlinked extraction", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: symlinkedRoot, withDestinationURL: privateTarget)
        let symlinkedResolver = ArchiveLayoutResolver(responses: [.success(archive.url)])
        let symlinkedExtractor = try makeArchiveExtractor(
            extractionRoot: symlinkedRoot,
            resolver: symlinkedResolver
        )
        let symlinkedResult = await symlinkedExtractor.resolveStagedInstallerBundle(stagedAsset)
        XCTAssertEqual(extractedBundleFailureCode(symlinkedResult), .stagingFailed)
    }

    func testRejectsArchiveBeyondConfiguredByteBoundBeforeCreatingExtractionState() async throws {
        let archive = try makeArchiveFixture(entries: validAppBundleEntries(), label: "small-bound")
        defer { try? FileManager.default.removeItem(at: archive.directory) }
        let extractionRoot = archive.directory.appendingPathComponent("private extraction", isDirectory: true)
        let stagedAsset = try makeStagedAsset(byteCount: archive.byteCount)
        let resolver = ArchiveLayoutResolver(responses: [.success(archive.url)])
        let extractor = try MacOSStagedInstallerArchiveExtractor(
            extractionRoot: extractionRoot,
            archiveResolver: resolver,
            maximumArchiveBytes: 64,
            maximumCentralDirectoryBytes: 64,
            maximumEntryCount: 64,
            maximumPathBytes: 256,
            maximumTotalUncompressedBytes: 32 * 1024
        )

        let result = await extractor.resolveStagedInstallerBundle(stagedAsset)
        XCTAssertEqual(extractedBundleFailureCode(result), .stagingFailed)
        XCTAssertFalse(try containsDirectory(named: "ready", below: extractionRoot))
    }

    func testRejectsInvalidStoredCRCAndLeavesCandidateUnresolvable() async throws {
        let root = "ForgePlatformInstaller.app"
        let archive = try makeArchiveFixture(
            entries: validAppBundleEntries(
                overriding: [
                    .file(
                        "\(root)/Contents/Info.plist",
                        bytes: Data("<plist/>".utf8),
                        declaredCRC32: 0xdead_beef
                    )
                ]
            ),
            label: "invalid-crc"
        )
        defer { try? FileManager.default.removeItem(at: archive.directory) }
        let extractionRoot = archive.directory.appendingPathComponent("private extraction", isDirectory: true)
        let stagedAsset = try makeStagedAsset(byteCount: archive.byteCount)
        let resolver = ArchiveLayoutResolver(responses: [.success(archive.url)])
        let extractor = try makeArchiveExtractor(
            extractionRoot: extractionRoot,
            resolver: resolver
        )

        let result = await extractor.resolveStagedInstallerBundle(stagedAsset)
        XCTAssertEqual(extractedBundleFailureCode(result), .stagingFailed)
        XCTAssertFalse(try containsDirectory(named: "ready", below: extractionRoot))
        XCTAssertTrue(try containsDirectory(named: "candidate", below: extractionRoot))
    }

    func testRejectsArchiveReplacementBeforeCandidatePromotion() async throws {
        let archive = try makeArchiveFixture(entries: validAppBundleEntries(), label: "replacement")
        defer { try? FileManager.default.removeItem(at: archive.directory) }
        let replacement = makeZIPArchive(
            entries: validAppBundleEntries(
                overriding: [
                    .file(
                        "ForgePlatformInstaller.app/Contents/Resources/installer-release.json",
                        bytes: Data("[]".utf8)
                    )
                ]
            )
        )
        XCTAssertEqual(replacement.count, Int(archive.byteCount))
        let extractionRoot = archive.directory.appendingPathComponent("private extraction", isDirectory: true)
        let stagedAsset = try makeStagedAsset(byteCount: archive.byteCount)
        let resolver = TamperingArchiveLayoutResolver(
            archiveURL: archive.url,
            replacementBytes: replacement
        )
        let extractor = try makeArchiveExtractor(
            extractionRoot: extractionRoot,
            resolver: resolver
        )

        let result = await extractor.resolveStagedInstallerBundle(stagedAsset)
        XCTAssertEqual(extractedBundleFailureCode(result), .stagedAssetIdentityChanged)
        XCTAssertFalse(try containsDirectory(named: "ready", below: extractionRoot))
        XCTAssertTrue(try containsDirectory(named: "candidate", below: extractionRoot))
    }

    func testRejectsPostExtractionBundleTamperingOnRepeatedResolution() async throws {
        let archive = try makeArchiveFixture(entries: validAppBundleEntries(), label: "output-tamper")
        defer { try? FileManager.default.removeItem(at: archive.directory) }
        let extractionRoot = archive.directory.appendingPathComponent("private extraction", isDirectory: true)
        let stagedAsset = try makeStagedAsset(byteCount: archive.byteCount)
        let resolver = ArchiveLayoutResolver(
            responses: Array(repeating: .success(archive.url), count: 4)
        )
        let extractor = try makeArchiveExtractor(
            extractionRoot: extractionRoot,
            resolver: resolver
        )
        let bundleURL = try requireExtractedBundleSuccess(
            await extractor.resolveStagedInstallerBundle(stagedAsset)
        )
        let infoPlist = bundleURL.appendingPathComponent("Contents/Info.plist")
        try Data("<alter/>".utf8).write(to: infoPlist)
        try setArchiveMode(at: infoPlist, to: mode_t(0o600))

        let result = await extractor.resolveStagedInstallerBundle(stagedAsset)
        XCTAssertEqual(extractedBundleFailureCode(result), .stagingFailed)
        XCTAssertNil(extractedBundleURL(result))
        XCTAssertFalse(bundleURL.path.contains("/candidate/"))
    }
}

private struct ArchiveFixture {
    let directory: URL
    let url: URL
    let byteCount: UInt64
}

private enum ArchiveLayoutTestError: Error {
    case unexpectedResult
    case filesystem
}

private func makeArchiveExtractor(
    extractionRoot: URL,
    resolver: any MacOSInstallerArchiveStagingResolving
) throws -> MacOSStagedInstallerArchiveExtractor {
    try MacOSStagedInstallerArchiveExtractor(
        extractionRoot: extractionRoot,
        archiveResolver: resolver,
        maximumArchiveBytes: 16 * 1024,
        maximumCentralDirectoryBytes: 8 * 1024,
        maximumEntryCount: 64,
        maximumPathBytes: 256,
        maximumTotalUncompressedBytes: 32 * 1024
    )
}

private func requireExtractedBundleSuccess(
    _ result: Result<URL, InstallerSelfUpdateFailure>,
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> URL {
    switch result {
    case .success(let bundleURL):
        return bundleURL
    case .failure(let failure):
        XCTFail("Expected extracted bundle success, got \(failure.code)", file: file, line: line)
        throw ArchiveLayoutTestError.unexpectedResult
    }
}

private func extractedBundleFailureCode(
    _ result: Result<URL, InstallerSelfUpdateFailure>
) -> InstallerSelfUpdateFailureCode? {
    switch result {
    case .success:
        return nil
    case .failure(let failure):
        return failure.code
    }
}

private func extractedBundleURL(
    _ result: Result<URL, InstallerSelfUpdateFailure>
) -> URL? {
    switch result {
    case .success(let bundleURL):
        return bundleURL
    case .failure:
        return nil
    }
}

private func posixMode(at url: URL) throws -> mode_t {
    var details = stat()
    let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
        guard let path else { return -1 }
        return Darwin.lstat(path, &details)
    }
    guard result == 0 else {
        throw ArchiveLayoutTestError.filesystem
    }
    return details.st_mode & mode_t(0o7777)
}

private func containsDirectory(named name: String, below root: URL) throws -> Bool {
    guard FileManager.default.fileExists(atPath: root.path) else {
        return false
    }
    let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    )
    while let candidate = enumerator?.nextObject() as? URL {
        let values = try candidate.resourceValues(forKeys: [.isDirectoryKey])
        if candidate.lastPathComponent == name, values.isDirectory == true {
            return true
        }
    }
    return false
}

private func makeArchiveFixture(
    entries: [ZIPFixtureEntry],
    label: String = "layout"
) throws -> ArchiveFixture {
    try makeArchiveFixture(bytes: makeZIPArchive(entries: entries), label: label)
}

private func makeArchiveFixture(bytes: Data, label: String) throws -> ArchiveFixture {
    // `O_NOFOLLOW_ANY` deliberately rejects symlinked parent components.  Use
    // the canonical macOS private temporary root rather than `/tmp` or the
    // process temporary URL, which may traverse the `/var` compatibility
    // symlink on macOS.
    let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        .appendingPathComponent(
            "forge-platform-installer-layout-tests-\(label)-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: NSNumber(value: 0o700)]
    )
    try setArchiveMode(at: directory, to: mode_t(0o700))
    let archiveURL = directory.appendingPathComponent("installer-update.zip")
    try bytes.write(to: archiveURL)
    try setArchiveMode(at: archiveURL, to: mode_t(0o600))
    return ArchiveFixture(
        directory: directory,
        url: archiveURL,
        byteCount: UInt64(bytes.count)
    )
}

private func setArchiveMode(at url: URL, to mode: mode_t) throws {
    let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
        guard let path else { return -1 }
        return Darwin.chmod(path, mode)
    }
    guard result == 0 else {
        throw ArchiveLayoutTestError.filesystem
    }
}

private func makeStagedAsset(byteCount: UInt64) throws -> StagedInstallerAsset {
    try StagedInstallerAsset(
        releaseAssetName: "ForgePlatformInstaller.app.zip",
        opaqueReference: "forge-platform-installer-archive-v1:layout-test:ForgePlatformInstaller.app.zip",
        fileIdentity: try StagedInstallerFileIdentity(
            volumeReference: "layout-test-volume",
            fileReference: "layout-test-file",
            byteCount: byteCount
        )
    )
}

private func requireLayoutSuccess(
    _ result: Result<MacOSInstallerArchiveLayout, InstallerSelfUpdateFailure>,
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> MacOSInstallerArchiveLayout {
    switch result {
    case .success(let layout):
        return layout
    case .failure(let failure):
        XCTFail("Expected layout success, got \(failure.code)", file: file, line: line)
        throw ArchiveLayoutTestError.unexpectedResult
    }
}

private func archiveLayoutFailureCode(
    _ result: Result<MacOSInstallerArchiveLayout, InstallerSelfUpdateFailure>
) -> InstallerSelfUpdateFailureCode? {
    switch result {
    case .success:
        return nil
    case .failure(let failure):
        return failure.code
    }
}

private actor ArchiveLayoutResolver: MacOSInstallerArchiveStagingResolving {
    private var responses: [Result<URL, InstallerSelfUpdateFailure>]
    private var count = 0

    init(responses: [Result<URL, InstallerSelfUpdateFailure>]) {
        self.responses = responses
    }

    func resolveStagedInstallerArchive(
        _ stagedAsset: StagedInstallerAsset
    ) async -> Result<URL, InstallerSelfUpdateFailure> {
        count += 1
        guard !responses.isEmpty else {
            return .failure(InstallerSelfUpdateFailure(.stagedAssetIdentityChanged))
        }
        return responses.removeFirst()
    }

    func resolutionCount() -> Int {
        count
    }
}

private actor TamperingArchiveLayoutResolver: MacOSInstallerArchiveStagingResolving {
    private let archiveURL: URL
    private let replacementBytes: Data
    private var count = 0

    init(archiveURL: URL, replacementBytes: Data) {
        self.archiveURL = archiveURL
        self.replacementBytes = replacementBytes
    }

    func resolveStagedInstallerArchive(
        _ stagedAsset: StagedInstallerAsset
    ) async -> Result<URL, InstallerSelfUpdateFailure> {
        count += 1
        if count == 2 {
            do {
                try replacementBytes.write(to: archiveURL, options: .atomic)
                try setArchiveMode(at: archiveURL, to: mode_t(0o600))
            } catch {
                return .failure(InstallerSelfUpdateFailure(.stagedAssetIdentityChanged))
            }
        }
        return .success(archiveURL)
    }
}

private struct ZIPFixtureEntry {
    let centralName: String
    let localName: String
    let bytes: Data
    let flags: UInt16
    let compressionMethod: UInt16
    let mode: UInt16
    let centralExtra: Data
    let localExtra: Data
    let centralComment: Data
    let versionMadeBy: UInt16
    let declaredUncompressedByteCount: UInt32?
    let declaredCRC32: UInt32?

    static func directory(_ path: String, mode: UInt16 = 0o040755) -> ZIPFixtureEntry {
        let name = path.hasSuffix("/") ? path : "\(path)/"
        return ZIPFixtureEntry(
            centralName: name,
            localName: name,
            bytes: Data(),
            flags: 0,
            compressionMethod: 0,
            mode: mode,
            centralExtra: Data(),
            localExtra: Data(),
            centralComment: Data(),
            versionMadeBy: 0x0314,
            declaredUncompressedByteCount: nil,
            declaredCRC32: nil
        )
    }

    static func file(
        _ path: String,
        localName: String? = nil,
        bytes: Data,
        flags: UInt16 = 0,
        compressionMethod: UInt16 = 0,
        mode: UInt16 = 0o100644,
        centralExtra: Data = Data(),
        localExtra: Data = Data(),
        centralComment: Data = Data(),
        versionMadeBy: UInt16 = 0x0314,
        declaredUncompressedByteCount: UInt32? = nil,
        declaredCRC32: UInt32? = nil
    ) -> ZIPFixtureEntry {
        ZIPFixtureEntry(
            centralName: path,
            localName: localName ?? path,
            bytes: bytes,
            flags: flags,
            compressionMethod: compressionMethod,
            mode: mode,
            centralExtra: centralExtra,
            localExtra: localExtra,
            centralComment: centralComment,
            versionMadeBy: versionMadeBy,
            declaredUncompressedByteCount: declaredUncompressedByteCount,
            declaredCRC32: declaredCRC32
        )
    }
}

private func validAppBundleEntries(
    root: String = "ForgePlatformInstaller.app",
    overriding replacements: [ZIPFixtureEntry] = []
) -> [ZIPFixtureEntry] {
    let base = [
        ZIPFixtureEntry.directory(root),
        .directory("\(root)/Contents"),
        .file("\(root)/Contents/Info.plist", bytes: Data("<plist/>".utf8)),
        .directory("\(root)/Contents/MacOS"),
        .file(
            "\(root)/Contents/MacOS/ForgePlatformInstaller",
            bytes: Data("binary".utf8),
            mode: 0o100755
        ),
        .directory("\(root)/Contents/Resources"),
        .file(
            "\(root)/Contents/Resources/installer-release.json",
            bytes: Data("{}".utf8)
        )
    ]
    guard !replacements.isEmpty else {
        return base
    }
    let replacementNames = Set(replacements.map(\.centralName))
    return base.filter { !replacementNames.contains($0.centralName) } + replacements
}

private func makeZIPArchive(
    entries: [ZIPFixtureEntry],
    totalEntryCountOverride: UInt16? = nil
) -> Data {
    var archive = Data()
    var centralDirectory = Data()
    var localOffsets: [UInt32] = []
    localOffsets.reserveCapacity(entries.count)

    for entry in entries {
        let localName = Data(entry.localName.utf8)
        let declaredUncompressedByteCount = entry.declaredUncompressedByteCount ?? UInt32(entry.bytes.count)
        let declaredCRC32 = entry.declaredCRC32 ?? zipFixtureCRC32(entry.bytes)
        localOffsets.append(UInt32(archive.count))
        appendUInt32(0x0403_4b50, to: &archive)
        appendUInt16(20, to: &archive)
        appendUInt16(entry.flags, to: &archive)
        appendUInt16(entry.compressionMethod, to: &archive)
        appendUInt16(0, to: &archive)
        appendUInt16(0, to: &archive)
        appendUInt32(declaredCRC32, to: &archive)
        appendUInt32(UInt32(entry.bytes.count), to: &archive)
        appendUInt32(declaredUncompressedByteCount, to: &archive)
        appendUInt16(UInt16(localName.count), to: &archive)
        appendUInt16(UInt16(entry.localExtra.count), to: &archive)
        archive.append(localName)
        archive.append(entry.localExtra)
        archive.append(entry.bytes)
    }

    for (index, entry) in entries.enumerated() {
        let centralName = Data(entry.centralName.utf8)
        let declaredUncompressedByteCount = entry.declaredUncompressedByteCount ?? UInt32(entry.bytes.count)
        let declaredCRC32 = entry.declaredCRC32 ?? zipFixtureCRC32(entry.bytes)
        appendUInt32(0x0201_4b50, to: &centralDirectory)
        appendUInt16(entry.versionMadeBy, to: &centralDirectory)
        appendUInt16(20, to: &centralDirectory)
        appendUInt16(entry.flags, to: &centralDirectory)
        appendUInt16(entry.compressionMethod, to: &centralDirectory)
        appendUInt16(0, to: &centralDirectory)
        appendUInt16(0, to: &centralDirectory)
        appendUInt32(declaredCRC32, to: &centralDirectory)
        appendUInt32(UInt32(entry.bytes.count), to: &centralDirectory)
        appendUInt32(declaredUncompressedByteCount, to: &centralDirectory)
        appendUInt16(UInt16(centralName.count), to: &centralDirectory)
        appendUInt16(UInt16(entry.centralExtra.count), to: &centralDirectory)
        appendUInt16(UInt16(entry.centralComment.count), to: &centralDirectory)
        appendUInt16(0, to: &centralDirectory)
        appendUInt16(0, to: &centralDirectory)
        appendUInt32(UInt32(entry.mode) << 16, to: &centralDirectory)
        appendUInt32(localOffsets[index], to: &centralDirectory)
        centralDirectory.append(centralName)
        centralDirectory.append(entry.centralExtra)
        centralDirectory.append(entry.centralComment)
    }

    let centralDirectoryOffset = UInt32(archive.count)
    archive.append(centralDirectory)
    let entryCount = totalEntryCountOverride ?? UInt16(entries.count)
    appendUInt32(0x0605_4b50, to: &archive)
    appendUInt16(0, to: &archive)
    appendUInt16(0, to: &archive)
    appendUInt16(entryCount, to: &archive)
    appendUInt16(entryCount, to: &archive)
    appendUInt32(UInt32(centralDirectory.count), to: &archive)
    appendUInt32(centralDirectoryOffset, to: &archive)
    appendUInt16(0, to: &archive)
    return archive
}

private func appendUInt16(_ value: UInt16, to data: inout Data) {
    let littleEndian = value.littleEndian
    withUnsafeBytes(of: littleEndian) { data.append(contentsOf: $0) }
}

private func appendUInt32(_ value: UInt32, to data: inout Data) {
    let littleEndian = value.littleEndian
    withUnsafeBytes(of: littleEndian) { data.append(contentsOf: $0) }
}

private func zipFixtureCRC32(_ data: Data) -> UInt32 {
    var value: UInt32 = 0xffff_ffff
    for byte in data {
        var remainder = (value ^ UInt32(byte)) & 0xff
        for _ in 0..<8 {
            remainder = (remainder & 1) == 1
                ? 0xedb8_8320 ^ (remainder >> 1)
                : remainder >> 1
        }
        value = remainder ^ (value >> 8)
    }
    return value ^ 0xffff_ffff
}
