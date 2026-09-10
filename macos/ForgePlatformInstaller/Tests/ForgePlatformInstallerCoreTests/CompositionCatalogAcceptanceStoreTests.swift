import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class CompositionCatalogAcceptanceStoreTests: XCTestCase {
    func testStoresOneTerminalCommitmentPerExactScope() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try makeScope()
        let commitment = try makeCommitment(scope: scope, sequence: 4, catalogSHA256: taggedDigest("a"))
        let store = FileCompositionCatalogAcceptanceStore(rootDirectory: root)

        let before = await store.loadAcceptedCatalog(for: scope)
        let committed = await store.commit(commitment)
        let loaded = await store.loadAcceptedCatalog(for: scope)

        XCTAssertEqual(before, .success(nil))
        assertCommitSucceeded(committed)
        XCTAssertEqual(loaded, .success(commitment.acceptance))
    }

    func testScopesStaySeparatedByTrustDigestChannelAndExactFeed() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileCompositionCatalogAcceptanceStore(rootDirectory: root)
        let stable = try makeScope()
        let changedTrust = try makeScope(trustDigest: String(repeating: "b", count: 64))
        let candidate = try makeScope(channel: .candidate)
        let changedFeed = try makeScope(feedURL: "https://catalog.example.test/alternate.json")
        let commitment = try makeCommitment(scope: stable, sequence: 4, catalogSHA256: taggedDigest("a"))

        assertCommitSucceeded(await store.commit(commitment))
        let stableReadback = await store.loadAcceptedCatalog(for: stable)
        let changedTrustReadback = await store.loadAcceptedCatalog(for: changedTrust)
        let candidateReadback = await store.loadAcceptedCatalog(for: candidate)
        let changedFeedReadback = await store.loadAcceptedCatalog(for: changedFeed)
        XCTAssertEqual(stableReadback, .success(commitment.acceptance))
        XCTAssertEqual(changedTrustReadback, .success(nil))
        XCTAssertEqual(candidateReadback, .success(nil))
        XCTAssertEqual(changedFeedReadback, .success(nil))
    }

    func testCommitIsMonotonicAndSameIdentityIsIdempotentWithoutReplacingTerminalBinding() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try makeScope()
        let store = FileCompositionCatalogAcceptanceStore(rootDirectory: root)
        let initial = try makeCommitment(scope: scope, sequence: 4, catalogSHA256: taggedDigest("a"))
        let newer = try makeCommitment(
            scope: scope,
            sequence: 5,
            catalogSHA256: taggedDigest("b"),
            operationID: "operation:catalog-install-002",
            receiptReference: "receipt:catalog-complete-002"
        )

        assertCommitSucceeded(await store.commit(initial))
        assertCommitSucceeded(await store.commit(newer))
        let afterAdvance = await store.loadAcceptedCatalog(for: scope)
        XCTAssertEqual(afterAdvance, .success(newer.acceptance))

        let recordURL = try soleRecordURL(in: root)
        let originalBytes = try Data(contentsOf: recordURL)
        let sameIdentityNewReceipt = try makeCommitment(
            scope: scope,
            sequence: 5,
            catalogSHA256: taggedDigest("b"),
            operationID: "operation:catalog-install-003",
            receiptReference: "receipt:catalog-complete-003"
        )
        assertCommitSucceeded(await store.commit(sameIdentityNewReceipt))
        XCTAssertEqual(try Data(contentsOf: recordURL), originalBytes)

        let older = try makeCommitment(
            scope: scope,
            sequence: 4,
            catalogSHA256: taggedDigest("a"),
            operationID: "operation:catalog-install-004",
            receiptReference: "receipt:catalog-complete-004"
        )
        let conflictingSameSequence = try makeCommitment(
            scope: scope,
            sequence: 5,
            catalogSHA256: taggedDigest("c"),
            operationID: "operation:catalog-install-005",
            receiptReference: "receipt:catalog-complete-005"
        )
        assertCommitFailed(await store.commit(older))
        assertCommitFailed(await store.commit(conflictingSameSequence))
        let finalReadback = await store.loadAcceptedCatalog(for: scope)
        XCTAssertEqual(finalReadback, .success(newer.acceptance))
    }

    func testRejectsBareOrMalformedTerminalCommitments() throws {
        let scope = try makeScope()
        let acceptance = try makeAcceptance(scope: scope, sequence: 4, catalogSHA256: taggedDigest("a"))

        XCTAssertThrowsError(try CompositionCatalogTerminalCommitment(
            acceptance: acceptance,
            operationID: "catalog-install-001",
            compositionID: "forge-ep-workspace-001",
            manifestSHA256: taggedDigest("c"),
            receiptReference: "receipt:catalog-complete-001"
        ))
        XCTAssertThrowsError(try CompositionCatalogTerminalCommitment(
            acceptance: acceptance,
            operationID: "operation:catalog-install-001",
            compositionID: "forge ep workspace",
            manifestSHA256: taggedDigest("c"),
            receiptReference: "receipt:catalog-complete-001"
        ))
        XCTAssertThrowsError(try CompositionCatalogTerminalCommitment(
            acceptance: acceptance,
            operationID: "operation:catalog-install-001",
            compositionID: "forge-ep-workspace-001",
            manifestSHA256: String(repeating: "c", count: 64),
            receiptReference: "receipt:catalog-complete-001"
        ))
        XCTAssertThrowsError(try CompositionCatalogTerminalCommitment(
            acceptance: acceptance,
            operationID: "operation:catalog-install-001",
            compositionID: "forge-ep-workspace-001",
            manifestSHA256: taggedDigest("c"),
            receiptReference: "complete-001"
        ))
    }

    func testFailsClosedForCorruptDuplicateOrMismatchedScopeRecords() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileCompositionCatalogAcceptanceStore(rootDirectory: root)
        let scope = try makeScope()
        let otherScope = try makeScope(feedURL: "https://catalog.example.test/alternate.json")
        let commitment = try makeCommitment(scope: scope, sequence: 4, catalogSHA256: taggedDigest("a"))
        let otherCommitment = try makeCommitment(
            scope: otherScope,
            sequence: 4,
            catalogSHA256: taggedDigest("b"),
            operationID: "operation:catalog-install-002",
            receiptReference: "receipt:catalog-complete-002"
        )
        assertCommitSucceeded(await store.commit(commitment))
        assertCommitSucceeded(await store.commit(otherCommitment))

        let records = try recordURLs(in: root)
        guard records.count == 2,
              let ownRecord = try records.first(where: { try String(contentsOf: $0).contains(taggedDigest("a")) }),
              let otherRecord = try records.first(where: { try String(contentsOf: $0).contains(taggedDigest("b")) }) else {
            return XCTFail("Expected two independently scoped catalog records")
        }
        let ownData = try Data(contentsOf: ownRecord)
        try ownData.write(to: otherRecord, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: otherRecord.path)
        assertLoadFailed(await store.loadAcceptedCatalog(for: otherScope))

        try Data("{\"schema_version\":1,\"schema_version\":1}".utf8).write(to: ownRecord, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ownRecord.path)
        assertLoadFailed(await store.loadAcceptedCatalog(for: scope))
    }

    func testFailsClosedForInsecureRootsRecordsAndLockContention() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try makeScope()
        let commitment = try makeCommitment(scope: scope, sequence: 4, catalogSHA256: taggedDigest("a"))
        let store = FileCompositionCatalogAcceptanceStore(rootDirectory: root)
        assertCommitSucceeded(await store.commit(commitment))

        let record = try soleRecordURL(in: root)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: record.path)
        assertLoadFailed(await store.loadAcceptedCatalog(for: scope))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: record.path)

        let sibling = record.deletingLastPathComponent().appendingPathComponent("linked-record.json")
        let linked = record.path.withCString { source in
            sibling.path.withCString { destination in
                Darwin.link(source, destination)
            }
        }
        XCTAssertEqual(linked, 0)
        assertLoadFailed(await store.loadAcceptedCatalog(for: scope))
        try FileManager.default.removeItem(at: sibling)

        do {
            let lockURL = root.appendingPathComponent("composition-catalog-acceptance-v1.lock")
            let descriptor = lockURL.path.withCString { Darwin.open($0, O_RDWR | O_CLOEXEC) }
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            defer {
                _ = flock(descriptor, LOCK_UN)
                _ = Darwin.close(descriptor)
            }
            XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
            assertLoadFailed(await store.loadAcceptedCatalog(for: scope))
        }

        let unrelated = record.deletingLastPathComponent().appendingPathComponent("unrelated-record.json")
        try Data(contentsOf: record).write(to: unrelated, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unrelated.path)
        try FileManager.default.removeItem(at: record)
        try FileManager.default.createSymbolicLink(at: record, withDestinationURL: unrelated)
        assertLoadFailed(await store.loadAcceptedCatalog(for: scope))
    }

    func testRejectsFIFORecordsAndLocksWithoutBlocking() async throws {
        let recordRoot = try makeRoot()
        defer { try? FileManager.default.removeItem(at: recordRoot) }
        let scope = try makeScope()
        let commitment = try makeCommitment(scope: scope, sequence: 4, catalogSHA256: taggedDigest("a"))
        let recordStore = FileCompositionCatalogAcceptanceStore(rootDirectory: recordRoot)
        assertCommitSucceeded(await recordStore.commit(commitment))

        let record = try soleRecordURL(in: recordRoot)
        try FileManager.default.removeItem(at: record)
        XCTAssertEqual(record.path.withCString { Darwin.mkfifo($0, mode_t(0o600)) }, 0)
        assertLoadFailed(await recordStore.loadAcceptedCatalog(for: scope))

        let lockRoot = try makeRoot()
        defer { try? FileManager.default.removeItem(at: lockRoot) }
        try FileManager.default.createDirectory(
            at: lockRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let lock = lockRoot.appendingPathComponent("composition-catalog-acceptance-v1.lock")
        XCTAssertEqual(lock.path.withCString { Darwin.mkfifo($0, mode_t(0o600)) }, 0)
        let lockStore = FileCompositionCatalogAcceptanceStore(rootDirectory: lockRoot)
        assertCommitFailed(await lockStore.commit(commitment))
    }

    func testDurablySynchronizesNewRootAndRecordsDirectoryBeforeFirstCommit() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = DescriptorSyncRecorder()
        let store = FileCompositionCatalogAcceptanceStore(
            rootDirectory: root,
            durableSynchronizer: { descriptor in recorder.synchronize(descriptor) }
        )
        let scope = try makeScope()
        let commitment = try makeCommitment(scope: scope, sequence: 4, catalogSHA256: taggedDigest("a"))

        assertCommitSucceeded(await store.commit(commitment))

        let parentInode = try inode(of: root.deletingLastPathComponent())
        let rootInode = try inode(of: root)
        let recordsInode = try inode(
            of: root.appendingPathComponent("composition-catalog-acceptance-v1", isDirectory: true)
        )
        let calls = recorder.inodes()
        guard let firstRoot = calls.firstIndex(of: rootInode),
              let firstParent = calls.firstIndex(of: parentInode),
              let firstRecords = calls.firstIndex(of: recordsInode),
              let rootAfterRecords = calls.indices.first(
                  where: { $0 > firstRecords && calls[$0] == rootInode }
              ) else {
            return XCTFail("Expected durable syncs for the root, its parent and records directory")
        }
        XCTAssertLessThan(firstRoot, firstParent)
        XCTAssertLessThan(firstParent, firstRecords)
        XCTAssertLessThan(firstRecords, rootAfterRecords)
    }

    func testFailsClosedWhenDirectoryDurabilityCannotBeConfirmed() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileCompositionCatalogAcceptanceStore(
            rootDirectory: root,
            durableSynchronizer: { _ in false }
        )
        let scope = try makeScope()
        let commitment = try makeCommitment(scope: scope, sequence: 4, catalogSHA256: taggedDigest("a"))

        assertCommitFailed(await store.commit(commitment))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("composition-catalog-acceptance-v1").path
            )
        )
    }

    func testNormalizesTemporaryAliasesAndPathsWithSpaces() async throws {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("forge platform catalog acceptance \(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let privateAlias = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(root.lastPathComponent, isDirectory: true)
        let scope = try makeScope()
        let commitment = try makeCommitment(scope: scope, sequence: 4, catalogSHA256: taggedDigest("a"))

        let writer = FileCompositionCatalogAcceptanceStore(rootDirectory: root)
        assertCommitSucceeded(await writer.commit(commitment))
        let aliasReadback = await FileCompositionCatalogAcceptanceStore(rootDirectory: privateAlias)
            .loadAcceptedCatalog(for: scope)
        XCTAssertEqual(aliasReadback, .success(commitment.acceptance))
    }

    func testRejectsSymlinkedAndPermissiveRoots() async throws {
        let base = try makeRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        let target = base.appendingPathComponent("target", isDirectory: true)
        let symlink = base.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
        let scope = try makeScope()
        let commitment = try makeCommitment(scope: scope, sequence: 4, catalogSHA256: taggedDigest("a"))
        let symlinkResult = await FileCompositionCatalogAcceptanceStore(rootDirectory: symlink).commit(commitment)
        assertCommitFailed(symlinkResult)

        let permissive = base.appendingPathComponent("permissive", isDirectory: true)
        try FileManager.default.createDirectory(
            at: permissive,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: permissive.path)
        let permissiveResult = await FileCompositionCatalogAcceptanceStore(rootDirectory: permissive).commit(commitment)
        assertCommitFailed(permissiveResult)
    }

    private func makeRoot() throws -> URL {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-platform-catalog-acceptance-tests", isDirectory: true)
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return parent.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
    }

    private func makeScope(
        trustDigest: String = String(repeating: "a", count: 64),
        channel: InstallerReleaseChannel = .stable,
        feedURL: String = "https://catalog.example.test/catalog.json"
    ) throws -> CompositionCatalogAcceptanceScope {
        try CompositionCatalogAcceptanceScope(
            installerReleaseTrustConfigurationSHA256: trustDigest,
            channel: channel,
            feed: try VerifiedCompositionCatalogFeedLocator(url: feedURL)
        )
    }

    private func makeAcceptance(
        scope: CompositionCatalogAcceptanceScope,
        sequence: UInt64,
        catalogSHA256: String
    ) throws -> CompositionCatalogAcceptance {
        CompositionCatalogAcceptance(
            scope: scope,
            identity: try VerifiedCompositionCatalogIdentity(sequence: sequence, sha256: catalogSHA256)
        )
    }

    private func makeCommitment(
        scope: CompositionCatalogAcceptanceScope,
        sequence: UInt64,
        catalogSHA256: String,
        operationID: String = "operation:catalog-install-001",
        receiptReference: String = "receipt:catalog-complete-001"
    ) throws -> CompositionCatalogTerminalCommitment {
        try CompositionCatalogTerminalCommitment(
            acceptance: try makeAcceptance(
                scope: scope,
                sequence: sequence,
                catalogSHA256: catalogSHA256
            ),
            operationID: operationID,
            compositionID: "forge-ep-workspace-001",
            manifestSHA256: taggedDigest("c"),
            receiptReference: receiptReference
        )
    }

    private func recordURLs(in root: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("composition-catalog-acceptance-v1", isDirectory: true),
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
    }

    private func soleRecordURL(in root: URL) throws -> URL {
        let records = try recordURLs(in: root)
        guard records.count == 1, let record = records.first else {
            throw NSError(domain: "CompositionCatalogAcceptanceStoreTests", code: 1)
        }
        return record
    }

    private func inode(of url: URL) throws -> UInt64 {
        var details = stat()
        let result = url.path.withCString { Darwin.lstat($0, &details) }
        guard result == 0 else {
            throw NSError(domain: "CompositionCatalogAcceptanceStoreTests", code: 2)
        }
        return UInt64(details.st_ino)
    }

    private func assertCommitSucceeded(
        _ result: Result<Void, CompositionCatalogAcceptanceStorageFailure>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if case .failure(let failure) = result {
            XCTFail("Expected catalog commitment to succeed: \(failure)", file: file, line: line)
        }
    }

    private func assertCommitFailed(
        _ result: Result<Void, CompositionCatalogAcceptanceStorageFailure>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .failure(.unavailable) = result else {
            return XCTFail("Expected catalog commitment to fail closed", file: file, line: line)
        }
    }

    private func assertLoadFailed(
        _ result: Result<CompositionCatalogAcceptance?, CompositionCatalogAcceptanceStorageFailure>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .failure(.unavailable) = result else {
            return XCTFail("Expected catalog acceptance readback to fail closed", file: file, line: line)
        }
    }

    private func taggedDigest(_ scalar: Character) -> String {
        "sha256:" + String(repeating: scalar, count: 64)
    }
}

private final class DescriptorSyncRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedInodes: [UInt64] = []

    func synchronize(_ descriptor: Int32) -> Bool {
        var details = stat()
        guard Darwin.fstat(descriptor, &details) == 0 else {
            return false
        }
        lock.lock()
        recordedInodes.append(UInt64(details.st_ino))
        lock.unlock()
        return Darwin.fsync(descriptor) == 0
    }

    func inodes() -> [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return recordedInodes
    }
}
