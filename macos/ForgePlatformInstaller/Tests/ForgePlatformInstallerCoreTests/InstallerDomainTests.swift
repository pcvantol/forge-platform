import XCTest
@testable import ForgePlatformInstallerCore

final class InstallerDomainTests: XCTestCase {
    func testNewerVerifiedReleaseRequiresSelfUpdateAndBlocksTheWizard() throws {
        var state = InstallerWizardState(currentInstallerVersion: try InstallerVersion("1.2.3"))
        let release = try makeRelease("1.2.4")

        state.recordSelfUpdateCheck(.verifiedGitHubRelease(release))

        XCTAssertEqual(state.selfUpdate, .updateRequired(release))
        XCTAssertFalse(state.canAdvance)
        XCTAssertFalse(state.advance())
        XCTAssertEqual(state.step, .selfUpdate)

        XCTAssertEqual(state.beginSelfUpdateHandoff(), release)
        XCTAssertEqual(state.selfUpdate, .relaunching(release))
        XCTAssertFalse(state.canAdvance)
    }

    func testVerifiedCurrentReleaseAllowsTheSelfUpdateGateToAdvance() throws {
        var state = InstallerWizardState(currentInstallerVersion: try InstallerVersion("1.2.3"))
        let release = try makeRelease("1.2.3")

        state.recordSelfUpdateCheck(.verifiedGitHubRelease(release))

        XCTAssertEqual(state.selfUpdate, .current(release))
        XCTAssertTrue(state.canAdvance)
        XCTAssertTrue(state.advance())
        XCTAssertEqual(state.step, .preflight)
    }

    func testRejectedReleaseMetadataFailsClosed() throws {
        var state = InstallerWizardState(currentInstallerVersion: try InstallerVersion("1.2.3"))

        state.recordSelfUpdateCheck(.rejected("signature mismatch"))

        XCTAssertEqual(state.selfUpdate, .failed("signature mismatch"))
        XCTAssertFalse(state.canAdvance)
    }

    func testBothRequiredProvidersMustBeInstalledAuthenticatedAndVerified() throws {
        var state = InstallerWizardState(currentInstallerVersion: try InstallerVersion("1.2.3"))
        state.step = .providers

        XCTAssertFalse(state.requiredProvidersVerified)
        XCTAssertFalse(state.canAdvance)
        let requiredCodexBefore = state.providers.first(where: { $0.id == .codex })
        XCTAssertFalse(state.setProviderSelected(.codex, isSelected: false))
        XCTAssertEqual(state.providers.first(where: { $0.id == .codex }), requiredCodexBefore)
        XCTAssertFalse(state.requiredProvidersVerified)
        XCTAssertFalse(state.canAdvance)

        verifyRequiredProvider(.codex, state: &state)
        XCTAssertFalse(state.requiredProvidersVerified)
        XCTAssertFalse(state.canAdvance)

        verifyRequiredProvider(.githubCLI, state: &state)
        XCTAssertTrue(state.requiredProvidersVerified)
        XCTAssertTrue(state.canAdvance)
        XCTAssertTrue(state.advance())
        XCTAssertEqual(state.step, .composition)
    }

    func testUnselectedOptionalProviderDoesNotBlockAManifestThatDoesNotRequireIt() throws {
        var state = InstallerWizardState(
            currentInstallerVersion: try InstallerVersion("1.2.3"),
            providerRequirements: [
                ProviderRequirement(provider: .codex, isRequired: true),
                ProviderRequirement(provider: .githubCLI, isRequired: false),
            ]
        )
        state.step = .providers

        verifyRequiredProvider(.codex, state: &state)

        XCTAssertTrue(state.requiredProvidersVerified)
        XCTAssertTrue(state.canAdvance)
        XCTAssertEqual(
            state.providers.first(where: { $0.id == .githubCLI })?.state,
            .notSelected
        )
    }

    func testDefaultPreflightRequiresManagedGitAndPythonEvidence() {
        let preflight = HostPreflight()
        let identifiers = Set(preflight.checks.map(\.id))

        XCTAssertTrue(identifiers.contains("managed-git"))
        XCTAssertTrue(identifiers.contains("managed-python"))
        XCTAssertFalse(preflight.isPassed)
    }

    func testGitHubCLIIdentifierMatchesCompositionSchema() {
        XCTAssertEqual(ProviderID.githubCLI.rawValue, "github-cli")
    }

    func testVerifiedDashboardURLAcceptsOnlyProductSuppliedHTTPSEndpoints() throws {
        let dashboard = try VerifiedDashboardURL("https://ep.example.test:8765/dashboard")
        let localDashboard = try VerifiedDashboardURL("http://localhost:8765/dashboard")
        let item = InstallationSummaryItem(
            componentID: "engineering-platform-server",
            title: "Engineering Platform Server",
            status: "Geverifieerd",
            dashboardURL: dashboard,
            serviceScope: .systemLaunchDaemon
        )

        XCTAssertEqual(dashboard.url.scheme, "https")
        XCTAssertEqual(dashboard.url.host, "ep.example.test")
        XCTAssertEqual(localDashboard.url.scheme, "http")
        XCTAssertEqual(localDashboard.url.host, "localhost")
        XCTAssertEqual(item.dashboardURL, dashboard)
    }

    func testVerifiedDashboardURLRejectsFileCustomAndHostlessURLs() {
        let rejectedURLs = [
            "file:///Users/operator/Desktop/dashboard.html",
            "forge-platform://dashboard",
            "https:/missing-host",
            "https://",
            "https://operator:password@ep.example.test/dashboard",
        ]

        for rawValue in rejectedURLs {
            XCTAssertThrowsError(try VerifiedDashboardURL(rawValue), "Expected \(rawValue) to be rejected")
        }
    }

    private func verifyRequiredProvider(_ provider: ProviderID, state: inout InstallerWizardState) {
        XCTAssertTrue(state.requestProviderAction(.install, for: provider))
        state.applyProviderActionResult(.installationReady, for: provider, action: .install)
        XCTAssertTrue(state.requestProviderAction(.authenticate, for: provider))
        state.applyProviderActionResult(.verified, for: provider, action: .authenticate)
        XCTAssertEqual(state.providers.first(where: { $0.id == provider })?.state, .verified)
    }

    private func makeRelease(_ version: String) throws -> VerifiedInstallerRelease {
        VerifiedInstallerRelease(
            version: try InstallerVersion(version),
            releasePage: "https://github.com/pcvantol/forge-platform/releases/tag/installer-v\(version)",
            assetName: "ForgePlatformInstaller.app.zip",
            sha256: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
            signingKeyID: "forge-platform-installer-release-v1"
        )
    }
}
