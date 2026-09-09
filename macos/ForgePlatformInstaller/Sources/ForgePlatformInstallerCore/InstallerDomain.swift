import Foundation

/// Strict three-part release version used only for the installer bootstrap gate.
/// Product and component versions remain independently owned by their artifacts.
public struct InstallerVersion: Comparable, Equatable, Hashable, Sendable, CustomStringConvertible {
    /// The release contract carries signed 64-bit semantic-version components.
    /// Do not depend on the host's word size for descriptor acceptance.
    public let major: Int64
    public let minor: Int64
    public let patch: Int64

    public init(_ rawValue: String) throws {
        let parts = rawValue.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else {
            throw InstallerVersionError.invalid(rawValue)
        }

        let values = try parts.map { part -> Int64 in
            guard let value = Int64(part), value >= 0, String(value) == String(part) else {
                throw InstallerVersionError.invalid(rawValue)
            }
            return value
        }
        major = values[0]
        minor = values[1]
        patch = values[2]
    }

    public var description: String {
        "\(major).\(minor).\(patch)"
    }

    public static func < (lhs: InstallerVersion, rhs: InstallerVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

public enum InstallerVersionError: Error, Equatable, Sendable {
    case invalid(String)
}

/// A release descriptor that a future trusted bootstrap coordinator has already
/// verified against the installer trust root. The UI never treats a bare
/// GitHub "latest" response as sufficient proof.
public struct VerifiedInstallerRelease: Equatable, Sendable {
    public let version: InstallerVersion
    public let releasePage: String
    public let assetName: String
    public let sha256: String
    public let signingKeyID: String

    public init(
        version: InstallerVersion,
        releasePage: String,
        assetName: String,
        sha256: String,
        signingKeyID: String
    ) {
        self.version = version
        self.releasePage = releasePage
        self.assetName = assetName
        self.sha256 = sha256
        self.signingKeyID = signingKeyID
    }
}

public enum SelfUpdateCheckResult: Equatable, Sendable {
    case verifiedGitHubRelease(VerifiedInstallerRelease)
    case rejected(String)
}

public enum SelfUpdateHandoffResult: Equatable, Sendable {
    /// The trusted bootstrap process has taken responsibility for download,
    /// verification, replacement, and relaunch. The old process must exit.
    case relaunching
    case failed(String)
}

public enum SelfUpdateGate: Equatable, Sendable {
    case checking
    case current(VerifiedInstallerRelease)
    case updateRequired(VerifiedInstallerRelease)
    case relaunching(VerifiedInstallerRelease)
    case failed(String)

    public var isCurrent: Bool {
        if case .current = self {
            return true
        }
        return false
    }
}

public enum ProviderID: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case codex
    case githubCLI = "github-cli"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .codex:
            return "Codex CLI"
        case .githubCLI:
            return "GitHub CLI"
        }
    }

    /// These names are display-only. A future trusted coordinator owns its
    /// exact immutable tool artifact and command invocation contract.
    public var installationScope: String {
        switch self {
        case .codex:
            return "Codex provider"
        case .githubCLI:
            return "GitHub provider"
        }
    }
}

public struct ProviderRequirement: Equatable, Sendable, Identifiable {
    public let provider: ProviderID
    public let isRequired: Bool

    public var id: ProviderID { provider }

    public init(provider: ProviderID, isRequired: Bool) {
        self.provider = provider
        self.isRequired = isRequired
    }
}

/// A trusted coordinator must explicitly project provider requirements from the
/// selected qualified composition.  The pure domain intentionally has no
/// implicit Codex or GitHub CLI defaults: an unresolved or rejected projection
/// blocks the provider gate rather than inventing a profile.
public enum ProviderRequirementsProjectionState: Equatable, Sendable {
    case pending
    case projected
    case rejected

    public var isProjected: Bool {
        self == .projected
    }
}

/// Closed, non-secret classifications for a provider action failure.  A
/// coordinator may retain detailed diagnostics in its own bounded context, but
/// neither a credential, path, command, URL, nor arbitrary output crosses into
/// the wizard state or its UI.
public enum ProviderFailureCode: String, CaseIterable, Codable, Equatable, Sendable {
    case coordinatorUnavailable = "coordinator-unavailable"
    case installationFailed = "installation-failed"
    case authenticationFailed = "authentication-failed"
    case verificationFailed = "verification-failed"
    case unexpectedActionResult = "unexpected-action-result"

    /// The UI receives only this fixed Dutch message, never coordinator output.
    public var userFacingMessage: String {
        switch self {
        case .coordinatorUnavailable:
            return "Providercoördinatie is niet beschikbaar."
        case .installationFailed:
            return "Installatie van de provider is mislukt."
        case .authenticationFailed:
            return "Aanmelding bij de provider is mislukt."
        case .verificationFailed:
            return "Verificatie van de provider is mislukt."
        case .unexpectedActionResult:
            return "De provider gaf een ongeldige uitkomst terug."
        }
    }

    fileprivate func isValid(for action: ProviderAction) -> Bool {
        switch (self, action) {
        case (.coordinatorUnavailable, _):
            return true
        case (.installationFailed, .install),
             (.authenticationFailed, .authenticate),
             (.verificationFailed, .verify):
            return true
        default:
            return false
        }
    }
}

public enum ProviderState: Equatable, Sendable {
    case notSelected
    case selected
    case installing
    case authenticationRequired
    case authenticating
    case verified
    case failed(ProviderFailureCode)

    public var isVerified: Bool {
        if case .verified = self {
            return true
        }
        return false
    }

    public var displayName: String {
        switch self {
        case .notSelected:
            return "Niet geselecteerd"
        case .selected:
            return "Geselecteerd"
        case .installing:
            return "Installatie bezig"
        case .authenticationRequired:
            return "Authenticatie vereist"
        case .authenticating:
            return "Authenticatie bezig"
        case .verified:
            return "Geverifieerd"
        case .failed:
            return "Mislukt"
        }
    }

    public var failureCode: ProviderFailureCode? {
        guard case .failed(let failure) = self else {
            return nil
        }
        return failure
    }
}

public enum ProviderAction: Equatable, Sendable {
    case install
    case authenticate
    case verify
}

/// A coordinator may only report one of these bounded outcomes. It is never
/// passed a command line, credential, or user-supplied executable path.
public enum ProviderActionResult: Equatable, Sendable {
    case installationReady
    case authenticationRequired
    case verified
    case failed(ProviderFailureCode)

    /// Compatibility bridge for older non-provider coordinator seams.  It
    /// deliberately drops the supplied text so it can never become installer
    /// state, UI text, a receipt, or a log field.  New provider coordinators
    /// must return the typed `failed(ProviderFailureCode)` case instead.
    static func failed(_ unsafeDiagnostic: String) -> Self {
        _ = unsafeDiagnostic
        return .failed(.coordinatorUnavailable)
    }
}

public struct ProviderProgress: Equatable, Sendable, Identifiable {
    public let requirement: ProviderRequirement
    public internal(set) var isSelected: Bool
    public internal(set) var state: ProviderState

    public var id: ProviderID { requirement.provider }

    public init(requirement: ProviderRequirement) {
        self.requirement = requirement
        self.isSelected = requirement.isRequired
        self.state = requirement.isRequired ? .selected : .notSelected
    }

    /// A provider is enabled when it is composition-required, or when the
    /// operator explicitly selected a composition-permitted optional provider.
    /// Required remains enabled even if an in-memory caller attempts to alter
    /// its selection flag, so that flag can never bypass the gate.
    public var isEnabled: Bool {
        requirement.isRequired || isSelected
    }

    public var isVerified: Bool {
        isEnabled && state.isVerified
    }
}

public enum CheckState: Equatable, Sendable {
    case pending
    case passed
    case failed(String)

    public var displayName: String {
        switch self {
        case .pending:
            return "In afwachting"
        case .passed:
            return "Geslaagd"
        case .failed:
            return "Mislukt"
        }
    }
}

public struct PreflightCheck: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let detail: String
    public var state: CheckState

    public init(id: String, title: String, detail: String, state: CheckState = .pending) {
        self.id = id
        self.title = title
        self.detail = detail
        self.state = state
    }
}

public struct HostPreflight: Equatable, Sendable {
    public var checks: [PreflightCheck]

    public init(checks: [PreflightCheck] = HostPreflight.defaultChecks) {
        self.checks = checks
    }

    public var isPassed: Bool {
        !checks.isEmpty && checks.allSatisfy { check in
            if case .passed = check.state {
                return true
            }
            return false
        }
    }

    public static let defaultChecks: [PreflightCheck] = [
        PreflightCheck(id: "macos", title: "macOS-versie en architectuur", detail: "Ondersteunde macOS- en CPU-combinatie."),
        PreflightCheck(id: "managed-git", title: "Beheerde Git-toolchain", detail: "Beschikbaarheid en versie via de installer-owned toolchain; geen impliciete mutatie van een globale Git-installatie."),
        PreflightCheck(id: "managed-python", title: "Beheerde Python-toolchain", detail: "Beschikbaarheid en versie voor geïsoleerde componentvenvs; geen selectie via PATH."),
        PreflightCheck(id: "storage", title: "Schijfruimte", detail: "Inclusief reserve voor product-owned backup en rollback."),
        PreflightCheck(id: "memory", title: "Werkgeheugen", detail: "Voldoende geheugen voor de geselecteerde compositie."),
        PreflightCheck(id: "permissions", title: "Systeemrechten", detail: "Geschikt voor een system-domain LaunchDaemon wanneer een product dat vereist."),
        PreflightCheck(id: "network", title: "Netwerk en tijd", detail: "Bereikbaarheid van vertrouwde release- en pairing-eindpunten."),
    ]
}

public enum ComponentChange: String, Equatable, Sendable {
    case install
    case update
    case retain
    case remove
    case blocked

    public var displayName: String {
        switch self {
        case .install:
            return "Installeren"
        case .update:
            return "Bijwerken"
        case .retain:
            return "Behouden"
        case .remove:
            return "Verwijderen"
        case .blocked:
            return "Geblokkeerd"
        }
    }
}

public struct ComponentDiff: Equatable, Sendable, Identifiable {
    public let componentID: String
    public let title: String
    public let change: ComponentChange
    public let installedVersion: String?
    public let candidateVersion: String?
    public let artifactDigest: String?
    public let detail: String

    public var id: String { componentID }

    public init(
        componentID: String,
        title: String,
        change: ComponentChange,
        installedVersion: String? = nil,
        candidateVersion: String? = nil,
        artifactDigest: String? = nil,
        detail: String
    ) {
        self.componentID = componentID
        self.title = title
        self.change = change
        self.installedVersion = installedVersion
        self.candidateVersion = candidateVersion
        self.artifactDigest = artifactDigest
        self.detail = detail
    }
}

public enum CompositionStatus: Equatable, Sendable {
    case pending
    case compatible
    case incompatible(String)

    public var displayName: String {
        switch self {
        case .pending:
            return "Nog niet gekwalificeerd"
        case .compatible:
            return "Compatibel"
        case .incompatible:
            return "Incompatibel"
        }
    }
}

public struct CompositionReview: Equatable, Sendable {
    public var manifestIdentity: String
    public var status: CompositionStatus
    public var components: [ComponentDiff]
    public var isAcknowledged: Bool

    public init(
        manifestIdentity: String = "Nog geen gekwalificeerd compositiemanifest geladen",
        status: CompositionStatus = .pending,
        components: [ComponentDiff] = [],
        isAcknowledged: Bool = false
    ) {
        self.manifestIdentity = manifestIdentity
        self.status = status
        self.components = components
        self.isAcknowledged = isAcknowledged
    }

    public var isReadyForExecution: Bool {
        guard case .compatible = status, isAcknowledged else {
            return false
        }
        return !components.contains { $0.change == .blocked }
    }
}

/// System services are shown as product-declared data only. The shell never
/// creates a privileged helper or writes a service registration.
public enum ServiceScope: String, Equatable, Sendable {
    case systemLaunchDaemon = "System LaunchDaemon"
}

public enum ExecutionStageState: Equatable, Sendable {
    case pending
    case running
    case passed
    case failed(String)

    public var displayName: String {
        switch self {
        case .pending:
            return "In afwachting"
        case .running:
            return "Bezig"
        case .passed:
            return "Geslaagd"
        case .failed:
            return "Mislukt"
        }
    }
}

public struct ExecutionStage: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let detail: String
    public var state: ExecutionStageState

    public init(id: String, title: String, detail: String, state: ExecutionStageState = .pending) {
        self.id = id
        self.title = title
        self.detail = detail
        self.state = state
    }
}

public enum DashboardURLError: Error, Equatable, Sendable {
    case invalid(String)
    case unsupportedScheme(String)
    case missingHost
    case embeddedCredentials
}

/// A product-supplied dashboard endpoint that passed the summary UI's strict
/// transport validation. The UI accepts no raw URL strings, local files, or
/// custom URL schemes as dashboard links.
public struct VerifiedDashboardURL: Equatable, Sendable {
    public let url: URL

    public init(_ rawValue: String) throws {
        guard let parsedURL = URL(string: rawValue), let scheme = parsedURL.scheme?.lowercased() else {
            throw DashboardURLError.invalid(rawValue)
        }
        guard scheme == "http" || scheme == "https" else {
            throw DashboardURLError.unsupportedScheme(scheme)
        }
        guard let host = parsedURL.host, !host.isEmpty else {
            throw DashboardURLError.missingHost
        }
        guard parsedURL.user == nil, parsedURL.password == nil else {
            throw DashboardURLError.embeddedCredentials
        }
        self.url = parsedURL
    }

    public var absoluteString: String {
        url.absoluteString
    }
}

public struct InstallationSummaryItem: Equatable, Sendable, Identifiable {
    public let componentID: String
    public let title: String
    public let status: String
    public let dashboardURL: VerifiedDashboardURL?
    public let serviceScope: ServiceScope?

    public var id: String { componentID }

    public init(
        componentID: String,
        title: String,
        status: String,
        dashboardURL: VerifiedDashboardURL? = nil,
        serviceScope: ServiceScope? = nil
    ) {
        self.componentID = componentID
        self.title = title
        self.status = status
        self.dashboardURL = dashboardURL
        self.serviceScope = serviceScope
    }
}

public enum WizardStep: Int, CaseIterable, Equatable, Sendable, Identifiable {
    case selfUpdate
    case preflight
    case providers
    case composition
    case execution
    case summary

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .selfUpdate:
            return "Installer bijwerken"
        case .preflight:
            return "Hostcontrole"
        case .providers:
            return "Providers"
        case .composition:
            return "Compositie"
        case .execution:
            return "Uitvoering"
        case .summary:
            return "Samenvatting"
        }
    }
}

/// Pure state machine for the native wizard. It accepts evidence supplied by a
/// future trusted coordinator but never runs a command, touches a product
/// database, selects a runtime, or mutates a service/venv itself.
public struct InstallerWizardState: Equatable, Sendable {
    public let currentInstallerVersion: InstallerVersion
    public var step: WizardStep
    public private(set) var selfUpdate: SelfUpdateGate
    public var preflight: HostPreflight
    public private(set) var providerRequirementsProjection: ProviderRequirementsProjectionState
    /// The accepted projection is domain-owned and write-once.  Consumers may
    /// render provider progress but cannot replace or clear it to bypass the
    /// provider gate.
    public private(set) var providers: [ProviderProgress]
    public var composition: CompositionReview
    public var executionStages: [ExecutionStage]
    public var summaryItems: [InstallationSummaryItem]

    public init(
        currentInstallerVersion: InstallerVersion,
        providerRequirements: [ProviderRequirement]? = nil
    ) {
        self.currentInstallerVersion = currentInstallerVersion
        self.step = .selfUpdate
        self.selfUpdate = .checking
        self.preflight = HostPreflight()
        if let providerRequirements {
            if Self.hasUniqueProviderIDs(providerRequirements) {
                self.providerRequirementsProjection = .projected
                self.providers = providerRequirements.map(ProviderProgress.init(requirement:))
            } else {
                self.providerRequirementsProjection = .rejected
                self.providers = []
            }
        } else {
            self.providerRequirementsProjection = .pending
            self.providers = []
        }
        self.composition = CompositionReview()
        self.executionStages = []
        self.summaryItems = []
    }

    /// Returns whether a trusted coordinator has explicitly supplied a valid
    /// provider projection.  An explicit empty projection is valid only for a
    /// qualified profile that needs no user-scoped provider.
    public var providerRequirementsAreProjected: Bool {
        providerRequirementsProjection.isProjected
    }

    public var enabledProviders: [ProviderProgress] {
        providers.filter(\.isEnabled)
    }

    /// Every enabled provider, including a selected optional provider, must be
    /// verified before this gate may advance.  An unprojected requirement set
    /// fails closed even though it currently has no provider rows.
    public var enabledProvidersVerified: Bool {
        providerRequirementsAreProjected && enabledProviders.allSatisfy(\.isVerified)
    }

    /// Kept as a source-compatible read-only projection for the current shell.
    /// It deliberately has the stronger enabled-provider semantics above; a
    /// future UI can use `enabledProvidersVerified` by name.
    public var requiredProvidersVerified: Bool {
        enabledProvidersVerified
    }

    public var canAdvance: Bool {
        switch step {
        case .selfUpdate:
            return selfUpdate.isCurrent
        case .preflight:
            return preflight.isPassed
        case .providers:
            return enabledProvidersVerified
        case .composition:
            return composition.isReadyForExecution
        case .execution:
            return !executionStages.isEmpty && executionStages.allSatisfy { stage in
                if case .passed = stage.state {
                    return true
                }
                return false
            }
        case .summary:
            return false
        }
    }

    public mutating func recordSelfUpdateCheck(_ result: SelfUpdateCheckResult) {
        switch result {
        case .verifiedGitHubRelease(let release):
            selfUpdate = release.version > currentInstallerVersion ? .updateRequired(release) : .current(release)
        case .rejected(let reason):
            selfUpdate = .failed(reason)
        }
    }

    /// Moves to a terminal handoff state before the trusted bootstrapper exits
    /// this process and relaunches the verified newer installer.
    @discardableResult
    public mutating func beginSelfUpdateHandoff() -> VerifiedInstallerRelease? {
        guard case .updateRequired(let release) = selfUpdate else {
            return nil
        }
        selfUpdate = .relaunching(release)
        return release
    }

    public mutating func recordSelfUpdateHandoff(_ result: SelfUpdateHandoffResult, for release: VerifiedInstallerRelease) {
        switch result {
        case .relaunching:
            selfUpdate = .relaunching(release)
        case .failed(let reason):
            selfUpdate = .failed(reason)
        }
    }

    /// Applies the non-secret provider requirement projection supplied by the
    /// trusted composition coordinator.  The pure state machine cannot prove
    /// that trust itself; it only refuses to advance until such a projection is
    /// present and structurally unambiguous.  Projection is write-once: a
    /// later request cannot replace an unverified required provider with an
    /// empty or weaker set.
    @discardableResult
    public mutating func applyProviderRequirementsProjection(_ requirements: [ProviderRequirement]) -> Bool {
        guard providerRequirementsProjection == .pending,
              step.rawValue <= WizardStep.providers.rawValue else {
            return false
        }
        guard Self.hasUniqueProviderIDs(requirements) else {
            providerRequirementsProjection = .rejected
            providers = []
            return false
        }
        providerRequirementsProjection = .projected
        providers = requirements.map(ProviderProgress.init(requirement:))
        return true
    }

    @discardableResult
    public mutating func setProviderSelected(_ providerID: ProviderID, isSelected: Bool) -> Bool {
        guard providerRequirementsAreProjected,
              let index = providers.firstIndex(where: { $0.id == providerID }) else {
            return false
        }
        guard !providers[index].requirement.isRequired || isSelected else {
            return false
        }
        providers[index].isSelected = isSelected
        providers[index].state = isSelected ? .selected : .notSelected
        return true
    }

    @discardableResult
    public mutating func requestProviderAction(_ action: ProviderAction, for providerID: ProviderID) -> Bool {
        guard providerRequirementsAreProjected,
              let index = providers.firstIndex(where: { $0.id == providerID }),
              providers[index].isEnabled else {
            return false
        }

        switch (providers[index].state, action) {
        case (.selected, .install), (.failed, .install):
            providers[index].state = .installing
        case (.authenticationRequired, .authenticate):
            providers[index].state = .authenticating
        case (.authenticationRequired, .verify), (.authenticating, .verify):
            providers[index].state = .authenticating
        default:
            return false
        }
        return true
    }

    public mutating func applyProviderActionResult(
        _ result: ProviderActionResult,
        for providerID: ProviderID,
        action: ProviderAction
    ) {
        guard providerRequirementsAreProjected,
              let index = providers.firstIndex(where: { $0.id == providerID }),
              providers[index].isEnabled else {
            return
        }
        guard Self.isAwaitingProviderActionResult(providers[index].state, for: action) else {
            providers[index].state = .failed(.unexpectedActionResult)
            return
        }

        switch (action, result) {
        case (.install, .installationReady), (.install, .authenticationRequired):
            providers[index].state = .authenticationRequired
        case (.authenticate, .verified), (.verify, .verified):
            providers[index].state = .verified
        case (let action, .failed(let failure)) where failure.isValid(for: action):
            providers[index].state = .failed(failure)
        default:
            providers[index].state = .failed(.unexpectedActionResult)
        }
    }

    @discardableResult
    public mutating func advance() -> Bool {
        guard canAdvance, let next = WizardStep(rawValue: step.rawValue + 1) else {
            return false
        }
        step = next
        return true
    }

    @discardableResult
    public mutating func goBack() -> Bool {
        guard let previous = WizardStep(rawValue: step.rawValue - 1) else {
            return false
        }
        step = previous
        return true
    }

    private static func hasUniqueProviderIDs(_ requirements: [ProviderRequirement]) -> Bool {
        Set(requirements.map(\.provider)).count == requirements.count
    }

    private static func isAwaitingProviderActionResult(
        _ state: ProviderState,
        for action: ProviderAction
    ) -> Bool {
        switch (state, action) {
        case (.installing, .install),
             (.authenticating, .authenticate),
             (.authenticating, .verify):
            return true
        default:
            return false
        }
    }
}

/// The shell can only request fixed, non-secret actions. Implementations that
/// actually download an installer or launch a provider flow belong to a later
/// trusted coordinator and must verify immutable artifacts before execution.
public protocol InstallerWizardCoordinator: Sendable {
    func checkForUpdate(currentVersion: InstallerVersion) async -> SelfUpdateCheckResult
    func handOffSelfUpdate(_ release: VerifiedInstallerRelease) async -> SelfUpdateHandoffResult
    func performProviderAction(_ action: ProviderAction, for provider: ProviderID) async -> ProviderActionResult
}

/// Safe default for the shell before a signed release/bootstrap coordinator is
/// connected. It deliberately leaves every privileged or credential-bearing
/// action blocked rather than attempting a PATH lookup or arbitrary shell call.
public struct UnavailableInstallerWizardCoordinator: InstallerWizardCoordinator {
    public init() {}

    public func checkForUpdate(currentVersion: InstallerVersion) async -> SelfUpdateCheckResult {
        .rejected("Geen vertrouwde release-coördinator gekoppeld; updatecontrole is fail-closed geblokkeerd.")
    }

    public func handOffSelfUpdate(_ release: VerifiedInstallerRelease) async -> SelfUpdateHandoffResult {
        .failed("Geen vertrouwde bootstrapper gekoppeld voor download, verificatie en herstart.")
    }

    public func performProviderAction(_ action: ProviderAction, for provider: ProviderID) async -> ProviderActionResult {
        .failed(.coordinatorUnavailable)
    }
}
