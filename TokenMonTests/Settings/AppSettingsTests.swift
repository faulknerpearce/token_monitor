import ServiceManagement
@testable import TokenMon
import XCTest

/// AppSettings clamps, persistence keys, and needs*Polling gating —
/// all against an isolated UserDefaults suite.
@MainActor
final class AppSettingsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "AppSettingsTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeSettings() -> AppSettings {
        AppSettings(defaults: defaults)
    }

    func testActivePollClampedToMinimum() throws {
        let settings = makeSettings()
        settings.activePollSeconds = 1
        XCTAssertEqual(settings.activePollSeconds, 15)
    }

    func testActivePollClampedToMaximum() throws {
        let settings = makeSettings()
        settings.activePollSeconds = 10_000
        XCTAssertEqual(settings.activePollSeconds, 300)
    }

    func testIdlePollClamped() throws {
        let settings = makeSettings()
        settings.idlePollSeconds = 0
        XCTAssertEqual(settings.idlePollSeconds, 60)
        settings.idlePollSeconds = 100_000
        XCTAssertEqual(settings.idlePollSeconds, 3600)
    }

    func testValuesPersistAcrossInstances() throws {
        let first = makeSettings()
        first.activePollSeconds = 45
        first.showCursorBarInMenuBar = true
        first.showClaudeBarInMenuBar = true
        first.showGrokbotBarInMenuBar = true

        let second = makeSettings()
        XCTAssertEqual(second.activePollSeconds, 45)
        XCTAssertTrue(second.showCursorBarInMenuBar)
        XCTAssertTrue(second.showClaudeBarInMenuBar)
        XCTAssertTrue(second.showGrokbotBarInMenuBar)
    }

    func testShowSelectedProviderDefaultsOffAndPersists() throws {
        XCTAssertFalse(makeSettings().showSelectedProviderInMenuBar)

        let first = makeSettings()
        first.showSelectedProviderInMenuBar = true

        XCTAssertTrue(makeSettings().showSelectedProviderInMenuBar)
    }

    func testNeedsGrokPollingFollowsBarAndProvider() {
        let settings = makeSettings()
        settings.selectedProvider = .cursor
        settings.showGrokBarInMenuBar = false
        settings.thresholdEnabled = false
        XCTAssertFalse(settings.needsGrokPolling)

        settings.showGrokBarInMenuBar = true
        XCTAssertTrue(settings.needsGrokPolling)

        settings.showGrokBarInMenuBar = false
        settings.selectedProvider = .grok
        XCTAssertTrue(settings.needsGrokPolling)
    }

    /// The usage alert is evaluated on each provider's polls, so it keeps every
    /// enabled provider polling.
    func testThresholdAlertKeepsEveryProviderPolling() {
        let settings = makeSettings()
        settings.enabledProviderIDs = Set(MonitorProvider.allCases.filter { $0 != .overview })
        settings.selectedProvider = .grok
        settings.showGrokBarInMenuBar = false
        settings.showOpenCodeBarInMenuBar = false
        settings.showCursorBarInMenuBar = false
        settings.showClaudeBarInMenuBar = false
        settings.showGrokbotBarInMenuBar = false
        settings.thresholdEnabled = true
        for provider in MonitorProvider.allCases where provider != .overview {
            XCTAssertTrue(settings.needsPolling(provider), "\(provider)")
        }
        settings.thresholdEnabled = false
        XCTAssertFalse(settings.needsPolling(.chatgpt))
    }

    func testNeedsOpenCodeAndCursorPollingOnOverview() {
        let settings = makeSettings()
        settings.selectedProvider = .overview
        XCTAssertTrue(settings.needsOpenCodePolling)
        XCTAssertTrue(settings.needsCursorPolling)
        XCTAssertTrue(settings.needsGrokPolling)
    }

    func testNeedsPollingOffWhenBarsHiddenAndOtherTabSelected() {
        let settings = makeSettings()
        settings.thresholdEnabled = false
        settings.selectedProvider = .grok
        settings.showCursorBarInMenuBar = false
        settings.showOpenCodeBarInMenuBar = false
        settings.showGrokbotBarInMenuBar = false
        XCTAssertFalse(settings.needsCursorPolling)
        XCTAssertFalse(settings.needsOpenCodePolling)
        XCTAssertFalse(settings.needsGrokbotPolling)
    }

    func testNeedsGrokbotPollingFollowsBarAndProvider() {
        let settings = makeSettings()
        settings.thresholdEnabled = false
        settings.selectedProvider = .cursor
        settings.showGrokbotBarInMenuBar = false
        XCTAssertFalse(settings.needsGrokbotPolling)

        settings.showGrokbotBarInMenuBar = true
        XCTAssertTrue(settings.needsGrokbotPolling)

        settings.showGrokbotBarInMenuBar = false
        settings.selectedProvider = .grokbot
        XCTAssertTrue(settings.needsGrokbotPolling)

        settings.selectedProvider = .overview
        XCTAssertTrue(settings.needsGrokbotPolling)
    }

    func testNeedsClaudePollingFollowsBarAndProvider() {
        let settings = makeSettings()
        settings.thresholdEnabled = false
        settings.selectedProvider = .cursor
        settings.showClaudeBarInMenuBar = false
        XCTAssertFalse(settings.needsClaudePolling)

        settings.showClaudeBarInMenuBar = true
        XCTAssertTrue(settings.needsClaudePolling)

        settings.showClaudeBarInMenuBar = false
        settings.selectedProvider = .claude
        XCTAssertTrue(settings.needsClaudePolling)
    }

    // MARK: - Provider visibility

    /// A disabled provider does not poll even when it is the selected tab or has
    /// a menu-bar bar: enablement is a lifecycle gate, not just a filter.
    func testDisabledProviderDoesNotPoll() {
        let settings = makeSettings()
        settings.selectedProvider = .overview
        settings.enabledProviderIDs = [.cursor]
        XCTAssertFalse(settings.needsGrokbotPolling)
        XCTAssertFalse(settings.needsGrokPolling)
        XCTAssertFalse(settings.needsClaudePolling)
        XCTAssertTrue(settings.needsCursorPolling)
    }

    /// A disabled Grokbot does not poll the shared Cursor session, even
    /// when its menu-bar bar is on.
    func testDisabledGrokbotDoesNotPollEvenWithBarEnabled() {
        let settings = makeSettings()
        settings.enabledProviderIDs = [.grok, .cursor]
        settings.showGrokbotBarInMenuBar = true
        settings.selectedProvider = .grokbot
        XCTAssertFalse(settings.needsGrokbotPolling)
    }

    func testEnabledProvidersDefaultToAllUsageProviders() {
        let settings = makeSettings()
        XCTAssertEqual(settings.enabledProviderIDs, Set(MonitorProvider.usageProviders))
        XCTAssertEqual(settings.visibleUsageProviders, MonitorProvider.usageProviders)
    }

    func testVisibleUsageProvidersFollowUsageProviderOrder() {
        let settings = makeSettings()
        settings.enabledProviderIDs = [.opencode, .grok]
        XCTAssertEqual(settings.visibleUsageProviders, [.grok, .opencode])
    }

    func testProviderOrderDefaultsToUsageProviders() {
        XCTAssertEqual(makeSettings().providerOrder, MonitorProvider.usageProviders)
        XCTAssertEqual(makeSettings().orderedUsageProviders, MonitorProvider.usageProviders)
    }

    func testProviderOrderPersistsAndAppendsNewProviders() {
        defaults.set(["claude", "grok"], forKey: "providerOrder")
        let settings = makeSettings()
        XCTAssertEqual(settings.orderedUsageProviders.first, .claude)
        XCTAssertEqual(settings.orderedUsageProviders[1], .grok)
        for provider in MonitorProvider.usageProviders {
            XCTAssertTrue(settings.orderedUsageProviders.contains(provider))
        }
        XCTAssertEqual(settings.orderedUsageProviders.count, MonitorProvider.usageProviders.count)
    }

    func testMoveProviderInsertsAtTargetSlot() {
        let settings = makeSettings()
        settings.moveProvider(.claude, to: .grok)
        XCTAssertEqual(settings.orderedUsageProviders.first, .claude)
        XCTAssertEqual(settings.orderedUsageProviders[1], .grok)
    }

    func testNormalizedOrderDropsOverviewAndDuplicates() {
        let order = MonitorProvider.normalizedOrder([.overview, .grok, .grok, .claude])
        XCTAssertEqual(order.first, .grok)
        XCTAssertEqual(order.filter { $0 == .grok }.count, 1)
        XCTAssertFalse(order.contains(.overview))
        XCTAssertEqual(order.count, MonitorProvider.usageProviders.count)
    }

    func testEnabledProvidersPersistAcrossInstances() throws {
        let first = makeSettings()
        first.enabledProviderIDs = [.grok, .cursor]

        let second = makeSettings()
        XCTAssertEqual(second.enabledProviderIDs, [.grok, .cursor])
        XCTAssertEqual(second.visibleUsageProviders, [.grok, .cursor])
    }

    func testCannotRemoveLastEnabledProvider() {
        let settings = makeSettings()
        settings.enabledProviderIDs = [.cursor]

        settings.enabledProviderIDs = []

        XCTAssertEqual(settings.enabledProviderIDs, [.cursor])
    }

    func testStoredOverviewAndUnknownValuesAreIgnored() {
        defaults.set(["overview", "gemini", "copilot"], forKey: "enabledProviderIDs")
        let settings = makeSettings()
        XCTAssertEqual(settings.enabledProviderIDs, Set(MonitorProvider.usageProviders))
    }

    func testStoredValidSubsetSurvivesLoad() {
        defaults.set(["opencode", "overview"], forKey: "enabledProviderIDs")
        let settings = makeSettings()
        XCTAssertEqual(settings.enabledProviderIDs, [.opencode])
    }

    func testThresholdPercentIsClampedOnLoad() {
        defaults.set(250.0, forKey: "thresholdPercent")
        XCTAssertEqual(makeSettings().thresholdPercent, 99)

        defaults.set(-5.0, forKey: "thresholdPercent")
        XCTAssertEqual(makeSettings().thresholdPercent, 50)
    }

    func testThresholdPercentIsClampedOnSet() {
        let settings = makeSettings()
        settings.thresholdPercent = 10
        XCTAssertEqual(settings.thresholdPercent, AppSettings.thresholdRange.lowerBound)
        XCTAssertEqual(defaults.double(forKey: "thresholdPercent"), 50)
    }

    func testRetiredVisibleProductsFallBackToAllKnown() {
        defaults.set(["legacyWidget"], forKey: "visibleProductIDs")
        let settings = makeSettings()
        XCTAssertEqual(settings.visibleProductIDs, Set(ProductCatalog.knownIDs))
    }

    func testEmptyVisibleProductsIsPreserved() {
        defaults.set([String](), forKey: "visibleProductIDs")
        XCTAssertTrue(makeSettings().visibleProductIDs.isEmpty)
    }

    func testVisibleProductsDropUnknownIds() {
        defaults.set(["chat", "legacyWidget"], forKey: "visibleProductIDs")
        let settings = makeSettings()
        XCTAssertEqual(settings.visibleProductIDs, ["chat"])
    }

    func testDisablingTheSelectedProviderFallsBackToOverview() {
        let settings = makeSettings()
        settings.selectedProvider = .cursor
        settings.enabledProviderIDs.remove(.cursor)
        XCTAssertEqual(settings.selectedProvider, .overview)
        XCTAssertEqual(makeSettings().selectedProvider, .overview, "the fallback is persisted")
    }

    func testDisablingAnotherProviderKeepsTheSelection() {
        let settings = makeSettings()
        settings.selectedProvider = .cursor
        settings.enabledProviderIDs.remove(.claude)
        XCTAssertEqual(settings.selectedProvider, .cursor)
    }

    func testProviderOrderPersistsTheNormalizedValue() {
        let settings = makeSettings()
        settings.providerOrder = [.claude, .claude, .overview]
        let expected = MonitorProvider.normalizedOrder([.claude])
        XCTAssertEqual(settings.providerOrder, expected)
        XCTAssertEqual(defaults.stringArray(forKey: "providerOrder"), expected.map(\.rawValue))
    }

    func testNeedsPollingMatchesTheProviderFlags() {
        let settings = makeSettings()
        settings.thresholdEnabled = false
        settings.selectedProvider = .chatgpt
        XCTAssertEqual(settings.needsPolling(.grok), settings.needsGrokPolling)
        XCTAssertEqual(settings.needsPolling(.cursor), settings.needsCursorPolling)
        XCTAssertTrue(settings.needsPolling(.chatgpt))
        XCTAssertFalse(settings.needsPolling(.openrouter))
        XCTAssertFalse(settings.needsPolling(.overview))
    }

    func testLaunchAtLoginShowsOnWhileAwaitingApproval() {
        let loginItem = FakeLoginItem(status: .requiresApproval)
        let settings = AppSettings(defaults: defaults, loginItem: loginItem)
        XCTAssertTrue(settings.launchAtLogin)
        XCTAssertTrue(settings.launchAtLoginNeedsApproval)

        loginItem.status = .enabled
        settings.refreshLaunchAtLoginStatus()
        XCTAssertTrue(settings.launchAtLogin)
        XCTAssertFalse(settings.launchAtLoginNeedsApproval)
    }

    func testLaunchAtLoginRegistersAndRevertsOnFailure() {
        let loginItem = FakeLoginItem(status: .notRegistered)
        let settings = AppSettings(defaults: defaults, loginItem: loginItem)
        XCTAssertFalse(settings.launchAtLogin)

        loginItem.registerResult = .requiresApproval
        settings.launchAtLogin = true
        XCTAssertEqual(loginItem.registerCalls, 1)
        XCTAssertTrue(settings.launchAtLogin)
        XCTAssertTrue(settings.launchAtLoginNeedsApproval)

        loginItem.failUnregister = true
        settings.launchAtLogin = false
        XCTAssertTrue(settings.launchAtLogin, "a failed unregister reverts to the real status")
    }
}

@MainActor
private final class FakeLoginItem: LoginItemService {
    var status: SMAppService.Status
    var registerResult: SMAppService.Status = .enabled
    var failUnregister = false
    private(set) var registerCalls = 0

    init(status: SMAppService.Status) {
        self.status = status
    }

    func register() throws {
        registerCalls += 1
        status = registerResult
    }

    func unregister() throws {
        if failUnregister { throw CocoaError(.featureUnsupported) }
        status = .notRegistered
    }
}
