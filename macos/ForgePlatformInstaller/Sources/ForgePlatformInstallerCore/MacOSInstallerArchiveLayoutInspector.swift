import Darwin
import Foundation

/// The two compression methods a later extractor may consider after this
/// layout gate succeeds.  This inspector never decompresses either method.
public enum MacOSInstallerArchiveCompression: String, Equatable, Sendable {
    case stored
    case deflate
}

/// A logical ZIP entry kind.  The `logicalPath` carried by the layout is an
/// archive identity, not a filesystem path that can be passed to a shell or
/// used as an extraction destination.
public enum MacOSInstallerArchiveEntryKind: String, Equatable, Sendable {
    case directory
    case regularFile
}

/// One strictly admitted central-directory entry.  Future extraction must
/// still use descriptor-based destination handling; this value is a read-only
/// layout proof and never authorizes an arbitrary path write.
public struct MacOSInstallerArchiveLayoutEntry: Equatable, Sendable {
    public let logicalPath: String
    public let kind: MacOSInstallerArchiveEntryKind
    public let compression: MacOSInstallerArchiveCompression
    public let compressedByteCount: UInt64
    public let uncompressedByteCount: UInt64
}

/// Read-only evidence that one staged archive has exactly one safe macOS app
/// bundle layout.  It intentionally contains no extracted URL, executable
/// selection, signing result, product identity, service instruction or handoff
/// permission.
public struct MacOSInstallerArchiveLayout: Equatable, Sendable {
    public let appBundleRoot: String
    public let archiveByteCount: UInt64
    public let totalUncompressedByteCount: UInt64
    /// Sorted by `logicalPath`; directory entries use the same canonical path
    /// spelling as files and are distinguished by `kind`.
    public let entries: [MacOSInstallerArchiveLayoutEntry]
}

/// The only public inspection seam.  A caller supplies an existing staged
/// asset and the archive resolver already owned by the native stager; it does
/// not supply an arbitrary URL, filename, shell command or extraction target.
public protocol MacOSInstallerArchiveLayoutInspecting: Sendable {
    func inspectStagedInstallerArchive(
        _ stagedAsset: StagedInstallerAsset,
        using resolver: any MacOSInstallerArchiveStagingResolving
    ) async -> Result<MacOSInstallerArchiveLayout, InstallerSelfUpdateFailure>
}

/// Strict, read-only ZIP central-directory inspector for a staged native
/// installer archive.  It deliberately rejects formats or layout features
/// that would require an unproven extraction policy: Zip64, multi-disk ZIP,
/// archive and entry comments, encrypted or descriptor-based entries,
/// unsupported compression, symlinks, non-regular special files, path aliases,
/// traversal components, duplicate entries and multiple `.app` roots.
///
/// This is only a prerequisite for a future extractor.  It does not unzip,
/// invoke `ditto`, create an app bundle, execute code, launch a process or
/// mutate installer/product state.
public struct MacOSInstallerArchiveLayoutInspector: MacOSInstallerArchiveLayoutInspecting {
    public static let defaultMaximumArchiveBytes = 512 * 1024 * 1024
    public static let defaultMaximumCentralDirectoryBytes = 16 * 1024 * 1024
    public static let defaultMaximumEntryCount = 8_192
    public static let defaultMaximumPathBytes = 1_024
    public static let defaultMaximumTotalUncompressedBytes: UInt64 = 2 * 1024 * 1024 * 1024

    private static let absoluteMaximumArchiveBytes = 1024 * 1024 * 1024
    private static let absoluteMaximumTotalUncompressedBytes: UInt64 = 8 * 1024 * 1024 * 1024
    private static let maximumEOCDSearchBytes = 22 + 65_535
    fileprivate static let maximumPathDepth = 64

    private let maximumArchiveBytes: Int
    private let maximumCentralDirectoryBytes: Int
    private let maximumEntryCount: Int
    private let maximumPathBytes: Int
    private let maximumTotalUncompressedBytes: UInt64

    public init(
        maximumArchiveBytes: Int = MacOSInstallerArchiveLayoutInspector.defaultMaximumArchiveBytes,
        maximumCentralDirectoryBytes: Int = MacOSInstallerArchiveLayoutInspector.defaultMaximumCentralDirectoryBytes,
        maximumEntryCount: Int = MacOSInstallerArchiveLayoutInspector.defaultMaximumEntryCount,
        maximumPathBytes: Int = MacOSInstallerArchiveLayoutInspector.defaultMaximumPathBytes,
        maximumTotalUncompressedBytes: UInt64 = MacOSInstallerArchiveLayoutInspector.defaultMaximumTotalUncompressedBytes
    ) throws {
        guard maximumArchiveBytes > 0,
              maximumArchiveBytes <= Self.absoluteMaximumArchiveBytes,
              maximumCentralDirectoryBytes > 0,
              maximumCentralDirectoryBytes <= maximumArchiveBytes,
              maximumEntryCount > 0,
              maximumEntryCount < Int(UInt16.max),
              maximumPathBytes > 0,
              maximumPathBytes <= 4_096,
              maximumTotalUncompressedBytes > 0,
              maximumTotalUncompressedBytes <= Self.absoluteMaximumTotalUncompressedBytes else {
            throw MacOSInstallerArchiveLayoutInspectorConfigurationError.invalidLimits
        }
        self.maximumArchiveBytes = maximumArchiveBytes
        self.maximumCentralDirectoryBytes = maximumCentralDirectoryBytes
        self.maximumEntryCount = maximumEntryCount
        self.maximumPathBytes = maximumPathBytes
        self.maximumTotalUncompressedBytes = maximumTotalUncompressedBytes
    }

    /// Resolves the staged archive before and after parsing.  The concrete
    /// stager rechecks its opaque reference and file identity during each
    /// resolution; this inspector additionally uses a no-follow descriptor and
    /// verifies the archive's stat identity before and after every read.
    public func inspectStagedInstallerArchive(
        _ stagedAsset: StagedInstallerAsset,
        using resolver: any MacOSInstallerArchiveStagingResolving
    ) async -> Result<MacOSInstallerArchiveLayout, InstallerSelfUpdateFailure> {
        do {
            _ = try StagedInstallerAsset(
                releaseAssetName: stagedAsset.releaseAssetName,
                opaqueReference: stagedAsset.opaqueReference,
                fileIdentity: stagedAsset.fileIdentity
            )
        } catch {
            return .failure(InstallerSelfUpdateFailure(.stagedAssetIdentityChanged))
        }

        let initialURL: URL
        switch await resolver.resolveStagedInstallerArchive(stagedAsset) {
        case .success(let resolvedURL):
            initialURL = resolvedURL
        case .failure(let failure):
            return .failure(failure)
        }

        let initialInspection: ZIPArchiveInspection
        do {
            initialInspection = try inspectResolvedArchive(
                initialURL,
                expectedByteCount: stagedAsset.fileIdentity.byteCount
            )
        } catch MacOSInstallerArchiveLayoutInspectorError.identityChanged {
            return .failure(InstallerSelfUpdateFailure(.stagedAssetIdentityChanged))
        } catch {
            return .failure(InstallerSelfUpdateFailure(.stagingFailed))
        }

        // A second resolver call makes the stager's own identity gate part of
        // the inspection boundary rather than trusting a URL beyond one read.
        switch await resolver.resolveStagedInstallerArchive(stagedAsset) {
        case .success(let finalURL):
            guard finalURL.standardizedFileURL == initialURL.standardizedFileURL else {
                return .failure(InstallerSelfUpdateFailure(.stagedAssetIdentityChanged))
            }
            // Do not rely solely on a resolver implementation to notice a
            // replacement between the first parse and this second resolution.
            // Parsing twice is deliberately inexpensive relative to a future
            // self-update and means the returned layout describes the archive
            // observed after the resolver's final identity gate.
            do {
                let finalInspection = try inspectResolvedArchive(
                    finalURL,
                    expectedByteCount: stagedAsset.fileIdentity.byteCount
                )
                guard finalInspection == initialInspection else {
                    return .failure(InstallerSelfUpdateFailure(.stagedAssetIdentityChanged))
                }
                return .success(finalInspection.layout)
            } catch MacOSInstallerArchiveLayoutInspectorError.identityChanged {
                return .failure(InstallerSelfUpdateFailure(.stagedAssetIdentityChanged))
            } catch {
                return .failure(InstallerSelfUpdateFailure(.stagingFailed))
            }
        case .failure:
            return .failure(InstallerSelfUpdateFailure(.stagedAssetIdentityChanged))
        }
    }

    private func inspectResolvedArchive(
        _ archiveURL: URL,
        expectedByteCount: UInt64
    ) throws -> ZIPArchiveInspection {
        guard archiveURL.isFileURL else {
            throw MacOSInstallerArchiveLayoutInspectorError.invalidArchive
        }
        let descriptor = archiveURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard descriptor >= 0 else {
            throw MacOSInstallerArchiveLayoutInspectorError.identityChanged
        }
        defer { _ = Darwin.close(descriptor) }

        let initialObservation = try secureArchiveObservation(descriptor)
        guard initialObservation.byteCount == expectedByteCount else {
            throw MacOSInstallerArchiveLayoutInspectorError.identityChanged
        }
        let reader = ZIPArchiveFileReader(
            descriptor: descriptor,
            fileSize: initialObservation.byteCount
        )
        let endOfDirectory = try parseEndOfCentralDirectory(using: reader)
        let entries = try parseCentralDirectory(
            using: reader,
            endOfDirectory: endOfDirectory
        )
        try validateLocalHeaders(
            entries,
            using: reader,
            centralDirectoryOffset: endOfDirectory.centralDirectoryOffset
        )
        let layout = try validateMacOSAppLayout(
            entries,
            archiveByteCount: initialObservation.byteCount
        )
        let finalObservation = try secureArchiveObservation(descriptor)
        guard finalObservation == initialObservation else {
            throw MacOSInstallerArchiveLayoutInspectorError.identityChanged
        }
        return ZIPArchiveInspection(
            layout: layout,
            observation: finalObservation
        )
    }

    private func parseEndOfCentralDirectory(
        using reader: ZIPArchiveFileReader
    ) throws -> ZIPEndOfCentralDirectory {
        let searchByteCount = Int(min(
            reader.fileSize,
            UInt64(Self.maximumEOCDSearchBytes)
        ))
        guard searchByteCount >= ZIPConstants.endOfCentralDirectoryFixedLength else {
            throw MacOSInstallerArchiveLayoutInspectorError.invalidArchive
        }
        let searchOffset = reader.fileSize - UInt64(searchByteCount)
        let bytes = try reader.read(offset: searchOffset, count: searchByteCount)

        for index in stride(
            from: bytes.count - ZIPConstants.endOfCentralDirectoryFixedLength,
            through: 0,
            by: -1
        ) {
            guard ZIPByteReader.uint32(bytes, at: index) == ZIPConstants.endOfCentralDirectorySignature else {
                continue
            }
            let commentLength = Int(ZIPByteReader.uint16(bytes, at: index + 20))
            guard index + ZIPConstants.endOfCentralDirectoryFixedLength + commentLength == bytes.count else {
                continue
            }
            // Comments and multi-disk/Zip64 forms are intentionally outside
            // this narrow, reproducible archive profile.
            guard commentLength == 0 else {
                throw MacOSInstallerArchiveLayoutInspectorError.invalidArchive
            }
            let diskNumber = ZIPByteReader.uint16(bytes, at: index + 4)
            let centralDirectoryDiskNumber = ZIPByteReader.uint16(bytes, at: index + 6)
            let entriesOnDisk = ZIPByteReader.uint16(bytes, at: index + 8)
            let totalEntries = ZIPByteReader.uint16(bytes, at: index + 10)
            let centralDirectorySize32 = ZIPByteReader.uint32(bytes, at: index + 12)
            let centralDirectoryOffset32 = ZIPByteReader.uint32(bytes, at: index + 16)
            guard diskNumber == 0,
                  centralDirectoryDiskNumber == 0,
                  entriesOnDisk == totalEntries,
                  totalEntries > 0,
                  totalEntries != UInt16.max,
                  centralDirectorySize32 != UInt32.max,
                  centralDirectoryOffset32 != UInt32.max,
                  Int(totalEntries) <= maximumEntryCount else {
                throw MacOSInstallerArchiveLayoutInspectorError.invalidArchive
            }
            let centralDirectorySize = UInt64(centralDirectorySize32)
            let centralDirectoryOffset = UInt64(centralDirectoryOffset32)
            let endOfDirectoryOffset = searchOffset + UInt64(index)
            guard centralDirectorySize <= UInt64(maximumCentralDirectoryBytes),
                  centralDirectoryOffset <= endOfDirectoryOffset,
                  centralDirectorySize <= endOfDirectoryOffset - centralDirectoryOffset,
                  centralDirectoryOffset + centralDirectorySize == endOfDirectoryOffset else {
                throw MacOSInstallerArchiveLayoutInspectorError.invalidArchive
            }
            return ZIPEndOfCentralDirectory(
                centralDirectoryOffset: centralDirectoryOffset,
                centralDirectorySize: centralDirectorySize,
                entryCount: Int(totalEntries)
            )
        }
        throw MacOSInstallerArchiveLayoutInspectorError.invalidArchive
    }

    private func parseCentralDirectory(
        using reader: ZIPArchiveFileReader,
        endOfDirectory: ZIPEndOfCentralDirectory
    ) throws -> [ZIPCentralDirectoryEntry] {
        guard endOfDirectory.centralDirectorySize <= UInt64(Int.max) else {
            throw MacOSInstallerArchiveLayoutInspectorError.invalidArchive
        }
        let centralDirectory = try reader.read(
            offset: endOfDirectory.centralDirectoryOffset,
            count: Int(endOfDirectory.centralDirectorySize)
        )
        var cursor = ZIPByteReader(data: centralDirectory)
        var entries: [ZIPCentralDirectoryEntry] = []
        entries.reserveCapacity(endOfDirectory.entryCount)

        for _ in 0..<endOfDirectory.entryCount {
            guard cursor.remaining >= ZIPConstants.centralDirectoryFixedLength,
                  try cursor.readUInt32() == ZIPConstants.centralDirectorySignature else {
                throw MacOSInstallerArchiveLayoutInspectorError.invalidArchive
            }
            let versionMadeBy = try cursor.readUInt16()
            let versionNeeded = try cursor.readUInt16()
            let generalPurposeFlags = try cursor.readUInt16()
            let compressionMethod = try cursor.readUInt16()
            _ = try cursor.readUInt16() // DOS modification time
            _ = try cursor.readUInt16() // DOS modification date
            let crc32 = try cursor.readUInt32()
            let compressedSize32 = try cursor.readUInt32()
            let uncompressedSize32 = try cursor.readUInt32()
            let fileNameLength = Int(try cursor.readUInt16())
            let extraFieldLength = Int(try cursor.readUInt16())
            let commentLength = Int(try cursor.readUInt16())
            let diskNumberStart = try cursor.readUInt16()
            _ = try cursor.readUInt16() // internal attributes
            let externalAttributes = try cursor.readUInt32()
            let localHeaderOffset32 = try cursor.readUInt32()

            guard versionNeeded < 45,
                  ZIPConstants.permits(generalPurposeFlags: generalPurposeFlags),
                  let compression = MacOSInstallerArchiveCompression(zipMethod: compressionMethod),
                  compressedSize32 != UInt32.max,
                  uncompressedSize32 != UInt32.max,
                  diskNumberStart == 0,
                  localHeaderOffset32 != UInt32.max,
                  commentLength == 0 else {
                throw MacOSInstallerArchiveLayoutInspectorError.invalidArchive
            }
            let fileName = try cursor.readData(count: fileNameLength)
            let extraField = try cursor.readData(count: extraFieldLength)
            guard !ZIPExtraField.containsZip64(extraField),
                  fileNameLength > 0,
                  fileNameLength <= maximumPathBytes else {
                throw MacOSInstallerArchiveLayoutInspectorError.invalidArchive
            }
            let path = try ZIPArchivePath(
                bytes: fileName,
                generalPurposeFlags: generalPurposeFlags,
                maximumPathBytes: maximumPathBytes
            )
            let compressedByteCount = UInt64(compressedSize32)
            let uncompressedByteCount = UInt64(uncompressedSize32)
            guard compression != .stored || compressedByteCount == uncompressedByteCount else {
                throw MacOSInstallerArchiveLayoutInspectorError.invalidArchive
            }
            try validateExternalAttributes(
                versionMadeBy: versionMadeBy,
                externalAttributes,
                path: path,
                compression: compression,
                compressedByteCount: compressedByteCount,
                uncompressedByteCount: uncompressedByteCount
            )
            entries.append(ZIPCentralDirectoryEntry(
                path: path,
                versionMadeBy: versionMadeBy,
                versionNeeded: versionNeeded,
                generalPurposeFlags: generalPurposeFlags,
                compression: compression,
                crc32: crc32,
                compressedByteCount: compressedByteCount,
                uncompressedByteCount: uncompressedByteCount,
                externalAttributes: externalAttributes,
                localHeaderOffset: UInt64(localHeaderOffset32),
                rawFileName: fileName
            ))
        }
        guard cursor.remaining == 0 else {
            throw MacOSInstallerArchiveLayoutInspectorError.invalidArchive
        }
        return entries
    }

    private func validateLocalHeaders(
        _ entries: [ZIPCentralDirectoryEntry],
        using reader: ZIPArchiveFileReader,
        centralDirectoryOffset: UInt64
    ) throws {
        var localRanges: [ZIPByteRange] = []
        localRanges.reserveCapacity(entries.count)

        for entry in entries {
            guard entry.localHeaderOffset < centralDirectoryOffset else {
                throw MacOSInstallerArchiveLayoutInspectorError.invalidArchive
            }
            let fixedHeader = try reader.read(
                offset: entry.localHeaderOffset,
                count: ZIPConstants.localFileHeaderFixedLength
            )
            var cursor = ZIPByteReader(data: fixedHeader)
            guard try cursor.readUInt32() == ZIPConstants.localFileHeaderSignature else {
                throw MacOSInstallerArchiveLayoutInspectorError.invalidArchive
            }
            let versionNeeded = try cursor.readUInt16()
            let generalPurposeFlags = try cursor.readUInt16()
            let compressionMethod = try cursor.readUInt16()
            _ = try cursor.readUInt16() // DOS modification time
            _ = try cursor.readUInt16() // DOS modification date
            let crc32 = try cursor.readUInt32()
            let compressedSize32 = try cursor.readUInt32()
            let uncompressedSize32 = try cursor.readUInt32()
            let fileNameLength = Int(try cursor.readUInt16())
            let extraFieldLength = Int(try cursor.readUInt16())

            guard versionNeeded == entry.versionNeeded,
                  ZIPConstants.permits(generalPurposeFlags: generalPurposeFlags),
                  generalPurposeFlags == entry.generalPurposeFlags,
                  MacOSInstallerArchiveCompression(zipMethod: compressionMethod) == entry.compression,
                  crc32 == entry.crc32,
                  compressedSize32 != UInt32.max,
                  uncompressedSize32 != UInt32.max,
                  UInt64(compressedSize32) == entry.compressedByteCount,
                  UInt64(uncompressedSize32) == entry.uncompressedByteCount else {
                throw MacOSInstallerArchiveLayoutInspectorError.invalidArchive
            }
            let variableHeaderLength = try checkedAdd(
                UInt64(fileNameLength),
                UInt64(extraFieldLength)
            )
            let variableHeaderOffset = try checkedAdd(
                entry.localHeaderOffset,
                UInt64(ZIPConstants.localFileHeaderFixedLength)
            )
            guard variableHeaderOffset <= centralDirectoryOffset,
                  variableHeaderLength <= centralDirectoryOffset - variableHeaderOffset,
                  variableHeaderLength <= UInt64(Int.max) else {
                throw MacOSInstallerArchiveLayoutInspectorError.invalidArchive
            }
            let variableHeader = try reader.read(
                offset: variableHeaderOffset,
                count: Int(variableHeaderLength)
            )
            var variableCursor = ZIPByteReader(data: variableHeader)
            let localFileName = try variableCursor.readData(count: fileNameLength)
            let localExtraField = try variableCursor.readData(count: extraFieldLength)
            guard variableCursor.remaining == 0,
                  localFileName == entry.rawFileName,
                  !ZIPExtraField.containsZip64(localExtraField) else {
                throw MacOSInstallerArchiveLayoutInspectorError.invalidArchive
            }
            let dataOffset = try checkedAdd(variableHeaderOffset, variableHeaderLength)
            let dataEnd = try checkedAdd(dataOffset, entry.compressedByteCount)
            guard dataEnd <= centralDirectoryOffset else {
                throw MacOSInstallerArchiveLayoutInspectorError.invalidArchive
            }
            localRanges.append(ZIPByteRange(start: entry.localHeaderOffset, end: dataEnd))
        }

        let orderedRanges = localRanges.sorted { left, right in
            left.start < right.start
        }
        guard orderedRanges.first?.start == 0 else {
            throw MacOSInstallerArchiveLayoutInspectorError.invalidArchive
        }
        for (previous, next) in zip(orderedRanges, orderedRanges.dropFirst()) {
            guard previous.end <= next.start else {
                throw MacOSInstallerArchiveLayoutInspectorError.invalidArchive
            }
        }
    }

    private func validateMacOSAppLayout(
        _ entries: [ZIPCentralDirectoryEntry],
        archiveByteCount: UInt64
    ) throws -> MacOSInstallerArchiveLayout {
        var entryByPath: [String: ZIPCentralDirectoryEntry] = [:]
        var directoryPaths = Set<String>()
        var caseFoldedPaths = Set<String>()
        var appRoot: String?
        var totalUncompressedByteCount: UInt64 = 0

        for entry in entries {
            let components = entry.path.components
            guard let candidateRoot = components.first,
                  ZIPArchivePath.isAppBundleRoot(candidateRoot),
                  !components.dropFirst().contains(where: ZIPArchivePath.isNestedAppBundleComponent) else {
                throw MacOSInstallerArchiveLayoutInspectorError.invalidArchive
            }
            if let appRoot {
                guard appRoot == candidateRoot else {
                    throw MacOSInstallerArchiveLayoutInspectorError.invalidArchive
                }
            } else {
                appRoot = candidateRoot
            }
            guard entryByPath[entry.path.canonical] == nil else {
                throw MacOSInstallerArchiveLayoutInspectorError.invalidArchive
            }
            // A later macOS extraction might target the common
            // case-insensitive filesystem.  Treat archive names that differ
            // only by case as an ambiguity now, while there is no destination
            // filesystem involved yet.
            guard caseFoldedPaths.insert(entry.path.canonical.lowercased()).inserted else {
                throw MacOSInstallerArchiveLayoutInspectorError.invalidArchive
            }
            entryByPath[entry.path.canonical] = entry
            if entry.path.isDirectory {
                directoryPaths.insert(entry.path.canonical)
            }
            let (newTotal, overflow) = totalUncompressedByteCount.addingReportingOverflow(entry.uncompressedByteCount)
            guard !overflow, newTotal <= maximumTotalUncompressedBytes else {
                throw MacOSInstallerArchiveLayoutInspectorError.invalidArchive
            }
            totalUncompressedByteCount = newTotal
        }

        guard let appRoot,
              let rootEntry = entryByPath[appRoot],
              rootEntry.path.isDirectory,
              directoryPaths.contains(appRoot) else {
            throw MacOSInstallerArchiveLayoutInspectorError.invalidArchive
        }

        for entry in entries {
            guard entry.path.components.count <= Self.maximumPathDepth else {
                throw MacOSInstallerArchiveLayoutInspectorError.invalidArchive
            }
            for parentDepth in 1..<entry.path.components.count {
                let parentPath = entry.path.components.prefix(parentDepth).joined(separator: "/")
                guard directoryPaths.contains(parentPath) else {
                    throw MacOSInstallerArchiveLayoutInspectorError.invalidArchive
                }
            }
        }

        let contentsDirectory = "\(appRoot)/Contents"
        let macOSDirectory = "\(contentsDirectory)/MacOS"
        let infoPlist = "\(contentsDirectory)/Info.plist"
        guard directoryPaths.contains(contentsDirectory),
              directoryPaths.contains(macOSDirectory),
              let infoPlistEntry = entryByPath[infoPlist],
              !infoPlistEntry.path.isDirectory,
              entries.contains(where: { entry in
                  !entry.path.isDirectory
                      && ZIPArchivePath.parent(of: entry.path.canonical) == macOSDirectory
              }) else {
            throw MacOSInstallerArchiveLayoutInspectorError.invalidArchive
        }

        let layoutEntries = entries
            .sorted { left, right in left.path.canonical < right.path.canonical }
            .map { entry in
                MacOSInstallerArchiveLayoutEntry(
                    logicalPath: entry.path.canonical,
                    kind: entry.path.isDirectory ? .directory : .regularFile,
                    compression: entry.compression,
                    compressedByteCount: entry.compressedByteCount,
                    uncompressedByteCount: entry.uncompressedByteCount
                )
            }
        return MacOSInstallerArchiveLayout(
            appBundleRoot: appRoot,
            archiveByteCount: archiveByteCount,
            totalUncompressedByteCount: totalUncompressedByteCount,
            entries: layoutEntries
        )
    }

    private func validateExternalAttributes(
        versionMadeBy: UInt16,
        _ externalAttributes: UInt32,
        path: ZIPArchivePath,
        compression: MacOSInstallerArchiveCompression,
        compressedByteCount: UInt64,
        uncompressedByteCount: UInt64
    ) throws {
        // Only Unix attributes give this gate a deterministic way to exclude
        // symlinks and special files.  A future extractor must not infer a
        // safe file kind from a DOS/unknown-platform archive.
        guard UInt8(truncatingIfNeeded: versionMadeBy >> 8) == 3 else {
            throw MacOSInstallerArchiveLayoutInspectorError.invalidArchive
        }
        let unixMode = UInt16((externalAttributes >> 16) & 0xffff)
        let fileType = unixMode & 0o170000
        guard (unixMode & 0o022) == 0,
              fileType != 0o120000 else { // symbolic link
            throw MacOSInstallerArchiveLayoutInspectorError.invalidArchive
        }
        if path.isDirectory {
            guard compression == .stored,
                  compressedByteCount == 0,
                  uncompressedByteCount == 0,
                  fileType == 0o040000 else {
                throw MacOSInstallerArchiveLayoutInspectorError.invalidArchive
            }
        } else {
            guard fileType == 0o100000 else {
                throw MacOSInstallerArchiveLayoutInspectorError.invalidArchive
            }
        }
    }

    private func secureArchiveObservation(_ descriptor: Int32) throws -> ZIPArchiveFileObservation {
        var details = stat()
        guard Darwin.fstat(descriptor, &details) == 0,
              (details.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              details.st_uid == Darwin.geteuid(),
              details.st_nlink == 1,
              (details.st_mode & mode_t(0o7777)) == mode_t(0o600) else {
            throw MacOSInstallerArchiveLayoutInspectorError.identityChanged
        }
        guard details.st_size > 0,
              details.st_size <= off_t(maximumArchiveBytes) else {
            throw MacOSInstallerArchiveLayoutInspectorError.invalidArchive
        }
        return ZIPArchiveFileObservation(
            device: details.st_dev,
            inode: details.st_ino,
            byteCount: UInt64(details.st_size),
            modificationSeconds: details.st_mtimespec.tv_sec,
            modificationNanoseconds: details.st_mtimespec.tv_nsec,
            changeSeconds: details.st_ctimespec.tv_sec,
            changeNanoseconds: details.st_ctimespec.tv_nsec
        )
    }
}

public enum MacOSInstallerArchiveLayoutInspectorConfigurationError: Error, Equatable, Sendable {
    case invalidLimits
}

private enum MacOSInstallerArchiveLayoutInspectorError: Error {
    case invalidArchive
    case identityChanged
}

private enum ZIPConstants {
    static let localFileHeaderSignature: UInt32 = 0x0403_4b50
    static let centralDirectorySignature: UInt32 = 0x0201_4b50
    static let endOfCentralDirectorySignature: UInt32 = 0x0605_4b50
    static let localFileHeaderFixedLength = 30
    static let centralDirectoryFixedLength = 46
    static let endOfCentralDirectoryFixedLength = 22

    static func permits(generalPurposeFlags: UInt16) -> Bool {
        // Only no flags or the UTF-8 filename marker are admitted.  This
        // rejects encryption, data descriptors and ZIP features a future
        // extractor has not explicitly qualified.
        generalPurposeFlags == 0 || generalPurposeFlags == 0x0800
    }
}

private extension MacOSInstallerArchiveCompression {
    init?(zipMethod: UInt16) {
        switch zipMethod {
        case 0:
            self = .stored
        case 8:
            self = .deflate
        default:
            return nil
        }
    }
}

private struct ZIPEndOfCentralDirectory {
    let centralDirectoryOffset: UInt64
    let centralDirectorySize: UInt64
    let entryCount: Int
}

private struct ZIPCentralDirectoryEntry {
    let path: ZIPArchivePath
    let versionMadeBy: UInt16
    let versionNeeded: UInt16
    let generalPurposeFlags: UInt16
    let compression: MacOSInstallerArchiveCompression
    let crc32: UInt32
    let compressedByteCount: UInt64
    let uncompressedByteCount: UInt64
    let externalAttributes: UInt32
    let localHeaderOffset: UInt64
    let rawFileName: Data
}

private struct ZIPArchivePath {
    let canonical: String
    let components: [String]
    let isDirectory: Bool

    init(
        bytes: Data,
        generalPurposeFlags: UInt16,
        maximumPathBytes: Int
    ) throws {
        guard !bytes.isEmpty,
              bytes.count <= maximumPathBytes,
              (generalPurposeFlags & 0x0800) != 0 || bytes.allSatisfy({ $0 < 0x80 }),
              let rawPath = String(data: bytes, encoding: .utf8) else {
            throw MacOSInstallerArchiveLayoutInspectorError.invalidArchive
        }
        let isDirectory = rawPath.hasSuffix("/")
        let canonical = isDirectory ? String(rawPath.dropLast()) : rawPath
        guard !canonical.isEmpty,
              !canonical.hasPrefix("/"),
              !canonical.contains("\\"),
              !canonical.contains("\u{0}") else {
            throw MacOSInstallerArchiveLayoutInspectorError.invalidArchive
        }
        let components = canonical.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty,
              components.count <= MacOSInstallerArchiveLayoutInspector.maximumPathDepth,
              components.allSatisfy(Self.isSafeComponent) else {
            throw MacOSInstallerArchiveLayoutInspectorError.invalidArchive
        }
        self.canonical = canonical
        self.components = components
        self.isDirectory = isDirectory
    }

    static func isAppBundleRoot(_ value: String) -> Bool {
        guard value.hasSuffix(".app"), value.count > 4 else {
            return false
        }
        return isSafeComponent(String(value.dropLast(4)))
    }

    static func isNestedAppBundleComponent(_ value: String) -> Bool {
        value.hasSuffix(".app")
    }

    static func parent(of canonicalPath: String) -> String? {
        guard let separator = canonicalPath.lastIndex(of: "/") else {
            return nil
        }
        return String(canonicalPath[..<separator])
    }

    private static func isSafeComponent(_ value: String) -> Bool {
        guard !value.isEmpty, value != ".", value != ".." else {
            return false
        }
        return value.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57)
                || (scalar.value >= 65 && scalar.value <= 90)
                || (scalar.value >= 97 && scalar.value <= 122)
                || scalar.value == 32 // space
                || scalar.value == 43 // +
                || scalar.value == 45 // -
                || scalar.value == 46 // .
                || scalar.value == 95 // _
        }
    }
}

private struct ZIPByteRange {
    let start: UInt64
    let end: UInt64
}

private struct ZIPArchiveFileObservation: Equatable {
    let device: dev_t
    let inode: ino_t
    let byteCount: UInt64
    let modificationSeconds: Int
    let modificationNanoseconds: Int
    let changeSeconds: Int
    let changeNanoseconds: Int
}

private struct ZIPArchiveInspection: Equatable {
    let layout: MacOSInstallerArchiveLayout
    let observation: ZIPArchiveFileObservation
}

private struct ZIPArchiveFileReader {
    let descriptor: Int32
    let fileSize: UInt64

    func read(offset: UInt64, count: Int) throws -> Data {
        guard count >= 0,
              offset <= fileSize,
              UInt64(count) <= fileSize - offset,
              offset <= UInt64(Int64.max) else {
            throw MacOSInstallerArchiveLayoutInspectorError.invalidArchive
        }
        guard count > 0 else {
            return Data()
        }
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            guard let baseAddress = buffer.baseAddress else {
                throw MacOSInstallerArchiveLayoutInspectorError.invalidArchive
            }
            var readByteCount = 0
            while readByteCount < buffer.count {
                let position = offset + UInt64(readByteCount)
                guard position <= UInt64(Int64.max) else {
                    throw MacOSInstallerArchiveLayoutInspectorError.invalidArchive
                }
                let result = Darwin.pread(
                    descriptor,
                    baseAddress.advanced(by: readByteCount),
                    buffer.count - readByteCount,
                    off_t(position)
                )
                if result < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw MacOSInstallerArchiveLayoutInspectorError.invalidArchive
                }
                guard result > 0 else {
                    throw MacOSInstallerArchiveLayoutInspectorError.invalidArchive
                }
                readByteCount += Int(result)
            }
        }
        return data
    }
}

private struct ZIPByteReader {
    private let data: Data
    private var offset = 0

    init(data: Data) {
        self.data = data
    }

    var remaining: Int {
        data.count - offset
    }

    mutating func readUInt16() throws -> UInt16 {
        guard remaining >= 2 else {
            throw MacOSInstallerArchiveLayoutInspectorError.invalidArchive
        }
        defer { offset += 2 }
        return Self.uint16(data, at: offset)
    }

    mutating func readUInt32() throws -> UInt32 {
        guard remaining >= 4 else {
            throw MacOSInstallerArchiveLayoutInspectorError.invalidArchive
        }
        defer { offset += 4 }
        return Self.uint32(data, at: offset)
    }

    mutating func readData(count: Int) throws -> Data {
        guard count >= 0, count <= remaining else {
            throw MacOSInstallerArchiveLayoutInspectorError.invalidArchive
        }
        defer { offset += count }
        return Data(data[offset..<(offset + count)])
    }

    static func uint16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    static func uint32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}

private enum ZIPExtraField {
    static func containsZip64(_ data: Data) -> Bool {
        var cursor = ZIPByteReader(data: data)
        while cursor.remaining > 0 {
            guard let identifier = try? cursor.readUInt16(),
                  let byteCount = try? cursor.readUInt16(),
                  Int(byteCount) <= cursor.remaining else {
                return true
            }
            if identifier == 0x0001 {
                return true
            }
            guard (try? cursor.readData(count: Int(byteCount))) != nil else {
                return true
            }
        }
        return false
    }
}

private func checkedAdd(_ left: UInt64, _ right: UInt64) throws -> UInt64 {
    let (value, overflow) = left.addingReportingOverflow(right)
    guard !overflow else {
        throw MacOSInstallerArchiveLayoutInspectorError.invalidArchive
    }
    return value
}
