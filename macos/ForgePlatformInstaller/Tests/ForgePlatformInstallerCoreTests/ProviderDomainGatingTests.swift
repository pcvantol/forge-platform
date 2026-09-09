import XCTest
@testable import ForgePlatformInstallerCore

final class ProviderDomainGatingTests: XCTestCase {
    func testUnprojectedProviderRequirementsFailClosedWithNoProviderRows() throws {
        var state = InstallerWizardState(currentInstallerVersion: try InstallerVersion("1.2.3"))
        state.step = .providers

        XCTAssertEqual(state.providerRequirementsProjection, .pending)
        XCTAssertFalse(state.providerRequirementsAreProjected)
        XCTAssertTrue(state.providers.isEmpty)
        XCTAssertFalse(state.enabledProvidersVerified)
        XCTAssertFalse(state.canAdvance)
    }

    func testExplicitEmptyProjectionAllowsAQualifiedProviderFreeProfile() throws {
        var state = InstallerWizardState(
            currentInstallerVersion: try InstallerVersion("1.2.3"),
            providerRequirements: []
        )
        state.step = .providers

        XCTAssertEqual(state.providerRequirementsProjection, .projected)
        XCTAssertTrue(state.providerRequirementsAreProjected)
        XCTAssertTrue(state.enabledProviders.isEmpty)
        XCTAssertTrue(state.enabledProvidersVerified)
        XCTAssertTrue(state.canAdvance)
    }

    func testProjectionAPIRequiresUniqueProviderIdentitiesAndFailsClosedWhenRejected() throws {
        var state = InstallerWizardState(currentInstallerVersion: try InstallerVersion("1.2.3"))
        state.step = .providers

        XCTAssertFalse(state.applyProviderRequirementsProjection([
            ProviderRequirement(provider: .codex, isRequired: true),
            ProviderRequirement(provider: .codex, isRequired: false),
        ]))

        XCTAssertEqual(state.providerRequirementsProjection, .rejected)
        XCTAssertTrue(state.providers.isEmpty)
        XCTAssertFalse(state.enabledProvidersVerified)
        XCTAssertFalse(state.canAdvance)
    }

    func testProviderRequirementsProjectionCannotReplaceAnUnverifiedRequiredProvider() throws {
        var state = InstallerWizardState(currentInstallerVersion: try InstallerVersion("1.2.3"))
        state.step = .providers

        XCTAssertTrue(state.applyProviderRequirementsProjection([
            ProviderRequirement(provider: .codex, isRequired: true),
        ]))
        XCTAssertFalse(state.enabledProvidersVerified)
        XCTAssertFalse(state.canAdvance)

        XCTAssertFalse(state.applyProviderRequirementsProjection([]))

        XCTAssertEqual(state.providerRequirementsProjection, .projected)
        XCTAssertEqual(state.providers.map(\.id), [.codex])
        XCTAssertTrue(state.providers[0].requirement.isRequired)
        XCTAssertFalse(state.enabledProvidersVerified)
        XCTAssertFalse(state.canAdvance)
    }

    func testRequiredProviderCannotBeDeselected() throws {
        var state = try providerState([
            ProviderRequirement(provider: .codex, isRequired: true),
        ])

        XCTAssertTrue(state.providers[0].isEnabled)
        XCTAssertTrue(state.providers[0].isSelected)
        XCTAssertFalse(state.setProviderSelected(.codex, isSelected: false))
        XCTAssertTrue(state.providers[0].isSelected)
        XCTAssertEqual(state.providers[0].state, .selected)
        XCTAssertFalse(state.enabledProvidersVerified)
        XCTAssertFalse(state.canAdvance)
    }

    func testSelectedOptionalProviderMustBeVerifiedBeforeTheGateCanAdvance() throws {
        var state = try providerState([
            ProviderRequirement(provider: .githubCLI, isRequired: false),
        ])

        XCTAssertTrue(state.enabledProviders.isEmpty)
        XCTAssertTrue(state.canAdvance)

        XCTAssertTrue(state.setProviderSelected(.githubCLI, isSelected: true))
        XCTAssertEqual(state.enabledProviders.map(\.id), [.githubCLI])
        XCTAssertEqual(state.providers[0].state, .selected)
        XCTAssertFalse(state.enabledProvidersVerified)
        XCTAssertFalse(state.canAdvance)

        verify(.githubCLI, in: &state)

        XCTAssertTrue(state.enabledProvidersVerified)
        XCTAssertTrue(state.canAdvance)
    }

    func testFailedAuthenticationUsesTypedFailureAndBlocksTheGate() throws {
        var state = try providerState([
            ProviderRequirement(provider: .codex, isRequired: true),
        ])

        XCTAssertTrue(state.requestProviderAction(.install, for: .codex))
        state.applyProviderActionResult(.authenticationRequired, for: .codex, action: .install)
        XCTAssertTrue(state.requestProviderAction(.authenticate, for: .codex))
        state.applyProviderActionResult(.failed(.authenticationFailed), for: .codex, action: .authenticate)

        XCTAssertEqual(state.providers[0].state, .failed(.authenticationFailed))
        XCTAssertEqual(state.providers[0].state.failureCode, .authenticationFailed)
        XCTAssertEqual(state.providers[0].state.displayName, "Mislukt")
        XCTAssertEqual(ProviderFailureCode.authenticationFailed.userFacingMessage, "Aanmelding bij de provider is mislukt.")
        XCTAssertFalse(state.enabledProvidersVerified)
        XCTAssertFalse(state.canAdvance)
    }

    func testAllEnabledRequiredAndOptionalProvidersMustVerifyBeforePassing() throws {
        var state = try providerState([
            ProviderRequirement(provider: .codex, isRequired: true),
            ProviderRequirement(provider: .githubCLI, isRequired: false),
        ])

        XCTAssertTrue(state.setProviderSelected(.githubCLI, isSelected: true))
        verify(.codex, in: &state)

        XCTAssertFalse(state.enabledProvidersVerified)
        XCTAssertFalse(state.canAdvance)

        verify(.githubCLI, in: &state)

        XCTAssertEqual(state.enabledProviders.map(\.id), [.codex, .githubCLI])
        XCTAssertTrue(state.enabledProviders.allSatisfy(\.isVerified))
        XCTAssertTrue(state.enabledProvidersVerified)
        XCTAssertTrue(state.canAdvance)
        XCTAssertTrue(state.advance())
        XCTAssertEqual(state.step, .composition)
    }

    func testUnrequestedSuccessResultCannotMarkAProviderVerified() throws {
        var state = try providerState([
            ProviderRequirement(provider: .codex, isRequired: true),
        ])

        state.applyProviderActionResult(.verified, for: .codex, action: .authenticate)

        XCTAssertEqual(state.providers[0].state, .failed(.unexpectedActionResult))
        XCTAssertFalse(state.enabledProvidersVerified)
        XCTAssertFalse(state.canAdvance)
    }

    func testTypedFailureResultRedactsArbitraryCoordinatorText() throws {
        let unsafeDiagnostic = "ruwe-diagnostiek-mag-niet-worden-bewaard"
        let result = ProviderActionResult.failed(unsafeDiagnostic)

        XCTAssertEqual(result, .failed(.coordinatorUnavailable))
        XCTAssertFalse(String(describing: result).contains(unsafeDiagnostic))

        var state = try providerState([
            ProviderRequirement(provider: .codex, isRequired: true),
        ])
        XCTAssertTrue(state.requestProviderAction(.install, for: .codex))
        state.applyProviderActionResult(result, for: .codex, action: .install)

        XCTAssertEqual(state.providers[0].state, .failed(.coordinatorUnavailable))
        XCTAssertEqual(state.providers[0].state.failureCode, .coordinatorUnavailable)
        XCTAssertEqual(ProviderFailureCode.coordinatorUnavailable.userFacingMessage, "Providercoördinatie is niet beschikbaar.")
        XCTAssertFalse(String(describing: state.providers[0].state).contains(unsafeDiagnostic))
        XCTAssertFalse(ProviderFailureCode.coordinatorUnavailable.userFacingMessage.contains(unsafeDiagnostic))
        XCTAssertFalse(state.canAdvance)
    }

    private func providerState(_ requirements: [ProviderRequirement]) throws -> InstallerWizardState {
        var state = InstallerWizardState(
            currentInstallerVersion: try InstallerVersion("1.2.3"),
            providerRequirements: requirements
        )
        state.step = .providers
        return state
    }

    private func verify(_ provider: ProviderID, in state: inout InstallerWizardState) {
        XCTAssertTrue(state.requestProviderAction(.install, for: provider))
        state.applyProviderActionResult(.installationReady, for: provider, action: .install)
        XCTAssertTrue(state.requestProviderAction(.authenticate, for: provider))
        state.applyProviderActionResult(.verified, for: provider, action: .authenticate)
        XCTAssertEqual(state.providers.first(where: { $0.id == provider })?.state, .verified)
    }
}
