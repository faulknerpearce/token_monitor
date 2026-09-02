import Foundation
import ServiceManagement
import SwiftUI

@MainActor
final class AppSettings: ObservableObject {
    private let defaults: UserDefaults

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
    /// the menu when one exists. Notify-only — nothing is downloaded.
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
        didSet { defaults.set(thresholdPercent, forKey: Keys.thresholdPercent) }
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
            let normalized = MonitorProvider.normalizedOrder(providerOrder)
            if providerOrder != normalized {
                providerOrder = normalized
                return
            }
            defaults.set(providerOrder.map(\.rawValue), forKey: Keys.providerOrder)
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
        }
    }

    @Published var selectedProvider: MonitorProvider {
        didSet {
            guard selectedProvider != oldValue else { return }
            defaults.set(selectedProvider.rawValue, forKey: Keys.selectedProvider)
        }
    }

    @Published var launchAtLogin: Bool {
        didSet {
            guard !isRevertingLaunchAtLogin, launchAtLogin != oldValue else { return }
            updateLaunchAtLogin()
        }
    }

    /// Whether Grok should be polled (panel tab or menu-bar graph).
    var needsGrokPolling: Bool {
        selectedProvider.pollsGrok || showGrokBarInMenuBar
    }

    /// Whether OpenCode should be polled (panel tab or menu-bar graph).
    var needsOpenCodePolling: Bool {
        selectedProvider.pollsOpenCode || showOpenCodeBarInMenuBar
    }

    /// Whether Cursor should be polled (panel tab or menu-bar graph).
    var needsCursorPolling: Bool {
        selectedProvider.pollsCursor || showCursorBarInMenuBar
    }

    /// Whether Claude should be polled (panel tab or menu-bar graph).
    var needsClaudePolling: Bool {
        selectedProvider.pollsClaude || showClaudeBarInMenuBar
    }

    /// Whether ChatGPT/Codex should be polled (panel tab).
    var needsChatGPTPolling: Bool {
        selectedProvider.pollsChatGPT
    }

    /// Whether OpenRouter should be polled (panel tab).
    var needsOpenRouterPolling: Bool {
        selectedProvider.pollsOpenRouter
    }

    /// Whether Grokbot should be polled (panel tab or menu-bar graph).
    var needsGrokbotPolling: Bool {
        selectedProvider.pollsGrokbot || showGrokbotBarInMenuBar
    }

    /// Guards against recursive `didSet` when registration fails and we revert.
    private var isRevertingLaunchAtLogin = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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
        thresholdPercent = defaults.object(forKey: Keys.thresholdPercent) as? Double ?? 80
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
            visibleProductIDs = Set(saved.map { $0.lowercased() })
        } else {
            visibleProductIDs = Set(ProductCatalog.knownIDs)
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private static func clampActivePoll(_ value: Int) -> Int { max(15, min(300, value)) }
    private static func clampIdlePoll(_ value: Int) -> Int { max(15, min(3600, value)) }

    private func updateLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Revert UI if registration fails (e.g. unsigned debug builds).
            let actual = SMAppService.mainApp.status == .enabled
            guard launchAtLogin != actual else { return }
            isRevertingLaunchAtLogin = true
            launchAtLogin = actual
            isRevertingLaunchAtLogin = false
        }
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

    /// Drag-reorder of the currently visible (enabled) providers.
    func moveVisibleProviders(from source: IndexSet, to destination: Int) {
        providerOrder = MonitorProvider.movingVisible(
            order: providerOrder,
            visible: visibleUsageProviders,
            from: source,
            to: destination
        )
    }

    /// Drag-reorder of the full usage-provider list (Preferences).
    func moveOrderedProviders(from source: IndexSet, to destination: Int) {
        var order = orderedUsageProviders
        order.move(fromOffsets: source, toOffset: destination)
        providerOrder = order
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
