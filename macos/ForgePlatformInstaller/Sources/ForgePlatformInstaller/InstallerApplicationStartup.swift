import Combine
import SwiftUI
import ForgePlatformInstallerCore

/// App-level bridge for the released startup boundary.  The root view does not
/// construct a wizard until the core has loaded sealed trust configuration and
/// release provenance, then automatically established that this exact installer
/// release is current.
@MainActor
final class InstallerApplicationStartupModel: ObservableObject {
    enum State {
        case checking
        case ready(InstallerWizardViewModel)
        case relaunching(VerifiedInstallerRelease)
        case blocked(String)
    }

    @Published private(set) var state: State = .checking

    private let startupBoundary: ReleasedInstallerStartupBoundary
    private var hasStarted = false

    init(startupBoundary: ReleasedInstallerStartupBoundary = .bundledFailClosed()) {
        self.startupBoundary = startupBoundary
    }

    func start() {
        guard !hasStarted else {
            return
        }
        hasStarted = true
        let startupBoundary = startupBoundary
        guard let currentVersion = InstallerBuild.currentVersion else {
            state = .blocked("De code-ondertekende installerversie ontbreekt of is niet geldig.")
            return
        }

        Task { [weak self] in
            let outcome = await startupBoundary.start(currentVersion: currentVersion)
            guard let self else {
                return
            }
            switch outcome {
            case .ready(let session):
                var wizardState = InstallerWizardState(currentInstallerVersion: currentVersion)
                wizardState.recordSelfUpdateCheck(.verifiedGitHubRelease(session.currentRelease))
                state = .ready(InstallerWizardViewModel(
                    state: wizardState,
                    coordinator: session.runtime
                ))
            case .relaunching(let release):
                state = .relaunching(release)
            case .blocked(let reason):
                state = .blocked(reason)
            }
        }
    }
}

struct InstallerApplicationRootView: View {
    @ObservedObject var startupModel: InstallerApplicationStartupModel

    var body: some View {
        Group {
            switch startupModel.state {
            case .checking:
                InstallerStartupStatusView(
                    title: "Installer-integriteit controleren",
                    message: "De geverifieerde Universal Installer wordt gecontroleerd voordat platformonderdelen beschikbaar zijn.",
                    symbol: "checkmark.shield"
                )
            case .ready(let viewModel):
                InstallerWizardView(viewModel: viewModel)
            case .relaunching(let release):
                InstallerStartupStatusView(
                    title: "Installer wordt herstart",
                    message: "De geverifieerde versie \(release.version.description) is geactiveerd. Deze instantie voert geen platformactie uit.",
                    symbol: "arrow.triangle.2.circlepath"
                )
            case .blocked(let reason):
                InstallerStartupStatusView(
                    title: "Installer geblokkeerd",
                    message: reason,
                    symbol: "lock.shield"
                )
            }
        }
        .task {
            startupModel.start()
        }
    }
}

private struct InstallerStartupStatusView: View {
    let title: String
    let message: String
    let symbol: String

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: symbol)
                .font(.system(size: 42, weight: .medium))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title2.weight(.semibold))
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 520)
            Text("Er worden geen componentinstallaties, provideracties of servicewijzigingen gestart.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
