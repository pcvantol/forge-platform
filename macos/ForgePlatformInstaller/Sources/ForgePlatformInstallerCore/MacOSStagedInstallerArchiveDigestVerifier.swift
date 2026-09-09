import CryptoKit
import Darwin
import Foundation

/// Narrow verifier for the exact ZIP bytes selected by a signed installer
/// release descriptor.  It deliberately verifies the archive before any
/// future extractor, app-bundle inspector, or handoff receives it.  The
/// verifier has no network, command, product, provider, or UI-path input.
public protocol StagedInstallerArchiveDigestVerifying: Sendable {
    func verifyStagedInstallerArchiveSHA256(
        _ stagedAsset: StagedInstallerAsset,
        for release: VerifiedInstallerReleaseRecord
    ) async -> Result<Void, InstallerSelfUpdateFailure>
}

/// Descriptor-based, bounded SHA-256 verification for a private staged
/// installer archive.  The resolver can return a URL only after it has
/// re-checked the opaque asset reference and its private staging boundary;
/// this verifier opens the final archive without following a symlink and
/// independently checks immutable file facts before and after hashing.
///
/// This is intentionally not a complete `StagedInstallerArtifactVerifying`
/// implementation. Archive extraction, static app-signature verification,
/// sealed-resource binding, notarization assessment, and atomic handoff each
/// require their own explicit proof boundary. A runtime cannot accidentally
/// treat digest verification alone as authority to launch an archive.
public struct MacOSStagedInstallerArchiveDigestVerifier: StagedInstallerArchiveDigestVerifying {
    private let archiveResolver: any MacOSInstallerArchiveStagingResolving
    private let maximumArchiveBytes: Int

    public init(
        archiveResolver: any MacOSInstallerArchiveStagingResolving,
        maximumArchiveBytes: Int = MacOSInstallerArchiveStaging.defaultMaximumArchiveBytes
    ) throws {
        guard maximumArchiveBytes > 0,
              maximumArchiveBytes <= MacOSInstallerArchiveStaging.absoluteMaximumArchiveBytes else {
            throw MacOSStagedInstallerArchiveDigestVerifierError.invalidConfiguration
        }
        self.archiveResolver = archiveResolver
        self.maximumArchiveBytes = maximumArchiveBytes
    }

    public func verifyStagedInstallerArchiveSHA256(
        _ stagedAsset: StagedInstallerAsset,
        for release: VerifiedInstallerReleaseRecord
    ) async -> Result<Void, InstallerSelfUpdateFailure> {
        guard stagedAsset.releaseAssetName == release.githubAsset.assetName,
              stagedAsset.fileIdentity.byteCount > 0,
              stagedAsset.fileIdentity.byteCount <= UInt64(maximumArchiveBytes) else {
            return .failure(InstallerSelfUpdateFailure(.sha256VerificationFailed))
        }

        let archiveURL: URL
        switch await archiveResolver.resolveStagedInstallerArchive(stagedAsset) {
        case .success(let resolvedURL):
            archiveURL = resolvedURL
        case .failure:
            return .failure(InstallerSelfUpdateFailure(.sha256VerificationFailed))
        }

        do {
            let digest = try sha256(
                ofPrivateArchiveAt: archiveURL,
                expectedByteCount: stagedAsset.fileIdentity.byteCount
            )
            guard digest == release.release.sha256 else {
                return .failure(InstallerSelfUpdateFailure(.sha256VerificationFailed))
            }
            return .success(())
        } catch {
            return .failure(InstallerSelfUpdateFailure(.sha256VerificationFailed))
        }
    }

    private func sha256(
        ofPrivateArchiveAt archiveURL: URL,
        expectedByteCount: UInt64
    ) throws -> String {
        guard archiveURL.isFileURL else {
            throw MacOSStagedInstallerArchiveDigestVerifierError.insecureArchive
        }
        let descriptor = archiveURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard descriptor >= 0 else {
            throw MacOSStagedInstallerArchiveDigestVerifierError.insecureArchive
        }
        defer { _ = Darwin.close(descriptor) }

        let initialDetails = try secureArchiveDetails(descriptor)
        guard initialDetails.st_size == off_t(expectedByteCount),
              initialDetails.st_size <= off_t(maximumArchiveBytes) else {
            throw MacOSStagedInstallerArchiveDigestVerifierError.insecureArchive
        }

        var hasher = SHA256()
        var readBytes: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: 128 * 1024)
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
                throw MacOSStagedInstallerArchiveDigestVerifierError.insecureArchive
            }
            readBytes += UInt64(count)
            guard readBytes <= expectedByteCount else {
                throw MacOSStagedInstallerArchiveDigestVerifierError.insecureArchive
            }
            hasher.update(data: Data(buffer.prefix(Int(count))))
        }

        var finalDetails = stat()
        guard readBytes == expectedByteCount,
              Darwin.fstat(descriptor, &finalDetails) == 0,
              hasSameIdentityAndMetadata(initialDetails, finalDetails),
              secureArchiveDetails(finalDetails) else {
            throw MacOSStagedInstallerArchiveDigestVerifierError.insecureArchive
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func secureArchiveDetails(_ descriptor: Int32) throws -> stat {
        var details = stat()
        guard Darwin.fstat(descriptor, &details) == 0,
              secureArchiveDetails(details) else {
            throw MacOSStagedInstallerArchiveDigestVerifierError.insecureArchive
        }
        return details
    }

    private func secureArchiveDetails(_ details: stat) -> Bool {
        (details.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
            && details.st_uid == Darwin.geteuid()
            && details.st_nlink == 1
            && (details.st_mode & mode_t(0o7777)) == mode_t(0o600)
    }

    private func hasSameIdentityAndMetadata(_ initial: stat, _ final: stat) -> Bool {
        initial.st_dev == final.st_dev
            && initial.st_ino == final.st_ino
            && initial.st_size == final.st_size
            && initial.st_mtimespec.tv_sec == final.st_mtimespec.tv_sec
            && initial.st_mtimespec.tv_nsec == final.st_mtimespec.tv_nsec
            && initial.st_ctimespec.tv_sec == final.st_ctimespec.tv_sec
            && initial.st_ctimespec.tv_nsec == final.st_ctimespec.tv_nsec
    }
}

private enum MacOSStagedInstallerArchiveDigestVerifierError: Error {
    case invalidConfiguration
    case insecureArchive
}
