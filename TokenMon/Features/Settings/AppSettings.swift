import Foundation
import ServiceManagement
import SwiftUI

/// The login-item registration `AppSettings` drives (`SMAppService.mainApp`
/// in the app; tests inject a fake so they never touch the real login item).
@MainActor
protocol LoginItemService: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LoginItemService {}

/// Persisted user settings published to pollers and menu-bar surfaces.
@MainActor
final class AppSettings: ObservableObject {
    private let defaults: UserDefaults
    private let loginItem: LoginItemService

    @Published var showCategoriesInMenuBar: Bool {
        didSet {
            guard showCategoriesInMenuBar != oldValue else { return }
            defaults.set(showCategoriesInMenuBar, forKey: Keys.showCategories)
        }
    }

    /// Grok segmented bar in the menu bar.
    @Published var showGrokBarInMenuBar: Bool {
        didSet {
            guard showGrokBarInMenuBar != oldValue else { return }
            defaults.set(showGrokBarInMenuBar, forKey: Keys.showGrokBar)
        }
    }

    /// OpenCode usage % + bar in the menu bar.
    @Published var showOpenCodeBarInMenuBar: Bool {
        didSet {
            guard showOpenCodeBarInMenuBar != oldValue else { return }
            defaults.set(showOpenCodeBarInMenuBar, forKey: Keys.showOpenCodeBar)
        }
    }

    /// Cursor usage % + bar in the menu bar.
    @Published var showCursorBarInMenuBar: Bool {
        didSet {
            guard showCursorBarInMenuBar != oldValue else { return }
            defaults.set(showCursorBarInMenuBar, forKey: Keys.showCursorBar)
        }
    }

    /// Claude usage % + bar in the menu bar.
    @Published var showClaudeBarInMenuBar: Bool {
        didSet {
            guard showClaudeBarInMenuBar != oldValue else { return }
            defaults.set(showClaudeBarInMenuBar, forKey: Keys.showClaudeBar)
        }
    }

    /// Grokbot usage % + bar in the menu bar.
    @Published var showGrokbotBarInMenuBar: Bool {
        didSet {
            guard showGrokbotBarInMenuBar != oldValue else { return }
            defaults.set(showGrokbotBarInMenuBar, forKey: Keys.showGrokbotBar)
        }
    }

    /// When on, TokenMon checks GitHub for a newer release and shows a row in
    /// the menu when one exists. Installing it is a separate, user-initiated
    /// action (`UpdateChecker.installAvailableUpdate`).
    @Published var checksForUpdates: Bool {
        didSet {
            guard checksForUpdates != oldValue else { return }
            defaults.set(checksForUpdates, forKey: Keys.checksForUpdates)
        }
    }

    /// When on, the menu bar shows only the selected provider (icon + % + bar)
    /// instead of the pinned graph composite.
    @Published var showSelectedProviderInMenuBar: Bool {
        didSet {
            guard showSelectedProviderInMenuBar != oldValue else { return }
            defaults.set(showSelectedProviderInMenuBar, forKey: Keys.showSelectedProvider)
        }
    }

    @Published var activePollSeconds: Int {
        didSet {
            let clamped = Self.clampActivePoll(activePollSeconds)
            if activePollSeconds != clamped { activePollSeconds = clamped }
            defaults.set(activePollSeconds, forKey: Keys.activePoll)
        }
    }

    @Published var idlePollSeconds: Int {
        didSet {
            let clamped = Self.clampIdlePoll(idlePollSeconds)
            if idlePollSeconds != clamped { idlePollSeconds = clamped }
            defaults.set(idlePollSeconds, forKey: Keys.idlePoll)
        }
    }

    @Published var thresholdEnabled: Bool {
        didSet { defaults.set(thresholdEnabled, forKey: Keys.thresholdEnabled) }
    }

    @Published var thresholdPercent: Double {
        didSet {
            let clamped = Self.clampThreshold(thresholdPercent)
            if thresholdPercent != clamped { thresholdPercent = clamped }
            defaults.set(thresholdPercent, forKey: Keys.thresholdPercent)
        }
    }

    @Published var visibleProductIDs: Set<String> {
        didSet {
            defaults.set(Array(visibleProductIDs), forKey: Keys.visibleProducts)
        }
    }

    /// Usage providers shown as tabs in the dropdown switcher (Overview always present).
    var visibleUsageProviders: [MonitorProvider] {
        orderedUsageProviders.filter { enabledProviderIDs.contains($0) }
    }

    /// All usage providers in the user-chosen display order.
    var orderedUsageProviders: [MonitorProvider] {
        MonitorProvider.normalizedOrder(providerOrder)
    }

    /// Saved permutation of usage providers; drives tab order, Overview cards,
    /// and composite menu-bar graph order.
    @Published var providerOrder: [MonitorProvider] {
        didSet {
            guard providerOrder != oldValue else { return }
            // Assigning inside `didSet` does not re-run the observer, so the
            // normalized order is persisted here directly.
            let normalized = MonitorProvider.normalizedOrder(providerOrder)
            if providerOrder != normalized {
                providerOrder = normalized
            }
            defaults.set(normalized.map(\.rawValue), forKey: Keys.providerOrder)
        }
    }

    @Published var enabledProviderIDs: Set<MonitorProvider> {
        didSet {
            guard enabledProviderIDs != oldValue else { return }
            if enabledProviderIDs.isEmpty || !enabledProviderIDs.isSubset(of: Set(MonitorProvider.usageProviders)) {
                enabledProviderIDs = oldValue
                return
            }
            defaults.set(enabledProviderIDs.map(\.rawValue).sorted(), forKey: Keys.enabledProviders)
            // A disabled tab cannot stay selected; fall back to Overview.
            if selectedProvider != .overview, !enabledProviderIDs.contains(selectedProvider) {
                selectedProvider = .overview
            }
        }
    }

    @Published var selectedProvider: MonitorProvider {
        didSet {
            guard selectedProvider != oldValue else { return }
            defaults.set(selectedProvider.rawValue, forKey: Keys.selectedProvider)
        }
    }

    /// On when the login item is registered, including while macOS still waits
    /// for the user to approve it (see `launchAtLoginNeedsApproval`).
    @Published var launchAtLogin: Bool {
        didSet {
            guard !isRevertingLaunchAtLogin, launchAtLogin != oldValue else { return }
            updateLaunchAtLogin()
        }
    }

    /// True while the login item is registered but awaiting approval in
    /// System Settings › General › Login Items.
    @Published private(set) var launchAtLoginNeedsApproval = false

    /// A provider only polls when the user has it enabled. The selection and
    /// menu-bar flags are visibility filters, not lifecycle switches; without
    /// this gate a disabled provider (e.g. Grokbot) still runs and can invalidate
    /// a shared session (e.g. Cursor's).
    func isProviderEnabled(_ provider: MonitorProvider) -> Bool {
        enabledProviderIDs.contains(provider)
    }

    /// Whether `provider` should be polled now (see the `needs*Polling` flags).
    func needsPolling(_ provider: MonitorProvider) -> Bool {
        switch provider {
        case .overview: return false
        case .grok: return needsGrokPolling
        case .opencode: return needsOpenCodePolling
        case .cursor: return needsCursorPolling
        case .claude: return needsClaudePolling
        case .chatgpt: return needsChatGPTPolling
        case .openrouter: return needsOpenRouterPolling
        case .grokbot: return needsGrokbotPolling
        }
    }

    /// Whether Grok should be polled (panel tab or menu-bar graph).
    var needsGrokPolling: Bool {
        isProviderEnabled(.grok) && (selectedProvider.polls(.grok) || showGrokBarInMenuBar)
    }

    /// Whether OpenCode should be polled (panel tab or menu-bar graph).
    var needsOpenCodePolling: Bool {
        isProviderEnabled(.opencode) && (selectedProvider.polls(.opencode) || showOpenCodeBarInMenuBar)
    }

    /// Whether Cursor should be polled (panel tab or menu-bar graph).
    var needsCursorPolling: Bool {
        isProviderEnabled(.cursor) && (selectedProvider.polls(.cursor) || showCursorBarInMenuBar)
    }

    /// Whether Claude should be polled (panel tab or menu-bar graph).
    var needsClaudePolling: Bool {
        isProviderEnabled(.claude) && (selectedProvider.polls(.claude) || showClaudeBarInMenuBar)
    }

    /// Whether ChatGPT/Codex should be polled (panel tab).
    var needsChatGPTPolling: Bool {
        isProviderEnabled(.chatgpt) && selectedProvider.polls(.chatgpt)
    }

    /// Whether OpenRouter should be polled (panel tab).
    var needsOpenRouterPolling: Bool {
        isProviderEnabled(.openrouter) && selectedProvider.polls(.openrouter)
    }

    /// Whether Grokbot should be polled (panel tab or menu-bar graph). Gated on
    /// Grokbot being enabled so a disabled Grokbot cannot invalidate the shared
    /// Cursor session.
    var needsGrokbotPolling: Bool {
        isProviderEnabled(.grokbot) && (selectedProvider.polls(.grokbot) || showGrokbotBarInMenuBar)
    }

    /// Guards against recursive `didSet` when registration fails and the value is reverted.
    private var isRevertingLaunchAtLogin = false

    init(defaults: UserDefaults = .standard, loginItem: LoginItemService = SMAppService.mainApp) {
        self.defaults = defaults
        self.loginItem = loginItem
        showCategoriesInMenuBar = defaults.object(forKey: Keys.showCategories) as? Bool ?? true
        showGrokBarInMenuBar = defaults.object(forKey: Keys.showGrokBar) as? Bool ?? true
        showOpenCodeBarInMenuBar = defaults.object(forKey: Keys.showOpenCodeBar) as? Bool ?? false
        showCursorBarInMenuBar = defaults.object(forKey: Keys.showCursorBar) as? Bool ?? false
        showClaudeBarInMenuBar = defaults.object(forKey: Keys.showClaudeBar) as? Bool ?? false
        showGrokbotBarInMenuBar = defaults.object(forKey: Keys.showGrokbotBar) as? Bool ?? false
        showSelectedProviderInMenuBar = defaults.object(forKey: Keys.showSelectedProvider) as? Bool ?? false
        checksForUpdates = defaults.object(forKey: Keys.checksForUpdates) as? Bool ?? true
        // Clamp on load — didSet does not run during init.
        activePollSeconds = Self.clampActivePoll(defaults.object(forKey: Keys.activePoll) as? Int ?? 60)
        idlePollSeconds = Self.clampIdlePoll(defaults.object(forKey: Keys.idlePoll) as? Int ?? 300)
        thresholdEnabled = defaults.object(forKey: Keys.thresholdEnabled) as? Bool ?? true
        thresholdPercent = Self.clampThreshold(defaults.object(forKey: Keys.thresholdPercent) as? Double ?? 80)
        selectedProvider = MonitorProvider(rawValue: defaults.string(forKey: Keys.selectedProvider) ?? "") ?? .grok
        let savedOrder = (defaults.stringArray(forKey: Keys.providerOrder) ?? [])
            .compactMap(MonitorProvider.init(rawValue:))
        providerOrder = MonitorProvider.normalizedOrder(savedOrder)
        if let saved = defaults.stringArray(forKey: Keys.enabledProviders) {
            let parsed = Set(saved.compactMap(MonitorProvider.init(rawValue:)))
                .intersection(Set(MonitorProvider.usageProviders))
            enabledProviderIDs = parsed.isEmpty ? Set(MonitorProvider.usageProviders) : parsed
        } else {
            enabledProviderIDs = Set(MonitorProvider.usageProviders)
        }
        if let saved = defaults.stringArray(forKey: Keys.visibleProducts) {
            let parsed = Set(saved.map { $0.lowercased() })
            let known = Set(ProductCatalog.knownIDs)
            if parsed.isEmpty {
                // The user explicitly deselected every product — keep it empty.
                visibleProductIDs = []
            } else {
                // Drop retired/renamed ids; if nothing survives, fall back to all
                // known products rather than hiding the breakdown.
                let sanitized = parsed.intersection(known)
                visibleProductIDs = sanitized.isEmpty ? known : sanitized
            }
        } else {
            visibleProductIDs = Set(ProductCatalog.knownIDs)
        }
        launchAtLogin = Self.isRegistered(loginItem.status)
        launchAtLoginNeedsApproval = loginItem.status == .requiresApproval
    }

    private static func isRegistered(_ status: SMAppService.Status) -> Bool {
        status == .enabled || status == .requiresApproval
    }

    /// Re-reads the login item, e.g. after the user approved it in System Settings.
    func refreshLaunchAtLoginStatus() {
        let status = loginItem.status
        launchAtLoginNeedsApproval = status == .requiresApproval
        let registered = Self.isRegistered(status)
        guard launchAtLogin != registered else { return }
        isRevertingLaunchAtLogin = true
        launchAtLogin = registered
        isRevertingLaunchAtLogin = false
    }

    /// Allowed values, shared by the model clamps and the Settings controls.
    static let activePollRange = 15...300
    static let idlePollRange = 60...3600
    static let thresholdRange: ClosedRange<Double> = 50...99

    private static func clampActivePoll(_ value: Int) -> Int {
        min(activePollRange.upperBound, max(activePollRange.lowerBound, value))
    }

    private static func clampIdlePoll(_ value: Int) -> Int {
        min(idlePollRange.upperBound, max(idlePollRange.lowerBound, value))
    }

    private static func clampThreshold(_ value: Double) -> Double {
        min(thresholdRange.upperBound, max(thresholdRange.lowerBound, value))
    }

    private func updateLaunchAtLogin() {
        do {
            if launchAtLogin {
                try loginItem.register()
            } else {
                try loginItem.unregister()
            }
        } catch {
            // Registration can fail (e.g. unsigned debug builds); the status
            // re-read below reverts the toggle to what macOS reports.
        }
        refreshLaunchAtLoginStatus()
    }

    private enum Keys {
        static let showCategories = "showCategoriesInMenuBar"
        static let showGrokBar = "showGrokBarInMenuBar"
        static let showOpenCodeBar = "showOpenCodeBarInMenuBar"
        static let showCursorBar = "showCursorBarInMenuBar"
        static let showClaudeBar = "showClaudeBarInMenuBar"
        static let showGrokbotBar = "showGrokbotBarInMenuBar"
        static let showSelectedProvider = "showSelectedProviderInMenuBar"
        static let checksForUpdates = "checksForUpdates"
        static let activePoll = "activePollSeconds"
        static let idlePoll = "idlePollSeconds"
        static let thresholdEnabled = "thresholdEnabled"
        static let thresholdPercent = "thresholdPercent"
        static let selectedProvider = "selectedProvider"
        static let enabledProviders = "enabledProviderIDs"
        static let providerOrder = "providerOrder"
        static let visibleProducts = "visibleProductIDs"
    }

    /// Live drag: move `moving` to the slot currently occupied by `target`.
    func moveProvider(_ moving: MonitorProvider, to target: MonitorProvider) {
        var order = orderedUsageProviders
        guard moving != target,
              let from = order.firstIndex(of: moving),
              let to = order.firstIndex(of: target)
        else { return }
        order.move(fromOffsets: IndexSet(integer: from), toOffset: from < to ? to + 1 : to)
        providerOrder = order
    }
}
