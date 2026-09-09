import CryptoKit
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

        return try inspectOpenArchive(
            descriptor,
            expectedByteCount: expectedByteCount
        ).inspection
    }

    /// Parses one archive through the already-open, no-follow descriptor and
    /// returns the exact local-data offsets bound to its central-directory
    /// entries.  The later stored-entry extractor calls this method on the
    /// same descriptor from which it copies bytes; no URL is re-opened between
    /// layout admission and extraction.
    fileprivate func inspectOpenArchive(
        _ descriptor: Int32,
        expectedByteCount: UInt64
    ) throws -> ZIPArchiveAdmission {
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
        let localDataOffsets = try validateLocalHeaders(
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
        return ZIPArchiveAdmission(
            inspection: ZIPArchiveInspection(
                layout: layout,
                observation: finalObservation
            ),
            entries: entries,
            localDataOffsets: localDataOffsets
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
    ) throws -> [UInt64] {
        var localRanges: [ZIPByteRange] = []
        localRanges.reserveCapacity(entries.count)
        var localDataOffsets: [UInt64] = []
        localDataOffsets.reserveCapacity(entries.count)

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
            localDataOffsets.append(dataOffset)
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
        return localDataOffsets
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

    fileprivate func secureArchiveObservation(_ descriptor: Int32) throws -> ZIPArchiveFileObservation {
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

fileprivate enum MacOSInstallerArchiveLayoutInspectorError: Error {
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

fileprivate struct ZIPCentralDirectoryEntry {
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

fileprivate struct ZIPArchivePath {
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

fileprivate struct ZIPArchiveFileObservation: Equatable {
    let device: dev_t
    let inode: ino_t
    let byteCount: UInt64
    let modificationSeconds: Int
    let modificationNanoseconds: Int
    let changeSeconds: Int
    let changeNanoseconds: Int
}

fileprivate struct ZIPArchiveInspection: Equatable {
    let layout: MacOSInstallerArchiveLayout
    let observation: ZIPArchiveFileObservation
}

/// Internal proof used only by the layout inspector and the stored-entry
/// extractor in this source file.  It deliberately contains descriptor-bound
/// offsets rather than URLs or destination paths.
fileprivate struct ZIPArchiveAdmission {
    let inspection: ZIPArchiveInspection
    let entries: [ZIPCentralDirectoryEntry]
    let localDataOffsets: [UInt64]
}

fileprivate struct ZIPArchiveFileReader {
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

// MARK: - Stored-entry staged archive extraction

/// Resolves one already staged installer archive to a private, fully written
/// macOS app bundle.  The public boundary accepts only the opaque staged asset
/// and the existing archive resolver; it deliberately has no URL, command,
/// destination path, component-installation or launch input.
///
/// The extractor implements a deliberately narrow archive profile.  The
/// layout inspector admits ZIP `stored` and `deflate` entries for read-only
/// qualification, but this type extracts *only* `stored` entries.  Adding a
/// decompressor requires its own bounded streaming and parser proof instead of
/// silently widening this trust boundary.
///
/// `extractionRoot` is selected by trusted packaged-runtime assembly, never by
/// wizard input or a product component.  It is canonicalised only through its
/// existing parent and is then required to be an effective-user-owned `0700`
/// directory.  All state below it is named from fixed constants or a hash of
/// the opaque staged identity.
public struct MacOSStagedInstallerArchiveExtractor: MacOSStagedInstallerBundleResolving {
    public static let defaultMaximumArchiveBytes = MacOSInstallerArchiveLayoutInspector.defaultMaximumArchiveBytes
    public static let defaultMaximumCentralDirectoryBytes = MacOSInstallerArchiveLayoutInspector.defaultMaximumCentralDirectoryBytes
    public static let defaultMaximumEntryCount = MacOSInstallerArchiveLayoutInspector.defaultMaximumEntryCount
    public static let defaultMaximumPathBytes = MacOSInstallerArchiveLayoutInspector.defaultMaximumPathBytes
    public static let defaultMaximumTotalUncompressedBytes = MacOSInstallerArchiveLayoutInspector.defaultMaximumTotalUncompressedBytes

    private static let extractionDirectoryName = "installer-update-extractions-v1"
    private static let candidateDirectoryName = "candidate"
    private static let readyDirectoryName = "ready"
    private static let bindingFileName = "archive-binding-v1"
    private static let maximumBindingBytes = 4 * 1024
    private static let copyBufferBytes = 64 * 1024

    private let extractionRoot: URL
    private let archiveResolver: any MacOSInstallerArchiveStagingResolving
    private let layoutInspector: MacOSInstallerArchiveLayoutInspector

    public init(
        extractionRoot: URL,
        archiveResolver: any MacOSInstallerArchiveStagingResolving,
        maximumArchiveBytes: Int = MacOSStagedInstallerArchiveExtractor.defaultMaximumArchiveBytes,
        maximumCentralDirectoryBytes: Int = MacOSStagedInstallerArchiveExtractor.defaultMaximumCentralDirectoryBytes,
        maximumEntryCount: Int = MacOSStagedInstallerArchiveExtractor.defaultMaximumEntryCount,
        maximumPathBytes: Int = MacOSStagedInstallerArchiveExtractor.defaultMaximumPathBytes,
        maximumTotalUncompressedBytes: UInt64 = MacOSStagedInstallerArchiveExtractor.defaultMaximumTotalUncompressedBytes
    ) throws {
        self.extractionRoot = Self.canonicalStateRoot(for: extractionRoot)
        self.archiveResolver = archiveResolver
        self.layoutInspector = try MacOSInstallerArchiveLayoutInspector(
            maximumArchiveBytes: maximumArchiveBytes,
            maximumCentralDirectoryBytes: maximumCentralDirectoryBytes,
            maximumEntryCount: maximumEntryCount,
            maximumPathBytes: maximumPathBytes,
            maximumTotalUncompressedBytes: maximumTotalUncompressedBytes
        )
    }

    /// Resolves only a complete `ready` bundle.  A failed extraction leaves a
    /// private `candidate` directory deliberately unresolvable: this bounded
    /// foundation neither hands it off nor performs a broad recursive cleanup.
    /// A later operation-owned recovery increment can make the exact cleanup
    /// decision with durable evidence; retries never return a candidate.
    public func resolveStagedInstallerBundle(
        _ stagedAsset: StagedInstallerAsset
    ) async -> Result<URL, InstallerSelfUpdateFailure> {
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
        switch await archiveResolver.resolveStagedInstallerArchive(stagedAsset) {
        case .success(let resolvedURL):
            initialURL = resolvedURL
        case .failure(let failure):
            return .failure(failure)
        }

        do {
            let archiveDescriptor = try openArchive(at: initialURL)
            defer { _ = Darwin.close(archiveDescriptor) }
            let initialAdmission = try inspectStoredArchive(
                descriptor: archiveDescriptor,
                expectedByteCount: stagedAsset.fileIdentity.byteCount
            )
            let operationName = Self.operationDirectoryName(for: stagedAsset)

            let stateRootDescriptor = try requirePrivateStateRoot()
            defer { _ = Darwin.close(stateRootDescriptor) }
            let extractionDescriptor = try openOrCreatePrivateDirectory(
                named: Self.extractionDirectoryName,
                in: stateRootDescriptor
            )
            defer { _ = Darwin.close(extractionDescriptor) }

            if let existingOperationDescriptor = try openPrivateDirectoryIfPresent(
                named: operationName,
                in: extractionDescriptor
            ) {
                defer { _ = Darwin.close(existingOperationDescriptor) }
                let readyURL = try await resolveExistingReadyBundle(
                    stagedAsset: stagedAsset,
                    initialURL: initialURL,
                    initialArchiveDescriptor: archiveDescriptor,
                    initialAdmission: initialAdmission,
                    operationName: operationName,
                    operationDescriptor: existingOperationDescriptor
                )
                return .success(readyURL)
            }

            let operationDescriptor = try createPrivateDirectory(
                named: operationName,
                in: extractionDescriptor
            )
            defer { _ = Darwin.close(operationDescriptor) }
            let candidateDescriptor = try createPrivateDirectory(
                named: Self.candidateDirectoryName,
                in: operationDescriptor
            )
            do {
                defer { _ = Darwin.close(candidateDescriptor) }
                try extractStoredBundle(
                    admission: initialAdmission,
                    archiveDescriptor: archiveDescriptor,
                    into: candidateDescriptor,
                    stagedAsset: stagedAsset
                )
                try verifyExtractedBundle(
                    in: candidateDescriptor,
                    admission: initialAdmission,
                    stagedAsset: stagedAsset
                )
                guard try layoutInspector.secureArchiveObservation(archiveDescriptor)
                    == initialAdmission.inspection.observation else {
                    throw MacOSStagedInstallerArchiveExtractionError.identityChanged
                }
            }

            let finalAdmission = try await resolveFinalStoredArchive(
                stagedAsset: stagedAsset,
                initialURL: initialURL
            )
            guard zipArchiveAdmissionsMatch(initialAdmission, finalAdmission) else {
                throw MacOSStagedInstallerArchiveExtractionError.identityChanged
            }
            try verifyExtractedBundleAtOperationPath(
                operationDescriptor: operationDescriptor,
                stateDirectoryName: Self.candidateDirectoryName,
                admission: finalAdmission,
                stagedAsset: stagedAsset
            )
            guard try layoutInspector.secureArchiveObservation(archiveDescriptor)
                == initialAdmission.inspection.observation else {
                throw MacOSStagedInstallerArchiveExtractionError.identityChanged
            }
            try promoteCandidate(in: operationDescriptor)
            // `renameatx_np` is the only transition that makes a candidate
            // addressable as ready.  Re-open the destination through a fresh
            // no-follow descriptor before returning its URL so a same-user
            // replacement of the source name cannot turn promotion into an
            // unchecked URL handoff.
            guard let readyDescriptor = try openPrivateDirectoryIfPresent(
                named: Self.readyDirectoryName,
                in: operationDescriptor
            ) else {
                throw MacOSStagedInstallerArchiveExtractionError.insecureFilesystem
            }
            defer { _ = Darwin.close(readyDescriptor) }
            try verifyExtractedBundle(
                in: readyDescriptor,
                admission: finalAdmission,
                stagedAsset: stagedAsset
            )
            guard try layoutInspector.secureArchiveObservation(archiveDescriptor)
                == initialAdmission.inspection.observation else {
                throw MacOSStagedInstallerArchiveExtractionError.identityChanged
            }
            return .success(readyBundleURL(
                operationName: operationName,
                appBundleRoot: finalAdmission.inspection.layout.appBundleRoot
            ))
        } catch MacOSInstallerArchiveLayoutInspectorError.identityChanged,
                MacOSStagedInstallerArchiveExtractionError.identityChanged {
            return .failure(InstallerSelfUpdateFailure(.stagedAssetIdentityChanged))
        } catch {
            return .failure(InstallerSelfUpdateFailure(.stagingFailed))
        }
    }

    private func resolveExistingReadyBundle(
        stagedAsset: StagedInstallerAsset,
        initialURL: URL,
        initialArchiveDescriptor: Int32,
        initialAdmission: ZIPArchiveAdmission,
        operationName: String,
        operationDescriptor: Int32
    ) async throws -> URL {
        // A crash or rejected write can leave only `candidate`.  It is never a
        // usable bundle, and its presence alongside `ready` is an unresolved
        // state rather than an invitation to choose one arbitrarily.
        if let candidate = try openPrivateDirectoryIfPresent(
            named: Self.candidateDirectoryName,
            in: operationDescriptor
        ) {
            _ = Darwin.close(candidate)
            throw MacOSStagedInstallerArchiveExtractionError.incompleteCandidate
        }
        guard let readyDescriptor = try openPrivateDirectoryIfPresent(
            named: Self.readyDirectoryName,
            in: operationDescriptor
        ) else {
            throw MacOSStagedInstallerArchiveExtractionError.incompleteCandidate
        }
        defer { _ = Darwin.close(readyDescriptor) }

        try verifyExtractedBundle(
            in: readyDescriptor,
            admission: initialAdmission,
            stagedAsset: stagedAsset
        )
        guard try layoutInspector.secureArchiveObservation(initialArchiveDescriptor)
            == initialAdmission.inspection.observation else {
            throw MacOSStagedInstallerArchiveExtractionError.identityChanged
        }

        let finalAdmission = try await resolveFinalStoredArchive(
            stagedAsset: stagedAsset,
            initialURL: initialURL
        )
        guard zipArchiveAdmissionsMatch(initialAdmission, finalAdmission) else {
            throw MacOSStagedInstallerArchiveExtractionError.identityChanged
        }
        try verifyExtractedBundle(
            in: readyDescriptor,
            admission: finalAdmission,
            stagedAsset: stagedAsset
        )
        guard try layoutInspector.secureArchiveObservation(initialArchiveDescriptor)
            == initialAdmission.inspection.observation else {
            throw MacOSStagedInstallerArchiveExtractionError.identityChanged
        }
        return readyBundleURL(
            operationName: operationName,
            appBundleRoot: finalAdmission.inspection.layout.appBundleRoot
        )
    }

    private func resolveFinalStoredArchive(
        stagedAsset: StagedInstallerAsset,
        initialURL: URL
    ) async throws -> ZIPArchiveAdmission {
        let finalURL: URL
        switch await archiveResolver.resolveStagedInstallerArchive(stagedAsset) {
        case .success(let resolvedURL):
            finalURL = resolvedURL
        case .failure:
            throw MacOSStagedInstallerArchiveExtractionError.identityChanged
        }
        guard finalURL.standardizedFileURL == initialURL.standardizedFileURL else {
            throw MacOSStagedInstallerArchiveExtractionError.identityChanged
        }
        let finalDescriptor = try openArchive(at: finalURL)
        defer { _ = Darwin.close(finalDescriptor) }
        let finalAdmission = try inspectStoredArchive(
            descriptor: finalDescriptor,
            expectedByteCount: stagedAsset.fileIdentity.byteCount
        )
        try verifyStoredArchivePayloads(
            descriptor: finalDescriptor,
            admission: finalAdmission
        )
        return finalAdmission
    }

    private func inspectStoredArchive(
        descriptor: Int32,
        expectedByteCount: UInt64
    ) throws -> ZIPArchiveAdmission {
        let admission = try layoutInspector.inspectOpenArchive(
            descriptor,
            expectedByteCount: expectedByteCount
        )
        guard admission.entries.allSatisfy({ $0.compression == .stored }) else {
            throw MacOSStagedInstallerArchiveExtractionError.invalidArchive
        }
        return admission
    }

    private func extractStoredBundle(
        admission: ZIPArchiveAdmission,
        archiveDescriptor: Int32,
        into candidateDescriptor: Int32,
        stagedAsset: StagedInstallerAsset
    ) throws {
        let reader = ZIPArchiveFileReader(
            descriptor: archiveDescriptor,
            fileSize: admission.inspection.observation.byteCount
        )
        let directoryEntries = admission.entries
            .filter { $0.path.isDirectory }
            .sorted { left, right in
                if left.path.components.count != right.path.components.count {
                    return left.path.components.count < right.path.components.count
                }
                return left.path.canonical < right.path.canonical
            }
        var createdDirectories = Set<String>()
        for entry in directoryEntries {
            try createExactDirectoryPath(
                entry.path.components,
                in: candidateDescriptor,
                createdDirectories: &createdDirectories
            )
        }

        for (entry, dataOffset) in zip(admission.entries, admission.localDataOffsets) where !entry.path.isDirectory {
            try writeStoredEntry(
                entry,
                dataOffset: dataOffset,
                using: reader,
                into: candidateDescriptor
            )
        }
        let binding = Self.bindingData(
            for: stagedAsset,
            admission: admission
        )
        try writePrivateBinding(binding, in: candidateDescriptor)
        try durableSync(candidateDescriptor)
    }

    private func verifyExtractedBundleAtOperationPath(
        operationDescriptor: Int32,
        stateDirectoryName: String,
        admission: ZIPArchiveAdmission,
        stagedAsset: StagedInstallerAsset
    ) throws {
        guard let stateDescriptor = try openPrivateDirectoryIfPresent(
            named: stateDirectoryName,
            in: operationDescriptor
        ) else {
            throw MacOSStagedInstallerArchiveExtractionError.insecureFilesystem
        }
        defer { _ = Darwin.close(stateDescriptor) }
        try verifyExtractedBundle(
            in: stateDescriptor,
            admission: admission,
            stagedAsset: stagedAsset
        )
    }

    private func verifyExtractedBundle(
        in stateDescriptor: Int32,
        admission: ZIPArchiveAdmission,
        stagedAsset: StagedInstallerAsset
    ) throws {
        let expectedBinding = Self.bindingData(for: stagedAsset, admission: admission)
        let actualBinding = try readPrivateBinding(in: stateDescriptor)
        guard actualBinding == expectedBinding else {
            throw MacOSStagedInstallerArchiveExtractionError.insecureFilesystem
        }

        let directoryEntries = admission.entries
            .filter { $0.path.isDirectory }
            .sorted { $0.path.components.count < $1.path.components.count }
        for entry in directoryEntries {
            let descriptor = try openExactDirectoryPath(
                entry.path.components,
                in: stateDescriptor
            )
            _ = try securePrivateDirectoryObservation(descriptor)
            _ = Darwin.close(descriptor)
        }
        for entry in admission.entries where !entry.path.isDirectory {
            try verifyExtractedRegularFile(entry, in: stateDescriptor)
        }
    }

    private func writeStoredEntry(
        _ entry: ZIPCentralDirectoryEntry,
        dataOffset: UInt64,
        using reader: ZIPArchiveFileReader,
        into rootDescriptor: Int32
    ) throws {
        guard let fileName = entry.path.components.last else {
            throw MacOSStagedInstallerArchiveExtractionError.invalidArchive
        }
        let parentDescriptor = try openExactDirectoryPath(
            Array(entry.path.components.dropLast()),
            in: rootDescriptor
        )
        defer { _ = Darwin.close(parentDescriptor) }
        let expectedMode: mode_t = (entry.externalAttributes >> 16) & 0o100 != 0 ? 0o700 : 0o600
        let descriptor = fileName.withCString { name in
            Darwin.openat(
                parentDescriptor,
                name,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW_ANY,
                mode_t(0o600)
            )
        }
        guard descriptor >= 0 else {
            throw MacOSStagedInstallerArchiveExtractionError.insecureFilesystem
        }
        defer { _ = Darwin.close(descriptor) }
        guard Darwin.fchmod(descriptor, expectedMode) == 0 else {
            throw MacOSStagedInstallerArchiveExtractionError.insecureFilesystem
        }

        var remaining = entry.uncompressedByteCount
        var offset = dataOffset
        var crc32 = ZIPCRC32()
        while remaining > 0 {
            let chunkByteCount = Int(min(UInt64(Self.copyBufferBytes), remaining))
            let bytes = try reader.read(offset: offset, count: chunkByteCount)
            try writeAll(bytes, to: descriptor)
            crc32.update(bytes)
            offset = try checkedAdd(offset, UInt64(bytes.count))
            remaining -= UInt64(bytes.count)
        }
        guard crc32.checksum == entry.crc32 else {
            throw MacOSStagedInstallerArchiveExtractionError.invalidArchive
        }
        try durableSync(descriptor)
        _ = try securePrivateRegularFileObservation(
            descriptor,
            expectedMode: expectedMode,
            expectedByteCount: entry.uncompressedByteCount
        )
        try durableSync(parentDescriptor)
    }

    private func verifyStoredArchivePayloads(
        descriptor: Int32,
        admission: ZIPArchiveAdmission
    ) throws {
        let reader = ZIPArchiveFileReader(
            descriptor: descriptor,
            fileSize: admission.inspection.observation.byteCount
        )
        for (entry, dataOffset) in zip(admission.entries, admission.localDataOffsets) where !entry.path.isDirectory {
            var remaining = entry.uncompressedByteCount
            var offset = dataOffset
            var crc32 = ZIPCRC32()
            while remaining > 0 {
                let byteCount = Int(min(UInt64(Self.copyBufferBytes), remaining))
                let bytes = try reader.read(offset: offset, count: byteCount)
                crc32.update(bytes)
                offset = try checkedAdd(offset, UInt64(bytes.count))
                remaining -= UInt64(bytes.count)
            }
            guard crc32.checksum == entry.crc32 else {
                throw MacOSStagedInstallerArchiveExtractionError.invalidArchive
            }
        }
        guard try layoutInspector.secureArchiveObservation(descriptor)
            == admission.inspection.observation else {
            throw MacOSStagedInstallerArchiveExtractionError.identityChanged
        }
    }

    private func verifyExtractedRegularFile(
        _ entry: ZIPCentralDirectoryEntry,
        in rootDescriptor: Int32
    ) throws {
        guard let fileName = entry.path.components.last else {
            throw MacOSStagedInstallerArchiveExtractionError.invalidArchive
        }
        let parentDescriptor = try openExactDirectoryPath(
            Array(entry.path.components.dropLast()),
            in: rootDescriptor
        )
        defer { _ = Darwin.close(parentDescriptor) }
        let descriptor = fileName.withCString { name in
            Darwin.openat(parentDescriptor, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard descriptor >= 0 else {
            throw MacOSStagedInstallerArchiveExtractionError.insecureFilesystem
        }
        defer { _ = Darwin.close(descriptor) }
        let expectedMode: mode_t = (entry.externalAttributes >> 16) & 0o100 != 0 ? 0o700 : 0o600
        let initialObservation = try securePrivateRegularFileObservation(
            descriptor,
            expectedMode: expectedMode,
            expectedByteCount: entry.uncompressedByteCount
        )
        var remaining = entry.uncompressedByteCount
        var crc32 = ZIPCRC32()
        var buffer = [UInt8](repeating: 0, count: Self.copyBufferBytes)
        while remaining > 0 {
            let requested = Int(min(UInt64(buffer.count), remaining))
            let byteCount = buffer.withUnsafeMutableBytes { rawBuffer -> ssize_t in
                Darwin.read(descriptor, rawBuffer.baseAddress, requested)
            }
            if byteCount < 0 {
                if errno == EINTR {
                    continue
                }
                throw MacOSStagedInstallerArchiveExtractionError.insecureFilesystem
            }
            guard byteCount > 0 else {
                throw MacOSStagedInstallerArchiveExtractionError.insecureFilesystem
            }
            let bytes = Data(buffer.prefix(Int(byteCount)))
            crc32.update(bytes)
            remaining -= UInt64(byteCount)
        }
        guard crc32.checksum == entry.crc32,
              try securePrivateRegularFileObservation(
                descriptor,
                expectedMode: expectedMode,
                expectedByteCount: entry.uncompressedByteCount
              ) == initialObservation else {
            throw MacOSStagedInstallerArchiveExtractionError.insecureFilesystem
        }
    }

    private func createExactDirectoryPath(
        _ components: [String],
        in rootDescriptor: Int32,
        createdDirectories: inout Set<String>
    ) throws {
        guard !components.isEmpty else {
            throw MacOSStagedInstallerArchiveExtractionError.invalidArchive
        }
        var currentDescriptor = Darwin.dup(rootDescriptor)
        guard currentDescriptor >= 0 else {
            throw MacOSStagedInstallerArchiveExtractionError.insecureFilesystem
        }
        defer { _ = Darwin.close(currentDescriptor) }
        var currentPath = ""
        for component in components {
            guard Self.isSafeExtractedPathComponent(component) else {
                throw MacOSStagedInstallerArchiveExtractionError.invalidArchive
            }
            currentPath = currentPath.isEmpty ? component : "\(currentPath)/\(component)"
            let mkdirResult = component.withCString { name in
                Darwin.mkdirat(currentDescriptor, name, mode_t(0o700))
            }
            // The only permitted pre-existing directory is an explicitly
            // created archive parent.  Any unexpected object/race fails
            // before a child name is ever opened.
            guard mkdirResult == 0 || (errno == EEXIST && createdDirectories.contains(currentPath)) else {
                throw MacOSStagedInstallerArchiveExtractionError.insecureFilesystem
            }
            let nextDescriptor = component.withCString { name in
                Darwin.openat(
                    currentDescriptor,
                    name,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY
                )
            }
            guard nextDescriptor >= 0 else {
                throw MacOSStagedInstallerArchiveExtractionError.insecureFilesystem
            }
            if mkdirResult == 0 {
                guard Darwin.fchmod(nextDescriptor, mode_t(0o700)) == 0 else {
                    _ = Darwin.close(nextDescriptor)
                    throw MacOSStagedInstallerArchiveExtractionError.insecureFilesystem
                }
                try durableSync(currentDescriptor)
                try durableSync(nextDescriptor)
                createdDirectories.insert(currentPath)
            }
            _ = try securePrivateDirectoryObservation(nextDescriptor)
            _ = Darwin.close(currentDescriptor)
            currentDescriptor = nextDescriptor
        }
    }

    private func openExactDirectoryPath(
        _ components: [String],
        in rootDescriptor: Int32
    ) throws -> Int32 {
        var currentDescriptor = Darwin.dup(rootDescriptor)
        guard currentDescriptor >= 0 else {
            throw MacOSStagedInstallerArchiveExtractionError.insecureFilesystem
        }
        for component in components {
            guard Self.isSafeExtractedPathComponent(component) else {
                _ = Darwin.close(currentDescriptor)
                throw MacOSStagedInstallerArchiveExtractionError.invalidArchive
            }
            let nextDescriptor = component.withCString { name in
                Darwin.openat(
                    currentDescriptor,
                    name,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY
                )
            }
            _ = Darwin.close(currentDescriptor)
            guard nextDescriptor >= 0 else {
                throw MacOSStagedInstallerArchiveExtractionError.insecureFilesystem
            }
            do {
                _ = try securePrivateDirectoryObservation(nextDescriptor)
            } catch {
                _ = Darwin.close(nextDescriptor)
                throw error
            }
            currentDescriptor = nextDescriptor
        }
        return currentDescriptor
    }

    private func requirePrivateStateRoot() throws -> Int32 {
        let creationResult = extractionRoot.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.mkdir(path, mode_t(0o700))
        }
        let wasCreated = creationResult == 0
        guard wasCreated || errno == EEXIST else {
            throw MacOSStagedInstallerArchiveExtractionError.insecureFilesystem
        }
        let descriptor = extractionRoot.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard descriptor >= 0 else {
            throw MacOSStagedInstallerArchiveExtractionError.insecureFilesystem
        }
        do {
            if wasCreated {
                guard Darwin.fchmod(descriptor, mode_t(0o700)) == 0 else {
                    throw MacOSStagedInstallerArchiveExtractionError.insecureFilesystem
                }
            }
            _ = try securePrivateDirectoryObservation(descriptor)
            if wasCreated {
                try durableSync(descriptor)
            }
            return descriptor
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    private func openOrCreatePrivateDirectory(
        named name: String,
        in parentDescriptor: Int32
    ) throws -> Int32 {
        if let descriptor = try openPrivateDirectoryIfPresent(named: name, in: parentDescriptor) {
            return descriptor
        }
        // A concurrent creator, or a failure after `mkdirat`, is not accepted
        // opportunistically.  Failing closed here avoids treating a directory
        // whose creation/durability sequence was interrupted as trustworthy.
        return try createPrivateDirectory(named: name, in: parentDescriptor)
    }

    private func createPrivateDirectory(
        named name: String,
        in parentDescriptor: Int32
    ) throws -> Int32 {
        guard Self.isSafeInternalDirectoryName(name) else {
            throw MacOSStagedInstallerArchiveExtractionError.insecureFilesystem
        }
        let mkdirResult = name.withCString { directoryName in
            Darwin.mkdirat(parentDescriptor, directoryName, mode_t(0o700))
        }
        guard mkdirResult == 0 else {
            throw MacOSStagedInstallerArchiveExtractionError.insecureFilesystem
        }
        let descriptor = name.withCString { directoryName in
            Darwin.openat(
                parentDescriptor,
                directoryName,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY
            )
        }
        guard descriptor >= 0 else {
            throw MacOSStagedInstallerArchiveExtractionError.insecureFilesystem
        }
        do {
            guard Darwin.fchmod(descriptor, mode_t(0o700)) == 0 else {
                throw MacOSStagedInstallerArchiveExtractionError.insecureFilesystem
            }
            _ = try securePrivateDirectoryObservation(descriptor)
            try durableSync(descriptor)
            try durableSync(parentDescriptor)
            return descriptor
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    private func openPrivateDirectoryIfPresent(
        named name: String,
        in parentDescriptor: Int32
    ) throws -> Int32? {
        guard Self.isSafeInternalDirectoryName(name) else {
            throw MacOSStagedInstallerArchiveExtractionError.insecureFilesystem
        }
        let descriptor = name.withCString { directoryName in
            Darwin.openat(
                parentDescriptor,
                directoryName,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY
            )
        }
        if descriptor < 0 {
            guard errno == ENOENT else {
                throw MacOSStagedInstallerArchiveExtractionError.insecureFilesystem
            }
            return nil
        }
        do {
            _ = try securePrivateDirectoryObservation(descriptor)
            return descriptor
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    private func writePrivateBinding(
        _ binding: Data,
        in directoryDescriptor: Int32
    ) throws {
        guard !binding.isEmpty, binding.count <= Self.maximumBindingBytes else {
            throw MacOSStagedInstallerArchiveExtractionError.invalidArchive
        }
        let descriptor = Self.bindingFileName.withCString { name in
            Darwin.openat(
                directoryDescriptor,
                name,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW_ANY,
                mode_t(0o600)
            )
        }
        guard descriptor >= 0 else {
            throw MacOSStagedInstallerArchiveExtractionError.insecureFilesystem
        }
        defer { _ = Darwin.close(descriptor) }
        guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw MacOSStagedInstallerArchiveExtractionError.insecureFilesystem
        }
        try writeAll(binding, to: descriptor)
        try durableSync(descriptor)
        _ = try securePrivateRegularFileObservation(
            descriptor,
            expectedMode: mode_t(0o600),
            expectedByteCount: UInt64(binding.count)
        )
        try durableSync(directoryDescriptor)
    }

    private func readPrivateBinding(in directoryDescriptor: Int32) throws -> Data {
        let descriptor = Self.bindingFileName.withCString { name in
            Darwin.openat(directoryDescriptor, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard descriptor >= 0 else {
            throw MacOSStagedInstallerArchiveExtractionError.insecureFilesystem
        }
        defer { _ = Darwin.close(descriptor) }
        let initialObservation = try securePrivateRegularFileObservation(
            descriptor,
            expectedMode: mode_t(0o600),
            expectedByteCount: nil
        )
        guard initialObservation.byteCount > 0,
              initialObservation.byteCount <= UInt64(Self.maximumBindingBytes),
              initialObservation.byteCount <= UInt64(Int.max) else {
            throw MacOSStagedInstallerArchiveExtractionError.insecureFilesystem
        }
        var data = Data()
        data.reserveCapacity(Int(initialObservation.byteCount))
        var buffer = [UInt8](repeating: 0, count: min(Self.copyBufferBytes, Int(initialObservation.byteCount)))
        while data.count < Int(initialObservation.byteCount) {
            let requestByteCount = min(buffer.count, Int(initialObservation.byteCount) - data.count)
            let readByteCount = buffer.withUnsafeMutableBytes { rawBuffer -> ssize_t in
                Darwin.read(descriptor, rawBuffer.baseAddress, requestByteCount)
            }
            if readByteCount < 0 {
                if errno == EINTR {
                    continue
                }
                throw MacOSStagedInstallerArchiveExtractionError.insecureFilesystem
            }
            guard readByteCount > 0 else {
                throw MacOSStagedInstallerArchiveExtractionError.insecureFilesystem
            }
            data.append(contentsOf: buffer.prefix(Int(readByteCount)))
        }
        guard try securePrivateRegularFileObservation(
            descriptor,
            expectedMode: mode_t(0o600),
            expectedByteCount: initialObservation.byteCount
        ) == initialObservation else {
            throw MacOSStagedInstallerArchiveExtractionError.insecureFilesystem
        }
        return data
    }

    private func promoteCandidate(in operationDescriptor: Int32) throws {
        let renameResult = Self.candidateDirectoryName.withCString { candidateName in
            Self.readyDirectoryName.withCString { readyName in
                Darwin.renameatx_np(
                    operationDescriptor,
                    candidateName,
                    operationDescriptor,
                    readyName,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard renameResult == 0 else {
            throw MacOSStagedInstallerArchiveExtractionError.insecureFilesystem
        }
        try durableSync(operationDescriptor)
    }

    private func readyBundleURL(operationName: String, appBundleRoot: String) -> URL {
        extractionRoot
            .appendingPathComponent(Self.extractionDirectoryName, isDirectory: true)
            .appendingPathComponent(operationName, isDirectory: true)
            .appendingPathComponent(Self.readyDirectoryName, isDirectory: true)
            .appendingPathComponent(appBundleRoot, isDirectory: true)
    }

    private func openArchive(at url: URL) throws -> Int32 {
        guard url.isFileURL else {
            throw MacOSStagedInstallerArchiveExtractionError.identityChanged
        }
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard descriptor >= 0 else {
            throw MacOSStagedInstallerArchiveExtractionError.identityChanged
        }
        return descriptor
    }

    private static func operationDirectoryName(for stagedAsset: StagedInstallerAsset) -> String {
        var material = Data("forge-platform-installer-staged-extraction-v1".utf8)
        appendBindingField(stagedAsset.releaseAssetName, to: &material)
        appendBindingField(stagedAsset.opaqueReference, to: &material)
        appendBindingField(stagedAsset.fileIdentity.volumeReference, to: &material)
        appendBindingField(stagedAsset.fileIdentity.fileReference, to: &material)
        appendBindingField(String(stagedAsset.fileIdentity.byteCount), to: &material)
        let digest = SHA256.hash(data: material)
        return "archive-" + digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func bindingData(
        for stagedAsset: StagedInstallerAsset,
        admission: ZIPArchiveAdmission
    ) -> Data {
        let observation = admission.inspection.observation
        var data = Data("forge-platform-installer-extraction-binding-v1".utf8)
        appendBindingField(stagedAsset.releaseAssetName, to: &data)
        appendBindingField(stagedAsset.opaqueReference, to: &data)
        appendBindingField(stagedAsset.fileIdentity.volumeReference, to: &data)
        appendBindingField(stagedAsset.fileIdentity.fileReference, to: &data)
        appendBindingField(String(stagedAsset.fileIdentity.byteCount), to: &data)
        appendBindingField(String(observation.device), to: &data)
        appendBindingField(String(observation.inode), to: &data)
        appendBindingField(String(observation.byteCount), to: &data)
        appendBindingField(String(observation.modificationSeconds), to: &data)
        appendBindingField(String(observation.modificationNanoseconds), to: &data)
        appendBindingField(String(observation.changeSeconds), to: &data)
        appendBindingField(String(observation.changeNanoseconds), to: &data)
        appendBindingField(admission.inspection.layout.appBundleRoot, to: &data)
        return data
    }

    private static func appendBindingField(_ field: String, to data: inout Data) {
        let bytes = Data(field.utf8)
        var byteCount = UInt64(bytes.count).bigEndian
        withUnsafeBytes(of: &byteCount) { data.append(contentsOf: $0) }
        data.append(bytes)
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

    private static func isSafeExtractedPathComponent(_ value: String) -> Bool {
        guard !value.isEmpty,
              value != ".",
              value != "..",
              !value.contains("/"),
              !value.contains("\\"),
              !value.contains("\u{0}") else {
            return false
        }
        return value.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57)
                || (scalar.value >= 65 && scalar.value <= 90)
                || (scalar.value >= 97 && scalar.value <= 122)
                || scalar.value == 32
                || scalar.value == 43
                || scalar.value == 45
                || scalar.value == 46
                || scalar.value == 95
        }
    }
}

private enum MacOSStagedInstallerArchiveExtractionError: Error {
    case invalidArchive
    case identityChanged
    case insecureFilesystem
    case incompleteCandidate
}

private struct PrivateDirectoryObservation: Equatable {
    let device: dev_t
    let inode: ino_t
    let modificationSeconds: Int
    let modificationNanoseconds: Int
    let changeSeconds: Int
    let changeNanoseconds: Int
}

private struct PrivateRegularFileObservation: Equatable {
    let device: dev_t
    let inode: ino_t
    let byteCount: UInt64
    let modificationSeconds: Int
    let modificationNanoseconds: Int
    let changeSeconds: Int
    let changeNanoseconds: Int
}

private func securePrivateDirectoryObservation(_ descriptor: Int32) throws -> PrivateDirectoryObservation {
    var details = stat()
    guard Darwin.fstat(descriptor, &details) == 0,
          (details.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
          details.st_uid == Darwin.geteuid(),
          (details.st_mode & mode_t(0o7777)) == mode_t(0o700) else {
        throw MacOSStagedInstallerArchiveExtractionError.insecureFilesystem
    }
    return PrivateDirectoryObservation(
        device: details.st_dev,
        inode: details.st_ino,
        modificationSeconds: details.st_mtimespec.tv_sec,
        modificationNanoseconds: details.st_mtimespec.tv_nsec,
        changeSeconds: details.st_ctimespec.tv_sec,
        changeNanoseconds: details.st_ctimespec.tv_nsec
    )
}

private func securePrivateRegularFileObservation(
    _ descriptor: Int32,
    expectedMode: mode_t,
    expectedByteCount: UInt64?
) throws -> PrivateRegularFileObservation {
    var details = stat()
    guard Darwin.fstat(descriptor, &details) == 0,
          (details.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
          details.st_uid == Darwin.geteuid(),
          details.st_nlink == 1,
          (details.st_mode & mode_t(0o7777)) == expectedMode,
          details.st_size >= 0 else {
        throw MacOSStagedInstallerArchiveExtractionError.insecureFilesystem
    }
    let byteCount = UInt64(details.st_size)
    guard expectedByteCount == nil || expectedByteCount == byteCount else {
        throw MacOSStagedInstallerArchiveExtractionError.insecureFilesystem
    }
    return PrivateRegularFileObservation(
        device: details.st_dev,
        inode: details.st_ino,
        byteCount: byteCount,
        modificationSeconds: details.st_mtimespec.tv_sec,
        modificationNanoseconds: details.st_mtimespec.tv_nsec,
        changeSeconds: details.st_ctimespec.tv_sec,
        changeNanoseconds: details.st_ctimespec.tv_nsec
    )
}

private func writeAll(_ data: Data, to descriptor: Int32) throws {
    guard !data.isEmpty else {
        return
    }
    try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
        guard let baseAddress = buffer.baseAddress else {
            throw MacOSStagedInstallerArchiveExtractionError.insecureFilesystem
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
                throw MacOSStagedInstallerArchiveExtractionError.insecureFilesystem
            }
            guard result > 0 else {
                throw MacOSStagedInstallerArchiveExtractionError.insecureFilesystem
            }
            written += Int(result)
        }
    }
}

private func durableSync(_ descriptor: Int32) throws {
    guard Darwin.fsync(descriptor) == 0 else {
        throw MacOSStagedInstallerArchiveExtractionError.insecureFilesystem
    }
}

private func zipArchiveAdmissionsMatch(
    _ left: ZIPArchiveAdmission,
    _ right: ZIPArchiveAdmission
) -> Bool {
    guard left.inspection == right.inspection,
          left.localDataOffsets == right.localDataOffsets,
          left.entries.count == right.entries.count else {
        return false
    }
    return zip(left.entries, right.entries).allSatisfy { first, second in
        first.path.canonical == second.path.canonical
            && first.path.components == second.path.components
            && first.path.isDirectory == second.path.isDirectory
            && first.versionMadeBy == second.versionMadeBy
            && first.versionNeeded == second.versionNeeded
            && first.generalPurposeFlags == second.generalPurposeFlags
            && first.compression == second.compression
            && first.crc32 == second.crc32
            && first.compressedByteCount == second.compressedByteCount
            && first.uncompressedByteCount == second.uncompressedByteCount
            && first.externalAttributes == second.externalAttributes
            && first.localHeaderOffset == second.localHeaderOffset
            && first.rawFileName == second.rawFileName
    }
}

private struct ZIPCRC32 {
    private static let table: [UInt32] = (0..<256).map { value in
        var remainder = UInt32(value)
        for _ in 0..<8 {
            remainder = (remainder & 1) == 1
                ? 0xedb8_8320 ^ (remainder >> 1)
                : remainder >> 1
        }
        return remainder
    }

    private var value: UInt32 = 0xffff_ffff

    mutating func update(_ data: Data) {
        for byte in data {
            value = Self.table[Int((value ^ UInt32(byte)) & 0xff)] ^ (value >> 8)
        }
    }

    var checksum: UInt32 {
        value ^ 0xffff_ffff
    }
}
