import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class SelfUpdateOperationLockTests: XCTestCase {
    func testFileLockRejectsASecondExclusiveLeaseUntilTheFirstIsReleased() throws {
        let stateDirectory = try makeStateDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }

        let firstLock = FileInstallerSelfUpdateOperationLock(rootDirectory: stateDirectory)
        let secondLock = FileInstallerSelfUpdateOperationLock(rootDirectory: stateDirectory)

        let firstLease = try requireLease(firstLock.acquireExclusiveSelfUpdateOperationLock())
        let secondAttempt = secondLock.acquireExclusiveSelfUpdateOperationLock()

        assertFailure(secondAttempt, code: .selfUpdateOperationInProgress)
        assertReleaseSucceeded(firstLease.releaseExclusiveSelfUpdateOperationLock())

        let replacementLease = try requireLease(secondLock.acquireExclusiveSelfUpdateOperationLock())
        assertReleaseSucceeded(replacementLease.releaseExclusiveSelfUpdateOperationLock())
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: stateDirectory.appendingPathComponent("installer-self-update.lock").path
            ),
            "The permanent lock inode is not removed after release."
        )
    }

    func testFileLockFailsClosedForASymlinkInsteadOfFollowingIt() throws {
        let stateDirectory = try makeStateDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        try FileManager.default.createDirectory(
            at: stateDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let lockPath = stateDirectory.appendingPathComponent("installer-self-update.lock").path
        try FileManager.default.createSymbolicLink(
            atPath: lockPath,
            withDestinationPath: "/private/tmp/not-an-installer-lock"
        )

        let lock = FileInstallerSelfUpdateOperationLock(rootDirectory: stateDirectory)
        assertFailure(lock.acquireExclusiveSelfUpdateOperationLock(), code: .selfUpdateOperationLockUnavailable)
    }

    func testFileLockFailsClosedForAnInsecureStateDirectory() throws {
        let stateDirectory = try makeStateDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        try FileManager.default.createDirectory(
            at: stateDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o755]
        )

        let lock = FileInstallerSelfUpdateOperationLock(rootDirectory: stateDirectory)
        assertFailure(lock.acquireExclusiveSelfUpdateOperationLock(), code: .selfUpdateOperationLockUnavailable)
    }

    func testFileLockFailsClosedForAStateDirectoryWithSpecialPermissionBits() throws {
        let stateDirectory = try makeStateDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        try FileManager.default.createDirectory(
            at: stateDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o1700], ofItemAtPath: stateDirectory.path)

        let lock = FileInstallerSelfUpdateOperationLock(rootDirectory: stateDirectory)
        assertFailure(lock.acquireExclusiveSelfUpdateOperationLock(), code: .selfUpdateOperationLockUnavailable)
    }

    private func makeStateDirectory() throws -> URL {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-platform-installer-lock-tests", isDirectory: true)
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return parent.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
    }

    private func requireLease(
        _ result: Result<any InstallerSelfUpdateOperationLock, InstallerSelfUpdateFailure>
    ) throws -> any InstallerSelfUpdateOperationLock {
        switch result {
        case .success(let lease):
            return lease
        case .failure(let failure):
            throw failure
        }
    }

    private func assertFailure(
        _ result: Result<any InstallerSelfUpdateOperationLock, InstallerSelfUpdateFailure>,
        code: InstallerSelfUpdateFailureCode,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .failure(let failure) = result else {
            return XCTFail("Expected operation lock acquisition to fail", file: file, line: line)
        }
        XCTAssertEqual(failure.code, code, file: file, line: line)
    }

    private func assertReleaseSucceeded(
        _ result: Result<Void, InstallerSelfUpdateFailure>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if case .failure(let failure) = result {
            XCTFail("Expected operation lock release to succeed: \(failure.code)", file: file, line: line)
        }
    }
}
