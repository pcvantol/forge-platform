import Darwin
import Foundation

/// Exact archive bytes returned by an archive downloader.  The downloader is
/// intentionally addressed only by the already verified GitHub Release asset
/// identity; it has no URL, redirect target, command, credential or product
/// installation input.  A concrete downloader must enforce the supplied
/// byte-bound while it receives the response.  The stager repeats that bound
/// before any byte reaches the filesystem, so an incorrect downloader cannot
/// make an unbounded archive durable.
public struct GitHubInstallerReleaseArchiveReadback: Sendable {
    public let githubAsset: GitHubInstallerReleaseAsset
    public let bytes: Data

    public init(githubAsset: GitHubInstallerReleaseAsset, bytes: Data) {
        self.githubAsset = githubAsset
        self.bytes = bytes
    }
}

/// The only archive-download seam accepted by the native stager.  Unlike a
/// general HTTP client, it cannot be asked to fetch an arbitrary URL or a
/// caller-chosen path.  Production transport is deliberately not assembled by
/// this foundation; tests inject a deterministic implementation.
public protocol GitHubInstallerReleaseArchiveDownloading: Sendable {
    func downloadInstallerReleaseArchive(
        for githubAsset: GitHubInstallerReleaseAsset,
        maximumBytes: Int
    ) async -> Result<GitHubInstallerReleaseArchiveReadback, InstallerSelfUpdateFailure>
}

/// Read-only seam for the later, trusted archive verifier and atomic handoff.
/// It resolves only an existing opaque staged-asset reference to the stager's
/// private archive URL after re-checking the private directory chain and the
/// captured file identity.  It is not available to the wizard UI and it never
/// accepts a URL, command or user-selected path as input.
///
/// The returned URL is an archive only.  This source increment intentionally
/// has no archive extractor, app-bundle verifier or handoff implementation;
/// callers must re-inspect identity around every sensitive use until a
/// descriptor-based archive verifier is introduced.
public protocol MacOSInstallerArchiveStagingResolving: Sendable {
    func resolveStagedInstallerArchive(
        _ stagedAsset: StagedInstallerAsset
    ) async -> Result<URL, InstallerSelfUpdateFailure>
}

/// Bounded, private staging for exactly one signed-feed-selected installer
/// archive.  It is deliberately not a product installer, component downloader,
/// archive extractor, code-signature verifier or atomic handoff implementation.
///
/// `stateRoot` is selected by trusted packaged-runtime assembly, never by the
/// wizard or a product component.  It is kept outside product stores and is
/// accepted only when it is owned by the effective user and has exact private
/// permissions.  The initializer permits an injected root solely so a later
/// release runtime can choose its installer-owned location and focused tests
/// can exercise the filesystem boundary.
public struct MacOSInstallerArchiveStaging: InstallerUpdateStaging, MacOSInstallerArchiveStagingResolving {
    /// A release archive may be substantial, but it must remain bounded before
    /// it is accepted into durable installer-owned state.
    public static let defaultMaximumArchiveBytes = 512 * 1024 * 1024
    public static let absoluteMaximumArchiveBytes = 1024 * 1024 * 1024

    /// Kept internal so tests can assert the state-layout contract without
    /// granting another caller an arbitrary path selection mechanism.
    static let stagingDirectoryName = "installer-update-archives-v1"

    private static let archiveFileName = "installer-update.zip"
    private static let opaqueReferencePrefix = "forge-platform-installer-archive-v1"
    private static let maximumOpaqueReferenceLength = 256

    private let stateRoot: URL
    private let downloader: any GitHubInstallerReleaseArchiveDownloading
    private let maximumArchiveBytes: Int

    public init(
        stateRoot: URL,
        downloader: any GitHubInstallerReleaseArchiveDownloading,
        maximumArchiveBytes: Int = MacOSInstallerArchiveStaging.defaultMaximumArchiveBytes
    ) throws {
        guard maximumArchiveBytes > 0,
              maximumArchiveBytes <= Self.absoluteMaximumArchiveBytes else {
            throw MacOSInstallerArchiveStagingConfigurationError.invalidMaximumArchiveBytes
        }
        self.stateRoot = Self.canonicalStateRoot(for: stateRoot)
        self.downloader = downloader
        self.maximumArchiveBytes = maximumArchiveBytes
    }

    /// Creates a single randomly named private operation directory, writes the
    /// exact requested archive as `installer-update.zip`, and returns only an
    /// opaque reference plus descriptor-derived file identity.  The archive is
    /// never unpacked here: invoking shell tools or `ditto` on an untrusted zip
    /// would exceed the safety proof of this staging increment.
    public func stageInstallerUpdate(
        for release: VerifiedInstallerReleaseRecord
    ) async -> Result<StagedInstallerAsset, InstallerSelfUpdateFailure> {
        // Validate the destination before receiving bytes.  This avoids
        // accepting a release archive if the installer-owned state boundary is
        // already symlinked, foreign-owned or permissive.
        do {
            try preflightSecureStateRoot()
        } catch {
            return .failure(InstallerSelfUpdateFailure(.stagingFailed))
        }

        let expectedAsset = release.githubAsset
        let downloadResult = await downloader.downloadInstallerReleaseArchive(
            for: expectedAsset,
            maximumBytes: maximumArchiveBytes
        )
        let readback: GitHubInstallerReleaseArchiveReadback
        switch downloadResult {
        case .success(let received):
            readback = received
        case .failure:
            return .failure(InstallerSelfUpdateFailure(.stagingFailed))
        }
        guard readback.githubAsset == expectedAsset,
              !readback.bytes.isEmpty,
              readback.bytes.count <= maximumArchiveBytes else {
            return .failure(InstallerSelfUpdateFailure(.stagingFailed))
        }

        do {
            let rootDescriptor = try requireSecureStateRootDirectory()
            defer { _ = Darwin.close(rootDescriptor) }
            let stagingDescriptor = try requireSecureStagingDirectory(in: rootDescriptor)
            defer { _ = Darwin.close(stagingDescriptor) }
            let operation = try createPrivateOperationDirectory(
                forReleaseAssetName: expectedAsset.assetName,
                in: stagingDescriptor
            )
            defer { _ = Darwin.close(operation.descriptor) }

            do {
                let identity = try writeArchive(
                    readback.bytes,
                    to: operation.descriptor
                )
                let stagedAsset = try StagedInstallerAsset(
                    releaseAssetName: expectedAsset.assetName,
                    opaqueReference: operation.opaqueReference,
                    fileIdentity: identity
                )
                return .success(stagedAsset)
            } catch {
                do {
                    try removeOperationDirectory(
                        named: operation.directoryName,
                        descriptor: operation.descriptor,
                        initialDetails: operation.details,
                        from: stagingDescriptor,
                        archiveMayBeAbsent: true
                    )
                    return .failure(InstallerSelfUpdateFailure(.stagingFailed))
                } catch {
                    return .failure(InstallerSelfUpdateFailure(.stagingCleanupFailed))
                }
            }
        } catch {
            return .failure(InstallerSelfUpdateFailure(.stagingFailed))
        }
    }

    /// Deletes only the fixed archive name inside an operation directory that
    /// is derived from a canonical opaque reference.  It never recursively
    /// removes a caller path, follows a symlink, or removes a directory whose
    /// identity changed while it was open.  A tampered/symlinked archive is
    /// therefore visible as `CLEANUP_PENDING` through the caller's existing
    /// recovery path rather than being followed or silently erased.
    public func discardStagedInstallerUpdate(
        _ stagedAsset: StagedInstallerAsset
    ) async -> Result<Void, InstallerSelfUpdateFailure> {
        do {
            let reference = try validateReference(for: stagedAsset)
            guard let rootDescriptor = try openSecureStateRootDirectory(createIfMissing: false) else {
                throw MacOSInstallerArchiveStagingError.insecureFilesystem
            }
            defer { _ = Darwin.close(rootDescriptor) }
            guard let stagingDescriptor = try openSecureDirectory(
                named: Self.stagingDirectoryName,
                in: rootDescriptor,
                createIfMissing: false
            ) else {
                throw MacOSInstallerArchiveStagingError.insecureFilesystem
            }
            defer { _ = Darwin.close(stagingDescriptor) }
            guard let operationDescriptor = try openSecureDirectory(
                named: reference.directoryName,
                in: stagingDescriptor,
                createIfMissing: false
            ) else {
                throw MacOSInstallerArchiveStagingError.insecureFilesystem
            }
            defer { _ = Darwin.close(operationDescriptor) }
            let operationDetails = try secureDirectoryDetails(operationDescriptor)
            try removeOperationDirectory(
                named: reference.directoryName,
                descriptor: operationDescriptor,
                initialDetails: operationDetails,
                from: stagingDescriptor,
                archiveMayBeAbsent: false
            )
            return .success(())
        } catch {
            return .failure(InstallerSelfUpdateFailure(.stagingCleanupFailed))
        }
    }

    /// Re-reads the staged archive through no-follow descriptors.  A normal
    /// replacement produces a distinct identity; a symlink, hardlink,
    /// foreign-owned, permissive, missing or non-regular object fails closed.
    public func inspectStagedInstallerAssetIdentity(
        _ stagedAsset: StagedInstallerAsset
    ) async -> Result<StagedInstallerFileIdentity, InstallerSelfUpdateFailure> {
        do {
            let reference = try validateReference(for: stagedAsset)
            let identity = try inspectArchiveIdentity(reference: reference)
            return .success(identity)
        } catch {
            return .failure(InstallerSelfUpdateFailure(.stagedAssetIdentityChanged))
        }
    }

    /// Resolves a private archive only after the same descriptor-based
    /// reinspection used by the coordinator.  The URL is constructed solely
    /// from fixed internal names and a canonical UUID reference; it never
    /// incorporates caller-controlled path text.
    public func resolveStagedInstallerArchive(
        _ stagedAsset: StagedInstallerAsset
    ) async -> Result<URL, InstallerSelfUpdateFailure> {
        do {
            let reference = try validateReference(for: stagedAsset)
            let observedIdentity = try inspectArchiveIdentity(reference: reference)
            guard observedIdentity == stagedAsset.fileIdentity else {
                throw MacOSInstallerArchiveStagingError.insecureFilesystem
            }
            return .success(archiveURL(for: reference))
        } catch {
            return .failure(InstallerSelfUpdateFailure(.stagedAssetIdentityChanged))
        }
    }

    private func inspectArchiveIdentity(
        reference: ArchiveReference
    ) throws -> StagedInstallerFileIdentity {
        guard let rootDescriptor = try openSecureStateRootDirectory(createIfMissing: false) else {
            throw MacOSInstallerArchiveStagingError.insecureFilesystem
        }
        defer { _ = Darwin.close(rootDescriptor) }
        guard let stagingDescriptor = try openSecureDirectory(
            named: Self.stagingDirectoryName,
            in: rootDescriptor,
            createIfMissing: false
        ) else {
            throw MacOSInstallerArchiveStagingError.insecureFilesystem
        }
        defer { _ = Darwin.close(stagingDescriptor) }
        guard let operationDescriptor = try openSecureDirectory(
            named: reference.directoryName,
            in: stagingDescriptor,
            createIfMissing: false
        ) else {
            throw MacOSInstallerArchiveStagingError.insecureFilesystem
        }
        defer { _ = Darwin.close(operationDescriptor) }
        let archiveDescriptor = Self.archiveFileName.withCString { name in
            Darwin.openat(operationDescriptor, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard archiveDescriptor >= 0 else {
            throw MacOSInstallerArchiveStagingError.insecureFilesystem
        }
        defer { _ = Darwin.close(archiveDescriptor) }
        let details = try secureRegularFileDetails(archiveDescriptor)
        guard details.st_size > 0,
              details.st_size <= off_t(maximumArchiveBytes) else {
            throw MacOSInstallerArchiveStagingError.insecureFilesystem
        }
        return try identity(for: details)
    }

    private func requireSecureStateRootDirectory() throws -> Int32 {
        guard let descriptor = try openSecureStateRootDirectory(createIfMissing: true) else {
            throw MacOSInstallerArchiveStagingError.insecureFilesystem
        }
        return descriptor
    }

    private func preflightSecureStateRoot() throws {
        let rootDescriptor = try requireSecureStateRootDirectory()
        defer { _ = Darwin.close(rootDescriptor) }
        let stagingDescriptor = try requireSecureStagingDirectory(in: rootDescriptor)
        _ = Darwin.close(stagingDescriptor)
    }

    private func openSecureStateRootDirectory(createIfMissing: Bool) throws -> Int32? {
        if createIfMissing {
            let result = stateRoot.withUnsafeFileSystemRepresentation { path -> Int32 in
                guard let path else { return -1 }
                return Darwin.mkdir(path, mode_t(0o700))
            }
            if result != 0 && errno != EEXIST {
                throw MacOSInstallerArchiveStagingError.insecureFilesystem
            }
        }
        let descriptor = stateRoot.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard descriptor >= 0 else {
            if !createIfMissing && errno == ENOENT {
                return nil
            }
            throw MacOSInstallerArchiveStagingError.insecureFilesystem
        }
        guard isSecureDirectory(descriptor) else {
            _ = Darwin.close(descriptor)
            throw MacOSInstallerArchiveStagingError.insecureFilesystem
        }
        return descriptor
    }

    private func requireSecureStagingDirectory(in rootDescriptor: Int32) throws -> Int32 {
        guard let descriptor = try openSecureDirectory(
            named: Self.stagingDirectoryName,
            in: rootDescriptor,
            createIfMissing: true
        ) else {
            throw MacOSInstallerArchiveStagingError.insecureFilesystem
        }
        return descriptor
    }

    private func openSecureDirectory(
        named name: String,
        in parentDescriptor: Int32,
        createIfMissing: Bool
    ) throws -> Int32? {
        guard Self.isSafeInternalDirectoryName(name) else {
            throw MacOSInstallerArchiveStagingError.insecureFilesystem
        }
        if createIfMissing {
            let result = name.withCString { childName in
                Darwin.mkdirat(parentDescriptor, childName, mode_t(0o700))
            }
            if result != 0 && errno != EEXIST {
                throw MacOSInstallerArchiveStagingError.insecureFilesystem
            }
        }
        let descriptor = name.withCString { childName in
            Darwin.openat(
                parentDescriptor,
                childName,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY
            )
        }
        guard descriptor >= 0 else {
            if !createIfMissing && errno == ENOENT {
                return nil
            }
            throw MacOSInstallerArchiveStagingError.insecureFilesystem
        }
        guard isSecureDirectory(descriptor) else {
            _ = Darwin.close(descriptor)
            throw MacOSInstallerArchiveStagingError.insecureFilesystem
        }
        return descriptor
    }

    private func createPrivateOperationDirectory(
        forReleaseAssetName releaseAssetName: String,
        in stagingDescriptor: Int32
    ) throws -> CreatedOperationDirectory {
        guard InstallerSelfUpdateValidation.isInstallerArchiveName(releaseAssetName) else {
            throw MacOSInstallerArchiveStagingError.insecureFilesystem
        }
        for _ in 0..<8 {
            let identifier = UUID().uuidString.lowercased()
            let directoryName = "archive-\(identifier)"
            let result = directoryName.withCString { name in
                Darwin.mkdirat(stagingDescriptor, name, mode_t(0o700))
            }
            if result != 0 {
                if errno == EEXIST {
                    continue
                }
                throw MacOSInstallerArchiveStagingError.insecureFilesystem
            }
            guard let descriptor = try openSecureDirectory(
                named: directoryName,
                in: stagingDescriptor,
                createIfMissing: false
            ) else {
                throw MacOSInstallerArchiveStagingError.insecureFilesystem
            }
            let details = try secureDirectoryDetails(descriptor)
            let opaqueReference = "\(Self.opaqueReferencePrefix):\(identifier):\(releaseAssetName)"
            guard InstallerSelfUpdateValidation.isOpaqueReference(opaqueReference) else {
                _ = Darwin.close(descriptor)
                throw MacOSInstallerArchiveStagingError.insecureFilesystem
            }
            return CreatedOperationDirectory(
                opaqueReference: opaqueReference,
                directoryName: directoryName,
                descriptor: descriptor,
                details: details
            )
        }
        throw MacOSInstallerArchiveStagingError.insecureFilesystem
    }

    private func writeArchive(
        _ data: Data,
        to operationDescriptor: Int32
    ) throws -> StagedInstallerFileIdentity {
        guard !data.isEmpty, data.count <= maximumArchiveBytes else {
            throw MacOSInstallerArchiveStagingError.insecureFilesystem
        }
        let archiveDescriptor = Self.archiveFileName.withCString { name in
            Darwin.openat(
                operationDescriptor,
                name,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW_ANY,
                mode_t(0o600)
            )
        }
        guard archiveDescriptor >= 0 else {
            throw MacOSInstallerArchiveStagingError.insecureFilesystem
        }
        defer { _ = Darwin.close(archiveDescriptor) }
        guard Darwin.fchmod(archiveDescriptor, mode_t(0o600)) == 0 else {
            throw MacOSInstallerArchiveStagingError.insecureFilesystem
        }
        _ = try secureRegularFileDetails(archiveDescriptor)
        try writeAll(data, to: archiveDescriptor)
        guard Darwin.fsync(archiveDescriptor) == 0 else {
            throw MacOSInstallerArchiveStagingError.insecureFilesystem
        }
        let details = try secureRegularFileDetails(archiveDescriptor)
        guard details.st_size == off_t(data.count),
              details.st_size <= off_t(maximumArchiveBytes),
              Darwin.fsync(operationDescriptor) == 0 else {
            throw MacOSInstallerArchiveStagingError.insecureFilesystem
        }
        return try identity(for: details)
    }

    private func removeOperationDirectory(
        named operationName: String,
        descriptor operationDescriptor: Int32,
        initialDetails: stat,
        from stagingDescriptor: Int32,
        archiveMayBeAbsent: Bool
    ) throws {
        try removeSecureArchiveFile(
            from: operationDescriptor,
            archiveMayBeAbsent: archiveMayBeAbsent
        )
        try verifyDirectoryEntry(
            named: operationName,
            in: stagingDescriptor,
            matches: initialDetails
        )
        let removeResult = operationName.withCString { name in
            Darwin.unlinkat(stagingDescriptor, name, AT_REMOVEDIR)
        }
        guard removeResult == 0, Darwin.fsync(stagingDescriptor) == 0 else {
            throw MacOSInstallerArchiveStagingError.insecureFilesystem
        }
    }

    private func removeSecureArchiveFile(
        from operationDescriptor: Int32,
        archiveMayBeAbsent: Bool
    ) throws {
        let archiveDescriptor = Self.archiveFileName.withCString { name in
            Darwin.openat(operationDescriptor, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard archiveDescriptor >= 0 else {
            if archiveMayBeAbsent && errno == ENOENT {
                return
            }
            throw MacOSInstallerArchiveStagingError.insecureFilesystem
        }
        defer { _ = Darwin.close(archiveDescriptor) }
        _ = try secureRegularFileDetails(archiveDescriptor)
        let removeResult = Self.archiveFileName.withCString { name in
            Darwin.unlinkat(operationDescriptor, name, 0)
        }
        guard removeResult == 0, Darwin.fsync(operationDescriptor) == 0 else {
            throw MacOSInstallerArchiveStagingError.insecureFilesystem
        }
    }

    private func verifyDirectoryEntry(
        named name: String,
        in parentDescriptor: Int32,
        matches expected: stat
    ) throws {
        var observed = stat()
        let result = name.withCString { childName in
            Darwin.fstatat(parentDescriptor, childName, &observed, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0,
              isSecureDirectoryDetails(observed),
              observed.st_dev == expected.st_dev,
              observed.st_ino == expected.st_ino else {
            throw MacOSInstallerArchiveStagingError.insecureFilesystem
        }
    }

    private func validateReference(
        for stagedAsset: StagedInstallerAsset
    ) throws -> ArchiveReference {
        _ = try StagedInstallerAsset(
            releaseAssetName: stagedAsset.releaseAssetName,
            opaqueReference: stagedAsset.opaqueReference,
            fileIdentity: stagedAsset.fileIdentity
        )
        guard stagedAsset.opaqueReference.utf8.count <= Self.maximumOpaqueReferenceLength else {
            throw MacOSInstallerArchiveStagingError.insecureFilesystem
        }
        let fields = stagedAsset.opaqueReference.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 3,
              fields[0] == Substring(Self.opaqueReferencePrefix),
              let identifier = UUID(uuidString: String(fields[1])),
              identifier.uuidString.lowercased() == String(fields[1]),
              fields[2] == Substring(stagedAsset.releaseAssetName) else {
            throw MacOSInstallerArchiveStagingError.insecureFilesystem
        }
        let canonicalIdentifier = identifier.uuidString.lowercased()
        return ArchiveReference(directoryName: "archive-\(canonicalIdentifier)")
    }

    private func archiveURL(for reference: ArchiveReference) -> URL {
        stateRoot
            .appendingPathComponent(Self.stagingDirectoryName, isDirectory: true)
            .appendingPathComponent(reference.directoryName, isDirectory: true)
            .appendingPathComponent(Self.archiveFileName, isDirectory: false)
    }

    private func secureDirectoryDetails(_ descriptor: Int32) throws -> stat {
        var details = stat()
        guard Darwin.fstat(descriptor, &details) == 0,
              isSecureDirectoryDetails(details) else {
            throw MacOSInstallerArchiveStagingError.insecureFilesystem
        }
        return details
    }

    private func isSecureDirectory(_ descriptor: Int32) -> Bool {
        var details = stat()
        return Darwin.fstat(descriptor, &details) == 0 && isSecureDirectoryDetails(details)
    }

    private func isSecureDirectoryDetails(_ details: stat) -> Bool {
        (details.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
            && details.st_uid == Darwin.geteuid()
            && (details.st_mode & mode_t(0o7777)) == mode_t(0o700)
    }

    private func secureRegularFileDetails(_ descriptor: Int32) throws -> stat {
        var details = stat()
        guard Darwin.fstat(descriptor, &details) == 0,
              (details.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              details.st_uid == Darwin.geteuid(),
              details.st_nlink == 1,
              (details.st_mode & mode_t(0o7777)) == mode_t(0o600) else {
            throw MacOSInstallerArchiveStagingError.insecureFilesystem
        }
        return details
    }

    private func identity(for details: stat) throws -> StagedInstallerFileIdentity {
        guard details.st_size > 0 else {
            throw MacOSInstallerArchiveStagingError.insecureFilesystem
        }
        let volumeReference = "volume-\(UInt64(details.st_dev))"
        // Include both inode and mutation timestamps.  The public identity type
        // has no dedicated timestamp fields, so these opaque facts add a
        // same-inode drift signal alongside replacement detection; the later
        // signed SHA-256 verifier remains the content-integrity authority.
        let fileReference = [
            "inode", String(UInt64(details.st_ino)),
            "mtime", String(details.st_mtimespec.tv_sec), String(details.st_mtimespec.tv_nsec),
            "ctime", String(details.st_ctimespec.tv_sec), String(details.st_ctimespec.tv_nsec),
        ].joined(separator: "-")
        return try StagedInstallerFileIdentity(
            volumeReference: volumeReference,
            fileReference: fileReference,
            byteCount: UInt64(details.st_size)
        )
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let baseAddress = buffer.baseAddress else {
                throw MacOSInstallerArchiveStagingError.insecureFilesystem
            }
            var written = 0
            while written < buffer.count {
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: written),
                    buffer.count - written
                )
                if result < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw MacOSInstallerArchiveStagingError.insecureFilesystem
                }
                guard result > 0 else {
                    throw MacOSInstallerArchiveStagingError.insecureFilesystem
                }
                written += Int(result)
            }
        }
    }

    private static func canonicalStateRoot(for input: URL) -> URL {
        let standardized = input.standardizedFileURL
        let parent = standardized.deletingLastPathComponent()
        let resolvedParentPath: String? = parent.withUnsafeFileSystemRepresentation { path in
            guard let path, let resolved = Darwin.realpath(path, nil) else {
                return nil
            }
            defer { Darwin.free(resolved) }
            return String(cString: resolved)
        }
        guard let resolvedParentPath else {
            return standardized
        }
        return URL(fileURLWithPath: resolvedParentPath, isDirectory: true)
            .appendingPathComponent(standardized.lastPathComponent, isDirectory: true)
    }

    private static func isSafeInternalDirectoryName(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.contains("\\")
            && value.unicodeScalars.allSatisfy { scalar in
                (scalar.value >= 48 && scalar.value <= 57)
                    || (scalar.value >= 65 && scalar.value <= 90)
                    || (scalar.value >= 97 && scalar.value <= 122)
                    || scalar.value == 45
                    || scalar.value == 46
                    || scalar.value == 95
            }
    }
}

public enum MacOSInstallerArchiveStagingConfigurationError: Error, Equatable, Sendable {
    case invalidMaximumArchiveBytes
}

private struct ArchiveReference: Sendable {
    let directoryName: String
}

private struct CreatedOperationDirectory {
    let opaqueReference: String
    let directoryName: String
    let descriptor: Int32
    let details: stat
}

private enum MacOSInstallerArchiveStagingError: Error {
    case insecureFilesystem
}
