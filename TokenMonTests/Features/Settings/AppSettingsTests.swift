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
        first.setMenuBarGraph(.cursor, shown: true)
        first.setMenuBarGraph(.claude, shown: true)
        first.setMenuBarGraph(.grokbot, shown: true)

        let second = makeSettings()
        XCTAssertEqual(second.activePollSeconds, 45)
        XCTAssertTrue(second.showsMenuBarGraph(.cursor))
        XCTAssertTrue(second.showsMenuBarGraph(.claude))
        XCTAssertTrue(second.showsMenuBarGraph(.grokbot))
    }

    /// Panel sections start open; a closed section stays closed on the next
    /// launch, and reopening it is saved too.
    func testPanelSectionsDefaultOpenAndPersist() {
        let first = makeSettings()
        XCTAssertTrue(PanelSection.allCases.allSatisfy(first.isExpanded))

        first.setExpanded(false, for: .claudeModels)
        let second = makeSettings()
        XCTAssertFalse(second.isExpanded(.claudeModels))
        XCTAssertTrue(second.isExpanded(.openCodeModels))

        second.setExpanded(true, for: .claudeModels)
        XCTAssertTrue(makeSettings().isExpanded(.claudeModels))
    }

    func testPanelSectionIgnoresUnknownSavedValues() {
        defaults.set(["openCodeModels", "retiredSection"], forKey: "collapsedPanelSections")
        XCTAssertEqual(makeSettings().collapsedPanelSections, [.openCodeModels])
        XCTAssertNil(PanelSection(rawValue: "retiredSection"))
        XCTAssertEqual(PanelSection(rawValue: PanelSection.claudeModels.rawValue), .claudeModels)
    }

    func testShowSelectedProviderDefaultsOffAndPersists() throws {
        XCTAssertFalse(makeSettings().showSelectedProviderInMenuBar)

        let first = makeSettings()
        first.showSelectedProviderInMenuBar = true

        XCTAssertTrue(makeSettings().showSelectedProviderInMenuBar)
    }

    /// The usage alert starts off; once the user turns it on, it stays on.
    func testThresholdAlertDefaultsOffAndPersists() {
        XCTAssertFalse(makeSettings().thresholdEnabled)

        makeSettings().thresholdEnabled = true

        XCTAssertTrue(makeSettings().thresholdEnabled)
    }

    func testNeedsGrokPollingFollowsBarAndProvider() {
        let settings = makeSettings()
        settings.selectedProvider = .cursor
        settings.setMenuBarGraph(.grok, shown: false)
        settings.thresholdEnabled = false
        XCTAssertFalse(settings.needsPolling(.grok))

        settings.setMenuBarGraph(.grok, shown: true)
        XCTAssertTrue(settings.needsPolling(.grok))

        settings.setMenuBarGraph(.grok, shown: false)
        settings.selectedProvider = .grok
        XCTAssertTrue(settings.needsPolling(.grok))
    }

    /// The usage alert is evaluated on each provider's polls, so it keeps every
    /// enabled provider polling.
    func testThresholdAlertKeepsEveryProviderPolling() {
        let settings = makeSettings()
        settings.enabledProviderIDs = Set(MonitorProvider.allCases.filter { $0 != .overview })
        settings.selectedProvider = .grok
        settings.setMenuBarGraph(.grok, shown: false)
        settings.setMenuBarGraph(.opencode, shown: false)
        settings.setMenuBarGraph(.cursor, shown: false)
        settings.setMenuBarGraph(.claude, shown: false)
        settings.setMenuBarGraph(.grokbot, shown: false)
        settings.thresholdEnabled = true
        for provider in MonitorProvider.allCases where provider != .overview {
            XCTAssertTrue(settings.needsPolling(provider), "\(provider)")
        }
        settings.thresholdEnabled = false
        XCTAssertFalse(settings.needsPolling(.chatgpt))
    }

    /// A provider left out of the alert stops polling for it, and the choice
    /// is saved.
    func testAlertProvidersLimitAlertPolling() {
        let settings = makeSettings()
        settings.selectedProvider = .grok
        settings.thresholdEnabled = true
        XCTAssertTrue(settings.needsPolling(.chatgpt))
        settings.alertProviders.remove(.chatgpt)
        XCTAssertFalse(settings.needsPolling(.chatgpt))
        XCTAssertFalse(settings.alertWatches(.chatgpt))
        XCTAssertTrue(settings.alertWatches(.claude))
        XCTAssertFalse(makeSettings().alertProviders.contains(.chatgpt))
    }

    func testNeedsOpenCodeAndCursorPollingOnOverview() {
        let settings = makeSettings()
        settings.selectedProvider = .overview
        XCTAssertTrue(settings.needsPolling(.opencode))
        XCTAssertTrue(settings.needsPolling(.cursor))
        XCTAssertTrue(settings.needsPolling(.grok))
    }

    func testNeedsPollingOffWhenBarsHiddenAndOtherTabSelected() {
        let settings = makeSettings()
        settings.thresholdEnabled = false
        settings.selectedProvider = .grok
        settings.setMenuBarGraph(.cursor, shown: false)
        settings.setMenuBarGraph(.opencode, shown: false)
        settings.setMenuBarGraph(.grokbot, shown: false)
        XCTAssertFalse(settings.needsPolling(.cursor))
        XCTAssertFalse(settings.needsPolling(.opencode))
        XCTAssertFalse(settings.needsPolling(.grokbot))
    }

    func testNeedsGrokbotPollingFollowsBarAndProvider() {
        let settings = makeSettings()
        settings.thresholdEnabled = false
        settings.selectedProvider = .cursor
        settings.setMenuBarGraph(.grokbot, shown: false)
        XCTAssertFalse(settings.needsPolling(.grokbot))

        settings.setMenuBarGraph(.grokbot, shown: true)
        XCTAssertTrue(settings.needsPolling(.grokbot))

        settings.setMenuBarGraph(.grokbot, shown: false)
        settings.selectedProvider = .grokbot
        XCTAssertTrue(settings.needsPolling(.grokbot))

        settings.selectedProvider = .overview
        XCTAssertTrue(settings.needsPolling(.grokbot))
    }

    func testNeedsClaudePollingFollowsBarAndProvider() {
        let settings = makeSettings()
        settings.thresholdEnabled = false
        settings.selectedProvider = .cursor
        settings.setMenuBarGraph(.claude, shown: false)
        XCTAssertFalse(settings.needsPolling(.claude))

        settings.setMenuBarGraph(.claude, shown: true)
        XCTAssertTrue(settings.needsPolling(.claude))

        settings.setMenuBarGraph(.claude, shown: false)
        settings.selectedProvider = .claude
        XCTAssertTrue(settings.needsPolling(.claude))
    }

    // MARK: - Provider visibility

    /// A disabled provider does not poll even when it is the selected tab or has
    /// a menu-bar bar: enablement is a lifecycle gate, not just a filter.
    func testDisabledProviderDoesNotPoll() {
        let settings = makeSettings()
        settings.selectedProvider = .overview
        settings.enabledProviderIDs = [.cursor]
        XCTAssertFalse(settings.needsPolling(.grokbot))
        XCTAssertFalse(settings.needsPolling(.grok))
        XCTAssertFalse(settings.needsPolling(.claude))
        XCTAssertTrue(settings.needsPolling(.cursor))
    }

    /// A disabled Grokbot does not poll the shared Cursor session, even
    /// when its menu-bar bar is on.
    func testDisabledGrokbotDoesNotPollEvenWithBarEnabled() {
        let settings = makeSettings()
        settings.enabledProviderIDs = [.grok, .cursor]
        settings.setMenuBarGraph(.grokbot, shown: true)
        settings.selectedProvider = .grokbot
        XCTAssertFalse(settings.needsPolling(.grokbot))
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

    func testNeedsPollingFollowsTabAndDefaultGraphs() {
        let settings = makeSettings()
        settings.thresholdEnabled = false
        settings.selectedProvider = .chatgpt
        // Grok's graph is on by default; Cursor's is off.
        XCTAssertTrue(settings.needsPolling(.grok))
        XCTAssertFalse(settings.needsPolling(.cursor))
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

    /// Graph settings saved as one flag per provider become the set, and the
    /// flags are removed.
    func testPerProviderGraphFlagsBecomeTheGraphSet() {
        defaults.set(false, forKey: "showGrokBarInMenuBar")
        defaults.set(true, forKey: "showClaudeBarInMenuBar")
        defaults.set(true, forKey: "showGrokbotBarInMenuBar")
        let settings = makeSettings()
        XCTAssertEqual(settings.menuBarGraphProviders, [.claude, .grokbot])
        XCTAssertNil(defaults.object(forKey: "showClaudeBarInMenuBar"))
        XCTAssertEqual(makeSettings().menuBarGraphProviders, [.claude, .grokbot])
    }

    func testGraphSetDefaultsToGrokOnly() {
        XCTAssertEqual(makeSettings().menuBarGraphProviders, [.grok])
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
