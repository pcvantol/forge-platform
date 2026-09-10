import CryptoKit
import Darwin
import Foundation

/// Read/write seam for the highest terminally committed signed catalog per
/// exact installer trust, channel and feed scope. This is deliberately
/// separate from installer self-update acceptance: a catalog anchor may not be
/// read from or written to a product data root, nor may it be saved as a bare
/// sequence/digest outside a completed composition operation.
protocol CompositionCatalogAcceptanceStoring: Sendable {
    func loadAcceptedCatalog(
        for scope: CompositionCatalogAcceptanceScope
    ) async -> Result<CompositionCatalogAcceptance?, CompositionCatalogAcceptanceStorageFailure>

    func commit(
        _ commitment: CompositionCatalogTerminalCommitment
    ) async -> Result<Void, CompositionCatalogAcceptanceStorageFailure>
}

/// The storage boundary deliberately returns one generic failure. A caller
/// must not project a state path, lock condition, malformed record, catalog
/// URL, operation ID or receipt reference into the wizard.
enum CompositionCatalogAcceptanceStorageFailure: Error, Equatable, Sendable {
    case unavailable
}

/// The sole value accepted by the durable catalog-anchor writer. A future
/// composition-operation coordinator may construct it only after it has
/// validated product-owned terminal receipts, readiness and cleanup. This
/// source layer does not validate those receipts or execute an operation; the
/// type makes a bare candidate catalog acceptance insufficient to persist.
struct CompositionCatalogTerminalCommitment: Equatable, Sendable {
    let acceptance: CompositionCatalogAcceptance
    let operationID: String
    let compositionID: String
    let manifestSHA256: String
    let receiptReference: String

    init(
        acceptance: CompositionCatalogAcceptance,
        operationID: String,
        compositionID: String,
        manifestSHA256: String,
        receiptReference: String
    ) throws {
        guard CompositionCatalogAcceptanceRecordValidation.isOperationID(operationID),
              CompositionCatalogValidation.isCompositionIdentity(compositionID),
              CompositionCatalogAcceptanceRecordValidation.isTaggedSHA256(manifestSHA256),
              CompositionCatalogAcceptanceRecordValidation.isReceiptReference(receiptReference) else {
            throw CompositionCatalogAcceptanceStorageFailure.unavailable
        }
        self.acceptance = acceptance
        self.operationID = operationID
        self.compositionID = compositionID
        self.manifestSHA256 = manifestSHA256
        self.receiptReference = receiptReference
    }
}

/// Durable, installer-owned, per-scope anti-replay storage. The caller gives a
/// preselected installer state root; this store never discovers a root from
/// PATH, a product data root, a catalog URL, a UI field or a provider. Each
/// operation takes its own non-blocking `flock(2)` lease, so read/compare/write
/// cannot race another cooperating catalog-operation process.
///
/// This store is intentionally unassembled. In particular, neither the
/// startup/runtime builder, catalog transport, session preparer, wizard nor a
/// product adapter invokes it in this increment.
struct FileCompositionCatalogAcceptanceStore: CompositionCatalogAcceptanceStoring {
    private static let recordsDirectoryName = "composition-catalog-acceptance-v1"
    private static let lockFileName = "composition-catalog-acceptance-v1.lock"
    private static let maximumRecordBytes = 64 * 1024
    private static let schemaVersion = 1

    private let rootDirectory: URL
    private let durableSynchronizer: @Sendable (Int32) -> Bool

    init(rootDirectory: URL) {
        self.init(
            rootDirectory: rootDirectory,
            durableSynchronizer: { descriptor in Darwin.fsync(descriptor) == 0 }
        )
    }

    // Internal test seam. Production construction always uses `fsync(2)`;
    // tests use this only to prove that a first successful commitment durably
    // synchronizes each newly created directory and its parent in order.
    init(
        rootDirectory: URL,
        durableSynchronizer: @escaping @Sendable (Int32) -> Bool
    ) {
        self.rootDirectory = Self.canonicalRootDirectory(for: rootDirectory)
        self.durableSynchronizer = durableSynchronizer
    }

    func loadAcceptedCatalog(
        for scope: CompositionCatalogAcceptanceScope
    ) async -> Result<CompositionCatalogAcceptance?, CompositionCatalogAcceptanceStorageFailure> {
        do {
            guard let rootDescriptor = try openSecureRootDirectory(createIfMissing: false) else {
                return .success(nil)
            }
            defer { _ = Darwin.close(rootDescriptor) }
            return try withExclusiveLock(in: rootDescriptor) {
                guard let recordsDescriptor = try openSecureRecordsDirectory(
                    in: rootDescriptor,
                    createIfMissing: false
                ) else {
                    return .success(nil)
                }
                defer { _ = Darwin.close(recordsDescriptor) }
                let recordName = Self.recordFileName(for: scope)
                guard let data = try readSecureRegularFileIfPresent(
                    named: recordName,
                    in: recordsDescriptor
                ) else {
                    return .success(nil)
                }
                let commitment = try decodeCommitment(data, expectedScope: scope)
                return .success(commitment.acceptance)
            }
        } catch {
            return .failure(.unavailable)
        }
    }

    func commit(
        _ commitment: CompositionCatalogTerminalCommitment
    ) async -> Result<Void, CompositionCatalogAcceptanceStorageFailure> {
        do {
            let validated = try CompositionCatalogTerminalCommitment(
                acceptance: commitment.acceptance,
                operationID: commitment.operationID,
                compositionID: commitment.compositionID,
                manifestSHA256: commitment.manifestSHA256,
                receiptReference: commitment.receiptReference
            )
            let rootDescriptor = try requireSecureRootDirectory()
            defer { _ = Darwin.close(rootDescriptor) }
            return try withExclusiveLock(in: rootDescriptor) {
                let recordsDescriptor = try requireSecureRecordsDirectory(in: rootDescriptor)
                defer { _ = Darwin.close(recordsDescriptor) }
                let recordName = Self.recordFileName(for: validated.acceptance.scope)

                if let data = try readSecureRegularFileIfPresent(
                    named: recordName,
                    in: recordsDescriptor
                ) {
                    let existing = try decodeCommitment(
                        data,
                        expectedScope: validated.acceptance.scope
                    )
                    if existing.acceptance.identity.sequence > validated.acceptance.identity.sequence {
                        throw CompositionCatalogAcceptanceStoreError.insecure
                    }
                    if existing.acceptance.identity.sequence == validated.acceptance.identity.sequence {
                        guard existing.acceptance.identity.sha256 == validated.acceptance.identity.sha256 else {
                            throw CompositionCatalogAcceptanceStoreError.insecure
                        }
                        // Same immutable catalog identity is idempotent. Do not
                        // overwrite its original terminal receipt binding.
                        return .success(())
                    }
                }

                try writeAtomically(
                    try encodeCommitment(validated),
                    named: recordName,
                    in: recordsDescriptor
                )
                return .success(())
            }
        } catch {
            return .failure(.unavailable)
        }
    }

    private func encodeCommitment(_ commitment: CompositionCatalogTerminalCommitment) throws -> Data {
        let record = SerializedCommitment(commitment: commitment)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        guard !data.isEmpty, data.count <= Self.maximumRecordBytes else {
            throw CompositionCatalogAcceptanceStoreError.insecure
        }
        return data
    }

    private func decodeCommitment(
        _ data: Data,
        expectedScope: CompositionCatalogAcceptanceScope
    ) throws -> CompositionCatalogTerminalCommitment {
        guard !data.isEmpty, data.count <= Self.maximumRecordBytes else {
            throw CompositionCatalogAcceptanceStoreError.insecure
        }
        var reader = try StrictJSONResourceReader(data: data)
        let root = try reader.parseDocument()
        guard let fields = root.objectValue,
              Set(fields.keys) == Set(["schema_version", "scope", "catalog", "terminal_operation"]),
              fields["schema_version"]?.integerValue == Self.schemaVersion,
              let scopeFields = fields["scope"]?.objectValue,
              let catalogFields = fields["catalog"]?.objectValue,
              let terminalFields = fields["terminal_operation"]?.objectValue,
              Set(scopeFields.keys) == Set([
                  "installer_release_trust_configuration_sha256", "channel", "feed_url",
              ]),
              Set(catalogFields.keys) == Set(["sequence", "sha256"]),
              Set(terminalFields.keys) == Set([
                  "state", "operation_id", "composition_id", "manifest_sha256", "receipt_reference",
              ]),
              let trustConfigurationSHA256 = scopeFields["installer_release_trust_configuration_sha256"]?.stringValue,
              let channelRaw = scopeFields["channel"]?.stringValue,
              let feedURL = scopeFields["feed_url"]?.stringValue,
              let channel = InstallerReleaseChannel(rawValue: channelRaw),
              let feed = try? VerifiedCompositionCatalogFeedLocator(url: feedURL),
              let sequence = catalogFields["sequence"]?.positiveUInt64Value,
              let catalogSHA256 = catalogFields["sha256"]?.stringValue,
              let operationState = terminalFields["state"]?.stringValue,
              operationState == "COMPLETE",
              let operationID = terminalFields["operation_id"]?.stringValue,
              let compositionID = terminalFields["composition_id"]?.stringValue,
              let manifestSHA256 = terminalFields["manifest_sha256"]?.stringValue,
              let receiptReference = terminalFields["receipt_reference"]?.stringValue else {
            throw CompositionCatalogAcceptanceStoreError.insecure
        }

        let scope = try CompositionCatalogAcceptanceScope(
            installerReleaseTrustConfigurationSHA256: trustConfigurationSHA256,
            channel: channel,
            feed: feed
        )
        guard scope == expectedScope else {
            throw CompositionCatalogAcceptanceStoreError.insecure
        }
        let acceptance = CompositionCatalogAcceptance(
            scope: scope,
            identity: try VerifiedCompositionCatalogIdentity(sequence: sequence, sha256: catalogSHA256)
        )
        return try CompositionCatalogTerminalCommitment(
            acceptance: acceptance,
            operationID: operationID,
            compositionID: compositionID,
            manifestSHA256: manifestSHA256,
            receiptReference: receiptReference
        )
    }

    private func requireSecureRootDirectory() throws -> Int32 {
        guard let descriptor = try openSecureRootDirectory(createIfMissing: true) else {
            throw CompositionCatalogAcceptanceStoreError.insecure
        }
        return descriptor
    }

    private func openSecureRootDirectory(createIfMissing: Bool) throws -> Int32? {
        let rootName = try rootDirectoryName()
        guard let parentDescriptor = try openRootParentDirectoryIfPresent() else {
            if !createIfMissing {
                return nil
            }
            throw CompositionCatalogAcceptanceStoreError.insecure
        }
        defer { _ = Darwin.close(parentDescriptor) }

        if createIfMissing {
            let result = rootName.withCString { name in
                Darwin.mkdirat(parentDescriptor, name, mode_t(0o700))
            }
            if result != 0 && errno != EEXIST {
                throw CompositionCatalogAcceptanceStoreError.insecure
            }
        }
        let descriptor = rootName.withCString { name in
            Darwin.openat(
                parentDescriptor,
                name,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY
            )
        }
        guard descriptor >= 0 else {
            if !createIfMissing && errno == ENOENT {
                return nil
            }
            throw CompositionCatalogAcceptanceStoreError.insecure
        }
        guard isSecureDirectory(descriptor) else {
            _ = Darwin.close(descriptor)
            throw CompositionCatalogAcceptanceStoreError.insecure
        }
        if createIfMissing {
            do {
                // Synchronize even for a pre-existing root. A prior attempt
                // could have created it but failed before its parent entry was
                // made durable; no subsequent commitment may succeed until
                // both sides have been synchronized.
                try durableSynchronize(descriptor)
                try durableSynchronize(parentDescriptor)
            } catch {
                _ = Darwin.close(descriptor)
                throw error
            }
        }
        return descriptor
    }

    private func requireSecureRecordsDirectory(in rootDescriptor: Int32) throws -> Int32 {
        guard let descriptor = try openSecureRecordsDirectory(
            in: rootDescriptor,
            createIfMissing: true
        ) else {
            throw CompositionCatalogAcceptanceStoreError.insecure
        }
        return descriptor
    }

    private func openSecureRecordsDirectory(
        in rootDescriptor: Int32,
        createIfMissing: Bool
    ) throws -> Int32? {
        if createIfMissing {
            let result = Self.recordsDirectoryName.withCString { name in
                Darwin.mkdirat(rootDescriptor, name, mode_t(0o700))
            }
            if result != 0 && errno != EEXIST {
                throw CompositionCatalogAcceptanceStoreError.insecure
            }
        }
        let descriptor = Self.recordsDirectoryName.withCString { name in
            Darwin.openat(rootDescriptor, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard descriptor >= 0 else {
            if !createIfMissing && errno == ENOENT {
                return nil
            }
            throw CompositionCatalogAcceptanceStoreError.insecure
        }
        guard isSecureDirectory(descriptor) else {
            _ = Darwin.close(descriptor)
            throw CompositionCatalogAcceptanceStoreError.insecure
        }
        if createIfMissing {
            do {
                // As for the root, sync an existing directory too: this lets
                // a later retry repair a creation sequence that did not reach
                // a successful parent sync, without ever returning success
                // before the directory entry is durable.
                try durableSynchronize(descriptor)
                try durableSynchronize(rootDescriptor)
            } catch {
                _ = Darwin.close(descriptor)
                throw error
            }
        }
        return descriptor
    }

    private func withExclusiveLock<T>(
        in rootDescriptor: Int32,
        _ body: () throws -> T
    ) throws -> T {
        let lockDescriptor = try openExclusiveLockFile(in: rootDescriptor)
        var lockReleased = false
        do {
            let result = try body()
            let releaseSucceeded = releaseLock(lockDescriptor)
            lockReleased = true
            guard releaseSucceeded else {
                throw CompositionCatalogAcceptanceStoreError.insecure
            }
            return result
        } catch {
            if !lockReleased {
                _ = releaseLock(lockDescriptor)
            }
            throw error
        }
    }

    private func openExclusiveLockFile(in rootDescriptor: Int32) throws -> Int32 {
        let descriptor = Self.lockFileName.withCString { fileName in
            Darwin.openat(
                rootDescriptor,
                fileName,
                O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW_ANY | O_NONBLOCK,
                mode_t(0o600)
            )
        }
        guard descriptor >= 0 else {
            throw CompositionCatalogAcceptanceStoreError.insecure
        }
        guard isSecureRegularFile(descriptor) else {
            _ = Darwin.close(descriptor)
            throw CompositionCatalogAcceptanceStoreError.insecure
        }
        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            _ = Darwin.close(descriptor)
            throw CompositionCatalogAcceptanceStoreError.insecure
        }
        return descriptor
    }

    private func releaseLock(_ descriptor: Int32) -> Bool {
        let unlocked = flock(descriptor, LOCK_UN) == 0
        let closed = Darwin.close(descriptor) == 0
        return unlocked && closed
    }

    private func readSecureRegularFileIfPresent(
        named name: String,
        in directoryDescriptor: Int32
    ) throws -> Data? {
        let descriptor = name.withCString { fileName in
            Darwin.openat(directoryDescriptor, fileName, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY | O_NONBLOCK)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT {
                return nil
            }
            throw CompositionCatalogAcceptanceStoreError.insecure
        }
        defer { _ = Darwin.close(descriptor) }
        let initialDetails = try secureRegularFileDetails(descriptor)
        guard initialDetails.st_size > 0,
              initialDetails.st_size <= off_t(Self.maximumRecordBytes) else {
            throw CompositionCatalogAcceptanceStoreError.insecure
        }
        return try readBoundedData(
            from: descriptor,
            maximumBytes: Self.maximumRecordBytes,
            initialDetails: initialDetails
        )
    }

    private func writeAtomically(_ data: Data, named name: String, in directoryDescriptor: Int32) throws {
        guard !data.isEmpty, data.count <= Self.maximumRecordBytes else {
            throw CompositionCatalogAcceptanceStoreError.insecure
        }
        try validateExistingRegularFileIfPresent(named: name, in: directoryDescriptor)
        let temporaryName = ".\(name).tmp-\(UUID().uuidString.lowercased())"
        let descriptor = temporaryName.withCString { fileName in
            Darwin.openat(
                directoryDescriptor,
                fileName,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW_ANY,
                mode_t(0o600)
            )
        }
        guard descriptor >= 0 else {
            throw CompositionCatalogAcceptanceStoreError.insecure
        }
        var renamed = false
        defer {
            _ = Darwin.close(descriptor)
            if !renamed {
                _ = temporaryName.withCString { fileName in
                    Darwin.unlinkat(directoryDescriptor, fileName, 0)
                }
            }
        }
        guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw CompositionCatalogAcceptanceStoreError.insecure
        }
        _ = try secureRegularFileDetails(descriptor)
        try writeAll(data, to: descriptor)
        try durableSynchronize(descriptor)
        try validateExistingRegularFileIfPresent(named: name, in: directoryDescriptor)
        let renameResult = temporaryName.withCString { sourceName in
            name.withCString { destinationName in
                Darwin.renameat(directoryDescriptor, sourceName, directoryDescriptor, destinationName)
            }
        }
        guard renameResult == 0 else {
            throw CompositionCatalogAcceptanceStoreError.insecure
        }
        try durableSynchronize(directoryDescriptor)
        renamed = true
        try validateExistingRegularFileIfPresent(named: name, in: directoryDescriptor)
    }

    private func validateExistingRegularFileIfPresent(
        named name: String,
        in directoryDescriptor: Int32
    ) throws {
        let descriptor = name.withCString { fileName in
            Darwin.openat(directoryDescriptor, fileName, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY | O_NONBLOCK)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT {
                return
            }
            throw CompositionCatalogAcceptanceStoreError.insecure
        }
        defer { _ = Darwin.close(descriptor) }
        _ = try secureRegularFileDetails(descriptor)
    }

    private func isSecureDirectory(_ descriptor: Int32) -> Bool {
        var details = stat()
        guard Darwin.fstat(descriptor, &details) == 0 else {
            return false
        }
        return (details.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
            && details.st_uid == Darwin.geteuid()
            && (details.st_mode & mode_t(0o7777)) == mode_t(0o700)
    }

    private func openRootParentDirectoryIfPresent() throws -> Int32? {
        let parentDirectory = rootDirectory.deletingLastPathComponent()
        let descriptor = parentDirectory.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT {
                return nil
            }
            throw CompositionCatalogAcceptanceStoreError.insecure
        }
        guard isDirectory(descriptor) else {
            _ = Darwin.close(descriptor)
            throw CompositionCatalogAcceptanceStoreError.insecure
        }
        return descriptor
    }

    private func rootDirectoryName() throws -> String {
        let name = rootDirectory.lastPathComponent
        guard !name.isEmpty,
              name != ".",
              name != "..",
              !name.contains("/") else {
            throw CompositionCatalogAcceptanceStoreError.insecure
        }
        return name
    }

    private func isDirectory(_ descriptor: Int32) -> Bool {
        var details = stat()
        return Darwin.fstat(descriptor, &details) == 0
            && (details.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
    }

    private func durableSynchronize(_ descriptor: Int32) throws {
        guard durableSynchronizer(descriptor) else {
            throw CompositionCatalogAcceptanceStoreError.insecure
        }
    }

    private func isSecureRegularFile(_ descriptor: Int32) -> Bool {
        (try? secureRegularFileDetails(descriptor)) != nil
    }

    private func secureRegularFileDetails(_ descriptor: Int32) throws -> stat {
        var details = stat()
        guard Darwin.fstat(descriptor, &details) == 0,
              (details.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              details.st_uid == Darwin.geteuid(),
              details.st_nlink == 1,
              (details.st_mode & mode_t(0o7777)) == mode_t(0o600) else {
            throw CompositionCatalogAcceptanceStoreError.insecure
        }
        return details
    }

    private func readBoundedData(
        from descriptor: Int32,
        maximumBytes: Int,
        initialDetails: stat
    ) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count == 0 {
                break
            }
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                throw CompositionCatalogAcceptanceStoreError.insecure
            }
            data.append(contentsOf: buffer.prefix(Int(count)))
            guard data.count <= maximumBytes else {
                throw CompositionCatalogAcceptanceStoreError.insecure
            }
        }
        var finalDetails = stat()
        guard Darwin.fstat(descriptor, &finalDetails) == 0,
              finalDetails.st_dev == initialDetails.st_dev,
              finalDetails.st_ino == initialDetails.st_ino,
              finalDetails.st_size == initialDetails.st_size,
              finalDetails.st_mtimespec.tv_sec == initialDetails.st_mtimespec.tv_sec,
              finalDetails.st_mtimespec.tv_nsec == initialDetails.st_mtimespec.tv_nsec else {
            throw CompositionCatalogAcceptanceStoreError.insecure
        }
        return data
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) in
            guard let baseAddress = rawBuffer.baseAddress else {
                throw CompositionCatalogAcceptanceStoreError.insecure
            }
            var written = 0
            while written < rawBuffer.count {
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: written),
                    rawBuffer.count - written
                )
                if result < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw CompositionCatalogAcceptanceStoreError.insecure
                }
                guard result > 0 else {
                    throw CompositionCatalogAcceptanceStoreError.insecure
                }
                written += Int(result)
            }
        }
    }

    private static func recordFileName(for scope: CompositionCatalogAcceptanceScope) -> String {
        "scope-\(CompositionCatalogAcceptanceRecordValidation.scopeSHA256(scope)).json"
    }

    private static func canonicalRootDirectory(for input: URL) -> URL {
        let standardized = input.standardizedFileURL
        let parent = standardized.deletingLastPathComponent()
        let resolvedParentPath: String? = parent.withUnsafeFileSystemRepresentation { parentPath in
            guard let parentPath, let resolvedPath = Darwin.realpath(parentPath, nil) else {
                return nil
            }
            defer { Darwin.free(resolvedPath) }
            return String(cString: resolvedPath)
        }
        guard let resolvedParentPath else {
            return standardized
        }
        return URL(fileURLWithPath: resolvedParentPath, isDirectory: true)
            .appendingPathComponent(standardized.lastPathComponent, isDirectory: true)
    }
}

private enum CompositionCatalogAcceptanceStoreError: Error {
    case insecure
}

private enum CompositionCatalogAcceptanceRecordValidation {
    private static let scopeDomain = "forge-platform-installer-composition-catalog-acceptance-scope-v1"

    static func scopeSHA256(_ scope: CompositionCatalogAcceptanceScope) -> String {
        let fields = [
            scopeDomain,
            "installer_release_trust_configuration_sha256=\(scope.installerReleaseTrustConfigurationSHA256)",
            "channel=\(scope.channel.rawValue)",
            "feed_url=\(scope.feedURL)",
        ]
        return SHA256.hash(data: Data(fields.joined(separator: "\u{0}").utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func isOperationID(_ value: String) -> Bool {
        isBoundedReference(value, prefix: "operation:")
    }

    static func isReceiptReference(_ value: String) -> Bool {
        isBoundedReference(value, prefix: "receipt:")
    }

    static func isTaggedSHA256(_ value: String) -> Bool {
        guard value.utf8.count == 71, value.hasPrefix("sha256:") else {
            return false
        }
        return value.dropFirst("sha256:".count).unicodeScalars.allSatisfy { scalar in
            (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
        }
    }

    private static func isBoundedReference(_ value: String, prefix: String) -> Bool {
        guard value.hasPrefix(prefix) else {
            return false
        }
        let suffix = value.dropFirst(prefix.count)
        guard !suffix.isEmpty,
              suffix.utf8.count <= 128,
              let first = suffix.unicodeScalars.first,
              isLowercaseLetterOrDigit(first) else {
            return false
        }
        return suffix.unicodeScalars.allSatisfy { scalar in
            isLowercaseLetterOrDigit(scalar)
                || scalar.value == 45
                || scalar.value == 46
                || scalar.value == 95
        }
    }

    private static func isLowercaseLetterOrDigit(_ scalar: Unicode.Scalar) -> Bool {
        (48...57).contains(scalar.value) || (97...122).contains(scalar.value)
    }
}

private struct SerializedCommitment: Encodable {
    let schemaVersion: Int
    let scope: SerializedScope
    let catalog: SerializedCatalog
    let terminalOperation: SerializedTerminalOperation

    init(commitment: CompositionCatalogTerminalCommitment) {
        schemaVersion = 1
        scope = SerializedScope(scope: commitment.acceptance.scope)
        catalog = SerializedCatalog(identity: commitment.acceptance.identity)
        terminalOperation = SerializedTerminalOperation(commitment: commitment)
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case scope
        case catalog
        case terminalOperation = "terminal_operation"
    }
}

private struct SerializedScope: Encodable {
    let installerReleaseTrustConfigurationSHA256: String
    let channel: String
    let feedURL: String

    init(scope: CompositionCatalogAcceptanceScope) {
        installerReleaseTrustConfigurationSHA256 = scope.installerReleaseTrustConfigurationSHA256
        channel = scope.channel.rawValue
        feedURL = scope.feedURL
    }

    enum CodingKeys: String, CodingKey {
        case installerReleaseTrustConfigurationSHA256 = "installer_release_trust_configuration_sha256"
        case channel
        case feedURL = "feed_url"
    }
}

private struct SerializedCatalog: Encodable {
    let sequence: UInt64
    let sha256: String

    init(identity: VerifiedCompositionCatalogIdentity) {
        sequence = identity.sequence
        sha256 = identity.sha256
    }
}

private struct SerializedTerminalOperation: Encodable {
    let state = "COMPLETE"
    let operationID: String
    let compositionID: String
    let manifestSHA256: String
    let receiptReference: String

    init(commitment: CompositionCatalogTerminalCommitment) {
        operationID = commitment.operationID
        compositionID = commitment.compositionID
        manifestSHA256 = commitment.manifestSHA256
        receiptReference = commitment.receiptReference
    }

    enum CodingKeys: String, CodingKey {
        case state
        case operationID = "operation_id"
        case compositionID = "composition_id"
        case manifestSHA256 = "manifest_sha256"
        case receiptReference = "receipt_reference"
    }
}
