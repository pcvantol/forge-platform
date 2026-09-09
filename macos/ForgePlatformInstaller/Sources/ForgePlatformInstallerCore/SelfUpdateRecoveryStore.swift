import Foundation

/// Immutable, non-secret identity for one installer self-update operation.
/// It binds durable recovery and the handoff receipt to exact installer bytes;
/// it intentionally contains no download URL, filesystem path, command, token,
/// credential, user name, or product-component data.
public struct InstallerSelfUpdateOperationIdentity: Codable, Equatable, Sendable {
    public let operationIdentifier: String
    public let installerVersion: String
    public let releaseSequence: UInt64
    public let sourceRevision: String
    public let artifactSHA256: String
    public let expectedCodeDirectorySHA256: String
    public let metadataSHA256: String
    public let releaseTrustConfigurationSHA256: String
    public let bundleIdentifier: String
    public let teamIdentifier: String

    public init(
        operationIdentifier: String,
        installerVersion: String,
        releaseSequence: UInt64,
        sourceRevision: String,
        artifactSHA256: String,
        expectedCodeDirectorySHA256: String,
        metadataSHA256: String,
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
              InstallerSelfUpdateValidation.isSHA256(artifactSHA256),
              InstallerSelfUpdateValidation.isSHA256(expectedCodeDirectorySHA256),
              InstallerSelfUpdateValidation.isSHA256(metadataSHA256),
              InstallerSelfUpdateValidation.isSHA256(releaseTrustConfigurationSHA256),
              InstallerSelfUpdateValidation.isBundleIdentifier(bundleIdentifier),
              InstallerSelfUpdateValidation.isTeamIdentifier(teamIdentifier) else {
            throw InstallerSelfUpdateMetadataError.invalidRecoveryRecord
        }

        self.operationIdentifier = operationIdentifier
        self.installerVersion = installerVersion
        self.releaseSequence = releaseSequence
        self.sourceRevision = sourceRevision
        self.artifactSHA256 = artifactSHA256
        self.expectedCodeDirectorySHA256 = expectedCodeDirectorySHA256
        self.metadataSHA256 = metadataSHA256
        self.releaseTrustConfigurationSHA256 = releaseTrustConfigurationSHA256
        self.bundleIdentifier = bundleIdentifier
        self.teamIdentifier = teamIdentifier
    }

    public init(release: VerifiedInstallerReleaseRecord, operationIdentifier: String = UUID().uuidString.lowercased()) throws {
        try self.init(
            operationIdentifier: operationIdentifier,
            installerVersion: release.release.version.description,
            releaseSequence: release.sequence,
            sourceRevision: release.sourceRevision,
            artifactSHA256: release.release.sha256,
            expectedCodeDirectorySHA256: release.expectedCodeDirectorySHA256,
            metadataSHA256: release.metadataSHA256,
            releaseTrustConfigurationSHA256: release.expectedReleaseTrustConfigurationSHA256,
            bundleIdentifier: release.expectedBundleIdentifier,
            teamIdentifier: release.expectedTeamIdentifier
        )
    }

    public func matches(_ release: VerifiedInstallerReleaseRecord) -> Bool {
        installerVersion == release.release.version.description
            && releaseSequence == release.sequence
            && sourceRevision == release.sourceRevision
            && artifactSHA256 == release.release.sha256
            && expectedCodeDirectorySHA256 == release.expectedCodeDirectorySHA256
            && metadataSHA256 == release.metadataSHA256
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

/// File-backed recovery implementation for a released macOS app.  The caller
/// supplies an installer-owned directory; this type never derives it from PATH,
/// a product data root, or user input.  It uses atomic JSON replacement and
/// restrictive permissions.  The payload is intentionally non-secret.
public struct FileInstallerSelfUpdateRecoveryStore: InstallerSelfUpdateRecoveryStoring {
    private let rootDirectory: URL

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory.standardizedFileURL
    }

    public func loadPendingSelfUpdate() async -> Result<InstallerSelfUpdateRecoveryRecord?, InstallerSelfUpdateFailure> {
        do {
            let manager = FileManager.default
            let pendingURL = pendingRecordURL
            guard manager.fileExists(atPath: pendingURL.path) else {
                return .success(nil)
            }
            let data = try Data(contentsOf: pendingURL)
            let decodedRecord = try JSONDecoder().decode(InstallerSelfUpdateRecoveryRecord.self, from: data)
            let record = try decodedRecord.validatingCopy()

            // Receipt-first recovery makes a crash after receipt persistence but
            // before pending-record removal safe: do not clean an activated asset.
            let completedReceiptURL = receiptURL(for: record.operation)
            if manager.fileExists(atPath: completedReceiptURL.path) {
                let receiptData = try Data(contentsOf: completedReceiptURL)
                let decodedReceipt = try JSONDecoder().decode(InstallerSelfUpdateHandoffReceipt.self, from: receiptData)
                let receipt = try decodedReceipt.validatingCopy()
                guard receipt.isValid(for: record.operation) else {
                    throw InstallerSelfUpdateMetadataError.invalidRecoveryRecord
                }
                try manager.removeItem(at: pendingURL)
                return .success(nil)
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
            try ensureDirectories()
            let validatedRecord = try record.validatingCopy()
            let data = try encoded(validatedRecord)
            try writeAtomically(data, to: pendingRecordURL)
            return .success(())
        } catch {
            return .failure(InstallerSelfUpdateFailure(.recoveryPersistenceFailed))
        }
    }

    public func clearPendingSelfUpdate(
        for operation: InstallerSelfUpdateOperationIdentity
    ) async -> Result<Void, InstallerSelfUpdateFailure> {
        do {
            let manager = FileManager.default
            guard manager.fileExists(atPath: pendingRecordURL.path) else {
                return .success(())
            }
            let data = try Data(contentsOf: pendingRecordURL)
            let decodedCurrent = try JSONDecoder().decode(InstallerSelfUpdateRecoveryRecord.self, from: data)
            let current = try decodedCurrent.validatingCopy()
            guard current.operation == operation else {
                return .failure(InstallerSelfUpdateFailure(.recoveryPersistenceFailed))
            }
            try manager.removeItem(at: pendingRecordURL)
            return .success(())
        } catch {
            return .failure(InstallerSelfUpdateFailure(.recoveryPersistenceFailed))
        }
    }

    public func persistHandoffReceipt(
        _ receipt: InstallerSelfUpdateHandoffReceipt
    ) async -> Result<Void, InstallerSelfUpdateFailure> {
        do {
            try ensureDirectories()
            let validatedReceipt = try receipt.validatingCopy()
            let data = try encoded(validatedReceipt)
            try writeAtomically(data, to: receiptURL(for: validatedReceipt.operation))
            return .success(())
        } catch {
            return .failure(InstallerSelfUpdateFailure(.recoveryPersistenceFailed))
        }
    }

    private var pendingRecordURL: URL {
        rootDirectory.appendingPathComponent("pending-installer-self-update.json", isDirectory: false)
    }

    private var receiptsDirectoryURL: URL {
        rootDirectory.appendingPathComponent("handoff-receipts", isDirectory: true)
    }

    private func receiptURL(for operation: InstallerSelfUpdateOperationIdentity) -> URL {
        receiptsDirectoryURL.appendingPathComponent("\(operation.operationIdentifier).json", isDirectory: false)
    }

    private func ensureDirectories() throws {
        let manager = FileManager.default
        try manager.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try manager.createDirectory(
            at: receiptsDirectoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private func writeAtomically(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

private extension InstallerSelfUpdateOperationIdentity {
    func validatingCopy() throws -> InstallerSelfUpdateOperationIdentity {
        try InstallerSelfUpdateOperationIdentity(
            operationIdentifier: operationIdentifier,
            installerVersion: installerVersion,
            releaseSequence: releaseSequence,
            sourceRevision: sourceRevision,
            artifactSHA256: artifactSHA256,
            expectedCodeDirectorySHA256: expectedCodeDirectorySHA256,
            metadataSHA256: metadataSHA256,
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
