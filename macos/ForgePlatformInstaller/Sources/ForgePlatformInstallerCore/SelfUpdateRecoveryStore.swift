import Foundation
import Darwin

/// Immutable, non-secret identity for one installer self-update operation.
/// It binds durable recovery and the handoff receipt to exact installer bytes;
/// it intentionally contains no download URL, filesystem path, command, token,
/// credential, user name, or product-component data.
public struct InstallerSelfUpdateOperationIdentity: Codable, Equatable, Sendable {
    public let operationIdentifier: String
    public let installerVersion: String
    public let releaseSequence: UInt64
    public let channel: InstallerReleaseChannel
    public let sourceRevision: String
    public let policyRevision: String
    public let capabilities: [String]
    public let artifactSHA256: String
    public let expectedCodeDirectorySHA256: String
    public let provenanceSHA256: String
    public let releaseTrustConfigurationSHA256: String
    public let bundleIdentifier: String
    public let teamIdentifier: String

    public init(
        operationIdentifier: String,
        installerVersion: String,
        releaseSequence: UInt64,
        channel: InstallerReleaseChannel,
        sourceRevision: String,
        policyRevision: String,
        capabilities: [String],
        artifactSHA256: String,
        expectedCodeDirectorySHA256: String,
        provenanceSHA256: String,
        releaseTrustConfigurationSHA256: String,
        bundleIdentifier: String,
        teamIdentifier: String
    ) throws {
        guard InstallerSelfUpdateValidation.isOpaqueReference(operationIdentifier) else {
            throw InstallerSelfUpdateMetadataError.invalidOperationIdentifier(operationIdentifier)
        }
        _ = try InstallerVersion(installerVersion)
        guard releaseSequence > 0,
              InstallerSelfUpdateValidation.isGitRevision(sourceRevision),
              InstallerSelfUpdateValidation.isPublicProvenanceIdentifier(policyRevision),
              InstallerSelfUpdateValidation.hasStrictlyAscendingUniqueProvenanceIdentifiers(capabilities),
              InstallerSelfUpdateValidation.isSHA256(artifactSHA256),
              InstallerSelfUpdateValidation.isSHA256(expectedCodeDirectorySHA256),
              InstallerSelfUpdateValidation.isSHA256(provenanceSHA256),
              InstallerSelfUpdateValidation.isSHA256(releaseTrustConfigurationSHA256),
              InstallerSelfUpdateValidation.isBundleIdentifier(bundleIdentifier),
              InstallerSelfUpdateValidation.isTeamIdentifier(teamIdentifier) else {
            throw InstallerSelfUpdateMetadataError.invalidRecoveryRecord
        }

        self.operationIdentifier = operationIdentifier
        self.installerVersion = installerVersion
        self.releaseSequence = releaseSequence
        self.channel = channel
        self.sourceRevision = sourceRevision
        self.policyRevision = policyRevision
        self.capabilities = capabilities
        self.artifactSHA256 = artifactSHA256
        self.expectedCodeDirectorySHA256 = expectedCodeDirectorySHA256
        self.provenanceSHA256 = provenanceSHA256
        self.releaseTrustConfigurationSHA256 = releaseTrustConfigurationSHA256
        self.bundleIdentifier = bundleIdentifier
        self.teamIdentifier = teamIdentifier
    }

    public init(release: VerifiedInstallerReleaseRecord, operationIdentifier: String = UUID().uuidString.lowercased()) throws {
        try self.init(
            operationIdentifier: operationIdentifier,
            installerVersion: release.release.version.description,
            releaseSequence: release.sequence,
            channel: release.channel,
            sourceRevision: release.sourceRevision,
            policyRevision: release.provenanceExpectation.policyRevision,
            capabilities: release.provenanceExpectation.capabilities,
            artifactSHA256: release.release.sha256,
            expectedCodeDirectorySHA256: release.expectedCodeDirectorySHA256,
            provenanceSHA256: release.provenanceSHA256,
            releaseTrustConfigurationSHA256: release.expectedReleaseTrustConfigurationSHA256,
            bundleIdentifier: release.expectedBundleIdentifier,
            teamIdentifier: release.expectedTeamIdentifier
        )
    }

    public func matches(_ release: VerifiedInstallerReleaseRecord) -> Bool {
        installerVersion == release.release.version.description
            && releaseSequence == release.sequence
            && channel == release.channel
            && sourceRevision == release.sourceRevision
            && policyRevision == release.provenanceExpectation.policyRevision
            && capabilities == release.provenanceExpectation.capabilities
            && artifactSHA256 == release.release.sha256
            && expectedCodeDirectorySHA256 == release.expectedCodeDirectorySHA256
            && provenanceSHA256 == release.provenanceSHA256
            && releaseTrustConfigurationSHA256 == release.expectedReleaseTrustConfigurationSHA256
            && bundleIdentifier == release.expectedBundleIdentifier
            && teamIdentifier == release.expectedTeamIdentifier
    }
}

public enum InstallerSelfUpdateRecoveryPhase: String, Codable, Equatable, Sendable {
    case updateRequired = "UPDATE_REQUIRED"
    case stagedForVerification = "STAGED_FOR_VERIFICATION"
    case verifiedForHandoff = "VERIFIED_FOR_HANDOFF"
    /// Written immediately before invoking the atomic swap. A restart cannot
    /// know whether activation happened, so it must stop rather than delete a
    /// potentially activated asset.
    case handoffAttempting = "HANDOFF_ATTEMPTING"
    case cleanupPending = "CLEANUP_PENDING"
    /// The atomic handoff may already have activated a replacement.  Recovery
    /// must not delete its staged asset until a product-specific resolver can
    /// reconcile the missing receipt.
    case handoffReceiptPending = "HANDOFF_RECEIPT_PENDING"
}

/// The resumable part of an installer-only operation.  A record with a staged
/// asset is enough to clean a crash-interrupted download without retaining any
/// location or credential.  Receipt-pending deliberately carries no asset so a
/// successful atomic activation is never mistaken for an abandoned download.
public struct InstallerSelfUpdateRecoveryRecord: Codable, Equatable, Sendable {
    public let operation: InstallerSelfUpdateOperationIdentity
    public let phase: InstallerSelfUpdateRecoveryPhase
    public let stagedAsset: StagedInstallerAsset?

    public init(
        operation: InstallerSelfUpdateOperationIdentity,
        phase: InstallerSelfUpdateRecoveryPhase,
        stagedAsset: StagedInstallerAsset? = nil
    ) throws {
        switch phase {
        case .updateRequired, .handoffAttempting, .handoffReceiptPending:
            guard stagedAsset == nil else {
                throw InstallerSelfUpdateMetadataError.invalidRecoveryRecord
            }
        case .stagedForVerification, .verifiedForHandoff, .cleanupPending:
            guard stagedAsset != nil else {
                throw InstallerSelfUpdateMetadataError.invalidRecoveryRecord
            }
        }
        self.operation = operation
        self.phase = phase
        self.stagedAsset = stagedAsset
    }
}

/// Durable evidence from an atomic handoff.  A successful result is accepted
/// only when this receipt echoes the exact operation and expected code identity.
public struct InstallerSelfUpdateHandoffReceipt: Codable, Equatable, Sendable {
    public let operation: InstallerSelfUpdateOperationIdentity
    public let handoffReference: String
    public let activatedCodeDirectorySHA256: String

    public init(
        operation: InstallerSelfUpdateOperationIdentity,
        handoffReference: String,
        activatedCodeDirectorySHA256: String
    ) throws {
        guard InstallerSelfUpdateValidation.isOpaqueReference(handoffReference),
              InstallerSelfUpdateValidation.isSHA256(activatedCodeDirectorySHA256) else {
            throw InstallerSelfUpdateMetadataError.invalidRecoveryRecord
        }
        self.operation = operation
        self.handoffReference = handoffReference
        self.activatedCodeDirectorySHA256 = activatedCodeDirectorySHA256
    }

    public func isValid(for operation: InstallerSelfUpdateOperationIdentity) -> Bool {
        self.operation == operation
            && activatedCodeDirectorySHA256 == operation.expectedCodeDirectorySHA256
    }
}

/// Persistent state belongs to the installer itself, outside product CENTRAL or
/// component datastores.  It stores only typed recovery identities and receipts.
public protocol InstallerSelfUpdateRecoveryStoring: Sendable {
    func loadPendingSelfUpdate() async -> Result<InstallerSelfUpdateRecoveryRecord?, InstallerSelfUpdateFailure>

    func savePendingSelfUpdate(
        _ record: InstallerSelfUpdateRecoveryRecord
    ) async -> Result<Void, InstallerSelfUpdateFailure>

    func clearPendingSelfUpdate(
        for operation: InstallerSelfUpdateOperationIdentity
    ) async -> Result<Void, InstallerSelfUpdateFailure>

    func persistHandoffReceipt(
        _ receipt: InstallerSelfUpdateHandoffReceipt
    ) async -> Result<Void, InstallerSelfUpdateFailure>
}

/// File-backed recovery implementation for a released macOS app. The caller
/// supplies one installer-owned state root; it is never derived from PATH, a
/// product data root, or user input. Every root, child directory and record is
/// opened through a descriptor without following a final symlink, then checked
/// for effective-owner and private-mode invariants before it is read, replaced
/// or removed. The payload itself is intentionally non-secret, but its
/// integrity is required for fail-closed reboot recovery.
public struct FileInstallerSelfUpdateRecoveryStore: InstallerSelfUpdateRecoveryStoring {
    private static let pendingRecordFileName = "pending-installer-self-update.json"
    private static let receiptsDirectoryName = "handoff-receipts"
    private static let maximumRecordBytes = 256 * 1024

    private let rootDirectory: URL

    public init(rootDirectory: URL) {
        self.rootDirectory = Self.canonicalRootDirectory(for: rootDirectory)
    }

    public func loadPendingSelfUpdate() async -> Result<InstallerSelfUpdateRecoveryRecord?, InstallerSelfUpdateFailure> {
        do {
            guard let rootDescriptor = try openSecureRootDirectory(createIfMissing: false) else {
                return .success(nil)
            }
            defer { _ = Darwin.close(rootDescriptor) }
            guard let data = try readSecureRegularFileIfPresent(
                named: Self.pendingRecordFileName,
                in: rootDescriptor
            ) else {
                return .success(nil)
            }
            let decodedRecord = try JSONDecoder().decode(InstallerSelfUpdateRecoveryRecord.self, from: data)
            let record = try decodedRecord.validatingCopy()

            // Receipt-first recovery makes a crash after receipt persistence but
            // before pending-record removal safe: do not clean an activated asset.
            if let receiptsDescriptor = try openSecureReceiptsDirectory(
                in: rootDescriptor,
                createIfMissing: false
            ) {
                defer { _ = Darwin.close(receiptsDescriptor) }
                if let receiptData = try readSecureRegularFileIfPresent(
                    named: receiptFileName(for: record.operation),
                    in: receiptsDescriptor
                ) {
                let decodedReceipt = try JSONDecoder().decode(InstallerSelfUpdateHandoffReceipt.self, from: receiptData)
                let receipt = try decodedReceipt.validatingCopy()
                guard receipt.isValid(for: record.operation) else {
                    throw InstallerSelfUpdateMetadataError.invalidRecoveryRecord
                }
                    try removeSecureRegularFile(named: Self.pendingRecordFileName, in: rootDescriptor)
                    return .success(nil)
                }
            }
            return .success(record)
        } catch {
            return .failure(InstallerSelfUpdateFailure(.recoveryLoadFailed))
        }
    }

    public func savePendingSelfUpdate(
        _ record: InstallerSelfUpdateRecoveryRecord
    ) async -> Result<Void, InstallerSelfUpdateFailure> {
        do {
            let validatedRecord = try record.validatingCopy()
            let data = try encoded(validatedRecord)
            let rootDescriptor = try requireSecureRootDirectory()
            defer { _ = Darwin.close(rootDescriptor) }
            try writeAtomically(
                data,
                named: Self.pendingRecordFileName,
                in: rootDescriptor
            )
            return .success(())
        } catch {
            return .failure(InstallerSelfUpdateFailure(.recoveryPersistenceFailed))
        }
    }

    public func clearPendingSelfUpdate(
        for operation: InstallerSelfUpdateOperationIdentity
    ) async -> Result<Void, InstallerSelfUpdateFailure> {
        do {
            guard let rootDescriptor = try openSecureRootDirectory(createIfMissing: false) else {
                return .success(())
            }
            defer { _ = Darwin.close(rootDescriptor) }
            guard let data = try readSecureRegularFileIfPresent(
                named: Self.pendingRecordFileName,
                in: rootDescriptor
            ) else {
                return .success(())
            }
            let decodedCurrent = try JSONDecoder().decode(InstallerSelfUpdateRecoveryRecord.self, from: data)
            let current = try decodedCurrent.validatingCopy()
            guard current.operation == operation else {
                return .failure(InstallerSelfUpdateFailure(.recoveryPersistenceFailed))
            }
            try removeSecureRegularFile(named: Self.pendingRecordFileName, in: rootDescriptor)
            return .success(())
        } catch {
            return .failure(InstallerSelfUpdateFailure(.recoveryPersistenceFailed))
        }
    }

    public func persistHandoffReceipt(
        _ receipt: InstallerSelfUpdateHandoffReceipt
    ) async -> Result<Void, InstallerSelfUpdateFailure> {
        do {
            let validatedReceipt = try receipt.validatingCopy()
            let data = try encoded(validatedReceipt)
            let rootDescriptor = try requireSecureRootDirectory()
            defer { _ = Darwin.close(rootDescriptor) }
            let receiptsDescriptor = try requireSecureReceiptsDirectory(in: rootDescriptor)
            defer { _ = Darwin.close(receiptsDescriptor) }
            try writeAtomically(
                data,
                named: receiptFileName(for: validatedReceipt.operation),
                in: receiptsDescriptor
            )
            return .success(())
        } catch {
            return .failure(InstallerSelfUpdateFailure(.recoveryPersistenceFailed))
        }
    }

    private func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard !data.isEmpty, data.count <= Self.maximumRecordBytes else {
            throw FileInstallerSelfUpdateRecoveryStoreError.insecure
        }
        return data
    }

    private func receiptFileName(for operation: InstallerSelfUpdateOperationIdentity) -> String {
        "\(operation.operationIdentifier).json"
    }

    private func requireSecureRootDirectory() throws -> Int32 {
        guard let descriptor = try openSecureRootDirectory(createIfMissing: true) else {
            throw FileInstallerSelfUpdateRecoveryStoreError.insecure
        }
        return descriptor
    }

    private func openSecureRootDirectory(createIfMissing: Bool) throws -> Int32? {
        if createIfMissing {
            let result = rootDirectory.withUnsafeFileSystemRepresentation { path -> Int32 in
                guard let path else { return -1 }
                return Darwin.mkdir(path, mode_t(0o700))
            }
            if result != 0 && errno != EEXIST {
                throw FileInstallerSelfUpdateRecoveryStoreError.insecure
            }
        }
        let descriptor = rootDirectory.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard descriptor >= 0 else {
            if !createIfMissing && errno == ENOENT {
                return nil
            }
            throw FileInstallerSelfUpdateRecoveryStoreError.insecure
        }
        guard isSecureDirectory(descriptor) else {
            _ = Darwin.close(descriptor)
            throw FileInstallerSelfUpdateRecoveryStoreError.insecure
        }
        return descriptor
    }

    private func requireSecureReceiptsDirectory(in rootDescriptor: Int32) throws -> Int32 {
        guard let descriptor = try openSecureReceiptsDirectory(
            in: rootDescriptor,
            createIfMissing: true
        ) else {
            throw FileInstallerSelfUpdateRecoveryStoreError.insecure
        }
        return descriptor
    }

    private func openSecureReceiptsDirectory(
        in rootDescriptor: Int32,
        createIfMissing: Bool
    ) throws -> Int32? {
        if createIfMissing {
            let result = Self.receiptsDirectoryName.withCString { name in
                Darwin.mkdirat(rootDescriptor, name, mode_t(0o700))
            }
            if result != 0 && errno != EEXIST {
                throw FileInstallerSelfUpdateRecoveryStoreError.insecure
            }
        }
        let descriptor = Self.receiptsDirectoryName.withCString { name in
            Darwin.openat(rootDescriptor, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard descriptor >= 0 else {
            if !createIfMissing && errno == ENOENT {
                return nil
            }
            throw FileInstallerSelfUpdateRecoveryStoreError.insecure
        }
        guard isSecureDirectory(descriptor) else {
            _ = Darwin.close(descriptor)
            throw FileInstallerSelfUpdateRecoveryStoreError.insecure
        }
        return descriptor
    }

    private func readSecureRegularFileIfPresent(named name: String, in directoryDescriptor: Int32) throws -> Data? {
        let descriptor = name.withCString { fileName in
            Darwin.openat(directoryDescriptor, fileName, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT {
                return nil
            }
            throw FileInstallerSelfUpdateRecoveryStoreError.insecure
        }
        defer { _ = Darwin.close(descriptor) }
        let initialDetails = try secureRegularFileDetails(descriptor)
        guard initialDetails.st_size > 0,
              initialDetails.st_size <= off_t(Self.maximumRecordBytes) else {
            throw FileInstallerSelfUpdateRecoveryStoreError.insecure
        }
        let data = try readBoundedData(
            from: descriptor,
            maximumBytes: Self.maximumRecordBytes,
            initialDetails: initialDetails
        )
        return data
    }

    private func writeAtomically(_ data: Data, named name: String, in directoryDescriptor: Int32) throws {
        guard !data.isEmpty, data.count <= Self.maximumRecordBytes else {
            throw FileInstallerSelfUpdateRecoveryStoreError.insecure
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
            throw FileInstallerSelfUpdateRecoveryStoreError.insecure
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
        _ = try secureRegularFileDetails(descriptor)
        try writeAll(data, to: descriptor)
        guard Darwin.fsync(descriptor) == 0 else {
            throw FileInstallerSelfUpdateRecoveryStoreError.insecure
        }
        try validateExistingRegularFileIfPresent(named: name, in: directoryDescriptor)
        let renameResult = temporaryName.withCString { sourceName in
            name.withCString { destinationName in
                Darwin.renameat(directoryDescriptor, sourceName, directoryDescriptor, destinationName)
            }
        }
        guard renameResult == 0, Darwin.fsync(directoryDescriptor) == 0 else {
            throw FileInstallerSelfUpdateRecoveryStoreError.insecure
        }
        renamed = true
        try validateExistingRegularFileIfPresent(named: name, in: directoryDescriptor)
    }

    private func removeSecureRegularFile(named name: String, in directoryDescriptor: Int32) throws {
        try validateExistingRegularFileIfPresent(named: name, in: directoryDescriptor)
        let result = name.withCString { fileName in
            Darwin.unlinkat(directoryDescriptor, fileName, 0)
        }
        guard result == 0, Darwin.fsync(directoryDescriptor) == 0 else {
            throw FileInstallerSelfUpdateRecoveryStoreError.insecure
        }
    }

    private func validateExistingRegularFileIfPresent(named name: String, in directoryDescriptor: Int32) throws {
        let descriptor = name.withCString { fileName in
            Darwin.openat(directoryDescriptor, fileName, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT {
                return
            }
            throw FileInstallerSelfUpdateRecoveryStoreError.insecure
        }
        defer { _ = Darwin.close(descriptor) }
        _ = try secureRegularFileDetails(descriptor)
    }

    private func secureRegularFileDetails(_ descriptor: Int32) throws -> stat {
        var details = stat()
        guard Darwin.fstat(descriptor, &details) == 0,
              (details.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              details.st_uid == Darwin.geteuid(),
              details.st_nlink == 1,
              (details.st_mode & mode_t(0o7777)) == mode_t(0o600) else {
            throw FileInstallerSelfUpdateRecoveryStoreError.insecure
        }
        return details
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
                throw FileInstallerSelfUpdateRecoveryStoreError.insecure
            }
            data.append(contentsOf: buffer.prefix(Int(count)))
            guard data.count <= maximumBytes else {
                throw FileInstallerSelfUpdateRecoveryStoreError.insecure
            }
        }
        var finalDetails = stat()
        guard Darwin.fstat(descriptor, &finalDetails) == 0,
              finalDetails.st_dev == initialDetails.st_dev,
              finalDetails.st_ino == initialDetails.st_ino,
              finalDetails.st_size == initialDetails.st_size,
              finalDetails.st_mtimespec.tv_sec == initialDetails.st_mtimespec.tv_sec,
              finalDetails.st_mtimespec.tv_nsec == initialDetails.st_mtimespec.tv_nsec else {
            throw FileInstallerSelfUpdateRecoveryStoreError.insecure
        }
        return data
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) in
            guard let baseAddress = rawBuffer.baseAddress else {
                throw FileInstallerSelfUpdateRecoveryStoreError.insecure
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
                    throw FileInstallerSelfUpdateRecoveryStoreError.insecure
                }
                guard result > 0 else {
                    throw FileInstallerSelfUpdateRecoveryStoreError.insecure
                }
                written += Int(result)
            }
        }
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

private enum FileInstallerSelfUpdateRecoveryStoreError: Error {
    case insecure
}

private extension InstallerSelfUpdateOperationIdentity {
    func validatingCopy() throws -> InstallerSelfUpdateOperationIdentity {
        try InstallerSelfUpdateOperationIdentity(
            operationIdentifier: operationIdentifier,
            installerVersion: installerVersion,
            releaseSequence: releaseSequence,
            channel: channel,
            sourceRevision: sourceRevision,
            policyRevision: policyRevision,
            capabilities: capabilities,
            artifactSHA256: artifactSHA256,
            expectedCodeDirectorySHA256: expectedCodeDirectorySHA256,
            provenanceSHA256: provenanceSHA256,
            releaseTrustConfigurationSHA256: releaseTrustConfigurationSHA256,
            bundleIdentifier: bundleIdentifier,
            teamIdentifier: teamIdentifier
        )
    }
}

private extension StagedInstallerFileIdentity {
    func validatingCopy() throws -> StagedInstallerFileIdentity {
        try StagedInstallerFileIdentity(
            volumeReference: volumeReference,
            fileReference: fileReference,
            byteCount: byteCount
        )
    }
}

private extension StagedInstallerAsset {
    func validatingCopy() throws -> StagedInstallerAsset {
        try StagedInstallerAsset(
            releaseAssetName: releaseAssetName,
            opaqueReference: opaqueReference,
            fileIdentity: try fileIdentity.validatingCopy()
        )
    }
}

private extension InstallerSelfUpdateRecoveryRecord {
    func validatingCopy() throws -> InstallerSelfUpdateRecoveryRecord {
        try InstallerSelfUpdateRecoveryRecord(
            operation: try operation.validatingCopy(),
            phase: phase,
            stagedAsset: try stagedAsset?.validatingCopy()
        )
    }
}

private extension InstallerSelfUpdateHandoffReceipt {
    func validatingCopy() throws -> InstallerSelfUpdateHandoffReceipt {
        try InstallerSelfUpdateHandoffReceipt(
            operation: try operation.validatingCopy(),
            handoffReference: handoffReference,
            activatedCodeDirectorySHA256: activatedCodeDirectorySHA256
        )
    }
}
