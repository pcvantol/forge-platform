import Foundation
import Darwin

/// Acquires one host-wide, installer-owned lease for the self-update critical
/// section.  The lease deliberately has no product, credential, path, or
/// release payload: it only serializes recovery, verification and handoff.
///
/// A released runtime must inject a cross-process implementation.  An
/// unavailable or busy lock is a fail-closed condition; callers must not try a
/// second self-update operation concurrently.
public protocol InstallerSelfUpdateOperationLocking: Sendable {
    func acquireExclusiveSelfUpdateOperationLock() -> Result<any InstallerSelfUpdateOperationLock, InstallerSelfUpdateFailure>
}

/// A non-copyable-in-practice lease represented as a protocol existential so
/// the coordinator never receives an untyped file descriptor or lock path.
/// Releasing an already released lease is harmless, which lets callers clean
/// up safely after all non-throwing asynchronous result paths.
public protocol InstallerSelfUpdateOperationLock: Sendable {
    func releaseExclusiveSelfUpdateOperationLock() -> Result<Void, InstallerSelfUpdateFailure>
}

/// `flock(2)`-backed, non-blocking mutual exclusion for installer self-update.
/// The caller supplies a preselected installer-owned state directory; it is
/// never taken from PATH, a product data root, or UI input.  The final
/// directory and lock file are opened without following a final symlink and
/// must be owned by the effective installer account with no group/world
/// permissions.  This makes two independently launched installer processes
/// contend for the same kernel lock instead of racing the recovery journal.
///
/// The lock is advisory by operating-system design.  Every released installer
/// self-update entry point is required to use this protocol, so a competing
/// legitimate installer process cannot bypass it.  A process that does not
/// cooperate is not treated as a valid installer participant.
public struct FileInstallerSelfUpdateOperationLock: InstallerSelfUpdateOperationLocking {
    private static let lockFileName = "installer-self-update.lock"

    private let rootDirectory: URL

    /// `rootDirectory` must be a fixed, installer-owned state directory whose
    /// parent already exists.  Refusing to create arbitrary parent paths keeps
    /// this primitive from becoming a filesystem provisioning mechanism.
    public init(rootDirectory: URL) {
        self.rootDirectory = Self.canonicalRootDirectory(for: rootDirectory)
    }

    public func acquireExclusiveSelfUpdateOperationLock() -> Result<any InstallerSelfUpdateOperationLock, InstallerSelfUpdateFailure> {
        do {
            let directoryDescriptor = try openSecureRootDirectory()
            defer { _ = Darwin.close(directoryDescriptor) }

            let lockDescriptor = try openSecureLockFile(in: directoryDescriptor)
            if flock(lockDescriptor, LOCK_EX | LOCK_NB) != 0 {
                let lockError = errno
                _ = Darwin.close(lockDescriptor)
                if lockError == EWOULDBLOCK || lockError == EAGAIN {
                    return .failure(InstallerSelfUpdateFailure(.selfUpdateOperationInProgress))
                }
                return .failure(InstallerSelfUpdateFailure(.selfUpdateOperationLockUnavailable))
            }
            return .success(FileInstallerSelfUpdateOperationLease(fileDescriptor: lockDescriptor))
        } catch {
            return .failure(InstallerSelfUpdateFailure(.selfUpdateOperationLockUnavailable))
        }
    }

    private func openSecureRootDirectory() throws -> Int32 {
        let createResult = rootDirectory.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.mkdir(path, mode_t(0o700))
        }
        if createResult != 0 && errno != EEXIST {
            throw FileInstallerSelfUpdateOperationLockError.unavailable
        }

        let directoryDescriptor = rootDirectory.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard directoryDescriptor >= 0 else {
            throw FileInstallerSelfUpdateOperationLockError.unavailable
        }
        guard isSecureDirectory(directoryDescriptor) else {
            _ = Darwin.close(directoryDescriptor)
            throw FileInstallerSelfUpdateOperationLockError.unavailable
        }
        return directoryDescriptor
    }

    private func openSecureLockFile(in directoryDescriptor: Int32) throws -> Int32 {
        let lockDescriptor = Self.lockFileName.withCString { fileName -> Int32 in
            Darwin.openat(
                directoryDescriptor,
                fileName,
                O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW_ANY,
                mode_t(0o600)
            )
        }
        guard lockDescriptor >= 0 else {
            throw FileInstallerSelfUpdateOperationLockError.unavailable
        }
        guard isSecureRegularFile(lockDescriptor) else {
            _ = Darwin.close(lockDescriptor)
            throw FileInstallerSelfUpdateOperationLockError.unavailable
        }
        return lockDescriptor
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

    private func isSecureRegularFile(_ descriptor: Int32) -> Bool {
        var details = stat()
        guard Darwin.fstat(descriptor, &details) == 0 else {
            return false
        }
        return (details.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
            && details.st_uid == Darwin.geteuid()
            && details.st_nlink == 1
            && (details.st_mode & mode_t(0o7777)) == mode_t(0o600)
    }

    /// `URL.resolvingSymlinksInPath()` deliberately preserves some macOS
    /// compatibility aliases (notably `/tmp` and `/var`).  Resolve the existing
    /// parent with `realpath(3)` before using `O_NOFOLLOW_ANY`, so callers get
    /// one normalized lock location while the subsequent kernel open still
    /// rejects any symlink introduced into the final path.
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

private enum FileInstallerSelfUpdateOperationLockError: Error {
    case unavailable
}

/// The kernel file descriptor remains open for the entire lease.  A local
/// mutex makes `release` idempotent even if task cancellation and object
/// lifetime cleanup race in one process; `flock` is what serializes processes.
private final class FileInstallerSelfUpdateOperationLease: InstallerSelfUpdateOperationLock, @unchecked Sendable {
    private let stateLock = NSLock()
    private var fileDescriptor: Int32?

    init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    deinit {
        _ = releaseExclusiveSelfUpdateOperationLock()
    }

    func releaseExclusiveSelfUpdateOperationLock() -> Result<Void, InstallerSelfUpdateFailure> {
        stateLock.lock()
        guard let descriptor = fileDescriptor else {
            stateLock.unlock()
            return .success(())
        }
        fileDescriptor = nil
        stateLock.unlock()

        let unlockSucceeded = flock(descriptor, LOCK_UN) == 0
        let closeSucceeded = Darwin.close(descriptor) == 0
        guard unlockSucceeded && closeSucceeded else {
            return .failure(InstallerSelfUpdateFailure(.selfUpdateOperationLockReleaseFailed))
        }
        return .success(())
    }
}
