import Darwin
import Foundation

/// The only two fixed macOS tools used to assess a staged installer bundle.
/// Neither a release descriptor, bundle resource, wizard input, nor provider
/// can select an executable or append a command argument.
enum MacOSInstallerNotarizationTool: Equatable, Sendable {
    case systemPolicy
    case stapler
}

/// An immutable command assembled entirely by the installer.  It is internal
/// so focused tests can prove that no ambient PATH, shell, receipt text, or
/// user input becomes an executable or option.
struct MacOSInstallerNotarizationCommand: Equatable, Sendable {
    let executableURL: URL
    let arguments: [String]
}

enum MacOSInstallerNotarizationCommandFactory {
    static let systemPolicyURL = URL(fileURLWithPath: "/usr/sbin/spctl", isDirectory: false)
    static let staplerURL = URL(fileURLWithPath: "/usr/bin/stapler", isDirectory: false)

    static func command(
        for tool: MacOSInstallerNotarizationTool,
        bundleURL: URL
    ) -> MacOSInstallerNotarizationCommand {
        switch tool {
        case .systemPolicy:
            return MacOSInstallerNotarizationCommand(
                executableURL: systemPolicyURL,
                arguments: ["--assess", "--type", "execute", "--verbose=4", bundleURL.path]
            )
        case .stapler:
            return MacOSInstallerNotarizationCommand(
                executableURL: staplerURL,
                arguments: ["validate", "-v", bundleURL.path]
            )
        }
    }
}

/// Runs one fixed notarization assessment command.  The protocol has no raw
/// command, environment, output, URL, credential, or receipt input.  A test
/// double can model a failing Apple assessment without running a process.
protocol MacOSInstallerNotarizationToolExecuting: Sendable {
    func executeNotarizationAssessment(
        _ tool: MacOSInstallerNotarizationTool,
        bundleURL: URL
    ) async -> Result<Void, InstallerSelfUpdateFailure>
}

/// Production executor for Gatekeeper and stapled-ticket assessment.  Each
/// process has a fixed absolute executable, exact arguments, a scrubbed
/// environment, bounded lifetime, and discarded diagnostic output.  In
/// particular it never invokes a shell, `xcrun`, a developer-tool lookup, or
/// a path selected by the UI.  Failure is deliberately reported only as a
/// typed notarization failure; raw tool output is not installer evidence or
/// a suitable wizard diagnostic.
struct MacOSSystemNotarizationToolExecutor: MacOSInstallerNotarizationToolExecuting {
    private static let timeout: DispatchTimeInterval = .seconds(30)
    private static let terminationGracePeriod: DispatchTimeInterval = .seconds(2)

    init() {}

    func executeNotarizationAssessment(
        _ tool: MacOSInstallerNotarizationTool,
        bundleURL: URL
    ) async -> Result<Void, InstallerSelfUpdateFailure> {
        guard let command = validatedCommand(for: tool, bundleURL: bundleURL) else {
            return .failure(InstallerSelfUpdateFailure(.notarizationVerificationFailed))
        }
        let success = await Task.detached(priority: .userInitiated) {
            run(command)
        }.value
        return success
            ? .success(())
            : .failure(InstallerSelfUpdateFailure(.notarizationVerificationFailed))
    }

    private func validatedCommand(
        for tool: MacOSInstallerNotarizationTool,
        bundleURL: URL
    ) -> MacOSInstallerNotarizationCommand? {
        guard isNonSymlinkAppBundleDirectory(bundleURL) else {
            return nil
        }
        let command = MacOSInstallerNotarizationCommandFactory.command(for: tool, bundleURL: bundleURL)
        guard command.executableURL.isFileURL,
              FileManager.default.isExecutableFile(atPath: command.executableURL.path) else {
            return nil
        }
        return command
    }

    private func isNonSymlinkAppBundleDirectory(_ bundleURL: URL) -> Bool {
        guard bundleURL.isFileURL,
              bundleURL.pathExtension.lowercased() == "app" else {
            return false
        }
        var details = stat()
        let result = bundleURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.lstat(path, &details)
        }
        return result == 0
            && (details.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
            && (details.st_mode & mode_t(S_IFLNK)) == 0
    }

    private func run(_ command: MacOSInstallerNotarizationCommand) -> Bool {
        let process = Process()
        process.executableURL = command.executableURL
        process.arguments = command.arguments
        // The executable is absolute, but clearing ambient configuration also
        // keeps user proxy, locale and credential variables from affecting a
        // security assessment or becoming part of its output behavior.
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "C",
            "LC_ALL": "C",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let termination = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            termination.signal()
        }
        do {
            try process.run()
        } catch {
            return false
        }
        guard termination.wait(timeout: .now() + Self.timeout) == .success else {
            process.terminate()
            if termination.wait(timeout: .now() + Self.terminationGracePeriod) != .success {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                guard termination.wait(timeout: .now() + Self.terminationGracePeriod) == .success else {
                    return false
                }
            }
            return false
        }
        return process.terminationReason == .exit && process.terminationStatus == 0
    }
}

/// A composed assessment requires both Gatekeeper's online/offline policy
/// verdict and a locally stapled ticket.  This avoids treating a valid static
/// signature as a notarization proof.  The release's opaque receipt reference
/// is validated as release metadata but is intentionally never converted into
/// a command, path, lookup, log field, or network request.
public struct MacOSStapledInstallerNotarizationAssessor: MacOSInstallerNotarizationAssessing {
    private let toolExecutor: any MacOSInstallerNotarizationToolExecuting

    public init() {
        self.toolExecutor = MacOSSystemNotarizationToolExecutor()
    }

    init(toolExecutor: any MacOSInstallerNotarizationToolExecuting) {
        self.toolExecutor = toolExecutor
    }

    public func assessNotarization(
        of bundleURL: URL,
        receiptReference: String
    ) async -> Result<Void, InstallerSelfUpdateFailure> {
        guard InstallerSelfUpdateValidation.isNotarizationReceiptReference(receiptReference) else {
            return .failure(InstallerSelfUpdateFailure(.notarizationVerificationFailed))
        }
        switch await toolExecutor.executeNotarizationAssessment(.systemPolicy, bundleURL: bundleURL) {
        case .success:
            break
        case .failure:
            return .failure(InstallerSelfUpdateFailure(.notarizationVerificationFailed))
        }
        switch await toolExecutor.executeNotarizationAssessment(.stapler, bundleURL: bundleURL) {
        case .success:
            return .success(())
        case .failure:
            return .failure(InstallerSelfUpdateFailure(.notarizationVerificationFailed))
        }
    }
}
