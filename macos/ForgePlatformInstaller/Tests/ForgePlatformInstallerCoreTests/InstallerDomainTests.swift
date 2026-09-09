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

    func testVerifiedCurrentReleaseLeadsToCompositionSelectionBeforePreflight() throws {
        var state = InstallerWizardState(currentInstallerVersion: try InstallerVersion("1.2.3"))
        let release = try makeRelease("1.2.3")

        state.recordSelfUpdateCheck(.verifiedGitHubRelease(release))

        XCTAssertEqual(state.selfUpdate, .current(release))
        XCTAssertTrue(state.canAdvance)
        XCTAssertTrue(state.advance())
        XCTAssertEqual(state.step, .composition)
        XCTAssertFalse(state.canAdvance)
        XCTAssertFalse(state.providerRequirementsAreProjected)
        XCTAssertTrue(state.providers.isEmpty)
    }

    func testRejectedReleaseMetadataFailsClosed() throws {
        var state = InstallerWizardState(currentInstallerVersion: try InstallerVersion("1.2.3"))

        state.recordSelfUpdateCheck(.rejected("signature mismatch"))

        XCTAssertEqual(state.selfUpdate, .failed("signature mismatch"))
        XCTAssertFalse(state.canAdvance)
    }

    func testCompositionSessionMustBeAcceptedBeforePreflightAndProjectsProvidersAtomically() throws {
        var state = try compositionSelectionState()
        let plan = try makeSessionPlan(
            requirements: [
                ProviderRequirement(provider: .codex, isRequired: true),
                ProviderRequirement(provider: .githubCLI, isRequired: false),
            ]
        )

        XCTAssertEqual(state.sessionPreparation, .pending)
        XCTAssertFalse(state.canAdvance)
        XCTAssertTrue(state.beginSessionPreparation())
        XCTAssertFalse(state.recordSessionPreparation(.unavailable(.selectionUnavailable)))
        XCTAssertEqual(state.sessionPreparation, .unavailable(.selectionUnavailable))
        XCTAssertFalse(state.providerRequirementsAreProjected)
        XCTAssertTrue(state.providers.isEmpty)

        XCTAssertTrue(state.beginSessionPreparation())
        XCTAssertTrue(state.recordSessionPreparation(.prepared(plan)))
        XCTAssertEqual(state.sessionPreparation, .prepared(plan))
        XCTAssertEqual(state.acceptedSessionPlan, plan)
        XCTAssertTrue(state.providerRequirementsAreProjected)
        XCTAssertEqual(state.providers.map(\.requirement), plan.providerRequirements)
        XCTAssertEqual(state.composition.manifestIdentity, plan.compositionIdentity)
        XCTAssertTrue(state.canAdvance)
        XCTAssertTrue(state.advance())
        XCTAssertEqual(state.step, .preflight)
    }

    func testAcceptedSessionResetsPreflightFactsThatPredateTheSession() throws {
        var state = try compositionSelectionState()
        state.preflight = HostPreflight(checks: [
            PreflightCheck(id: "stale-host", title: "Oude hostcontrole", detail: "Niet sessiegebonden", state: .passed),
        ])
        XCTAssertTrue(state.preflight.isPassed)

        XCTAssertTrue(state.beginSessionPreparation())
        XCTAssertTrue(state.recordSessionPreparation(.prepared(try makeSessionPlan(requirements: []))))

        XCTAssertFalse(state.preflight.isPassed)
        XCTAssertTrue(state.advance())
        XCTAssertEqual(state.step, .preflight)
        XCTAssertFalse(state.canAdvance)
    }

    func testCompositionSelectionCannotBeAbandonedWhileItsResultIsInFlight() throws {
        var state = try compositionSelectionState()

        XCTAssertTrue(state.beginSessionPreparation())
        XCTAssertFalse(state.canGoBack)
        XCTAssertFalse(state.goBack())
        XCTAssertEqual(state.step, .composition)
        XCTAssertEqual(state.sessionPreparation, .preparing)

        XCTAssertFalse(state.recordSessionPreparation(.unavailable(.selectionUnavailable)))
        XCTAssertTrue(state.canGoBack)
    }

    func testBothRequiredProvidersMustBeInstalledAuthenticatedAndVerified() throws {
        var state = try providerState([
            ProviderRequirement(provider: .codex, isRequired: true),
            ProviderRequirement(provider: .githubCLI, isRequired: true),
        ])

        XCTAssertFalse(state.enabledProvidersVerified)
        XCTAssertFalse(state.canAdvance)
        let requiredCodexBefore = state.providers.first(where: { $0.id == .codex })
        XCTAssertFalse(state.setProviderSelected(.codex, isSelected: false))
        XCTAssertEqual(state.providers.first(where: { $0.id == .codex }), requiredCodexBefore)
        XCTAssertFalse(state.enabledProvidersVerified)
        XCTAssertFalse(state.canAdvance)

        verifyRequiredProvider(.codex, state: &state)
        XCTAssertFalse(state.enabledProvidersVerified)
        XCTAssertFalse(state.canAdvance)

        verifyRequiredProvider(.githubCLI, state: &state)
        XCTAssertTrue(state.enabledProvidersVerified)
        XCTAssertTrue(state.canAdvance)
        XCTAssertTrue(state.advance())
        XCTAssertEqual(state.step, .review)
    }

    func testUnselectedOptionalProviderDoesNotBlockAProviderFreeSelection() throws {
        var state = try providerState([
            ProviderRequirement(provider: .codex, isRequired: true),
            ProviderRequirement(provider: .githubCLI, isRequired: false),
        ])

        verifyRequiredProvider(.codex, state: &state)

        XCTAssertTrue(state.enabledProvidersVerified)
        XCTAssertTrue(state.canAdvance)
        XCTAssertEqual(
            state.providers.first(where: { $0.id == .githubCLI })?.state,
            .notSelected
        )
    }

    func testSelfUpdateRecheckClearsTheAcceptedSessionAndProviderProjection() throws {
        var state = try acceptedSessionState([
            ProviderRequirement(provider: .codex, isRequired: true),
        ])
        let release = try makeRelease("1.2.3")
        state.preflight = HostPreflight(checks: [
            PreflightCheck(id: "old-session-host", title: "Oude sessie", detail: "Verouderd", state: .passed),
        ])

        XCTAssertTrue(state.hasAcceptedSessionPlan)
        XCTAssertFalse(state.providers.isEmpty)
        XCTAssertTrue(state.preflight.isPassed)

        state.recordSelfUpdateCheck(.verifiedGitHubRelease(release))

        XCTAssertEqual(state.selfUpdate, .current(release))
        XCTAssertEqual(state.sessionPreparation, .pending)
        XCTAssertNil(state.acceptedSessionPlan)
        XCTAssertEqual(state.providerRequirementsProjection, .pending)
        XCTAssertTrue(state.providers.isEmpty)
        XCTAssertFalse(state.preflight.isPassed)
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

    private func compositionSelectionState() throws -> InstallerWizardState {
        var state = InstallerWizardState(currentInstallerVersion: try InstallerVersion("1.2.3"))
        state.recordSelfUpdateCheck(.verifiedGitHubRelease(try makeRelease("1.2.3")))
        XCTAssertTrue(state.advance())
        XCTAssertEqual(state.step, .composition)
        return state
    }

    private func acceptedSessionState(_ requirements: [ProviderRequirement]) throws -> InstallerWizardState {
        var state = try compositionSelectionState()
        XCTAssertTrue(state.beginSessionPreparation())
        XCTAssertTrue(state.recordSessionPreparation(.prepared(try makeSessionPlan(requirements: requirements))))
        return state
    }

    private func providerState(_ requirements: [ProviderRequirement]) throws -> InstallerWizardState {
        var state = try acceptedSessionState(requirements)
        XCTAssertTrue(state.advance())
        XCTAssertEqual(state.step, .preflight)
        state.preflight = HostPreflight(checks: [
            PreflightCheck(id: "session-host", title: "Sessiehost", detail: "Geverifieerd", state: .passed),
        ])
        XCTAssertTrue(state.advance())
        XCTAssertEqual(state.step, .providers)
        return state
    }

    private func verifyRequiredProvider(_ provider: ProviderID, state: inout InstallerWizardState) {
        XCTAssertTrue(state.requestProviderAction(.install, for: provider))
        state.applyProviderActionResult(.installationReady, for: provider, action: .install)
        XCTAssertTrue(state.requestProviderAction(.authenticate, for: provider))
        state.applyProviderActionResult(.verified, for: provider, action: .authenticate)
        XCTAssertEqual(state.providers.first(where: { $0.id == provider })?.state, .verified)
    }

    private func makeSessionPlan(
        requirements: [ProviderRequirement],
        sessionID: String = "session-1"
    ) throws -> VerifiedCompositionSessionPlan {
        try VerifiedCompositionSessionPlan(
            sessionID: sessionID,
            compositionIdentity: "forge-platform-complete-v1",
            manifestSHA256: "sha256:" + String(repeating: "a", count: 64),
            catalogSequence: 1,
            catalogSHA256: "sha256:" + String(repeating: "b", count: 64),
            providerRequirements: requirements
        )
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
