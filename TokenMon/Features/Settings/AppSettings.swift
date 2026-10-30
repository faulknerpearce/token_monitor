import Foundation
import Observation
import ServiceManagement
import SwiftUI

/// The login-item registration `AppSettings` drives (`SMAppService.mainApp`
/// in the app; tests inject a fake in place of the real login item).
@MainActor
protocol LoginItemService: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LoginItemService {}

/// A dropdown panel section the user can open and close.
///
/// - Note: Raw values are saved in `UserDefaults`; do not rename them.
enum PanelSection: String, Codable, CaseIterable, Hashable, Sendable {
    case claudeModels
    case openCodeModels
}

/// Persisted user settings published to pollers and menu-bar surfaces.
@MainActor
@Observable
final class AppSettings {
    private let defaults: UserDefaults
    private let loginItem: LoginItemService

    var showCategoriesInMenuBar: Bool {
        didSet {
            guard showCategoriesInMenuBar != oldValue else { return }
            defaults.set(showCategoriesInMenuBar, forKey: Keys.showCategories)
        }
    }

    /// Providers whose usage graph shows in the menu bar (see
    /// `MonitorProvider.supportsMenuBarGraph`). Grok's segment shows whenever
    /// Grok is enabled; this set adds its bar.
    var menuBarGraphProviders: Set<MonitorProvider> {
        didSet {
            guard menuBarGraphProviders != oldValue else { return }
            defaults.set(menuBarGraphProviders.map(\.rawValue).sorted(), forKey: Keys.menuBarGraphs)
        }
    }

    /// Whether `provider`'s graph shows in the menu bar.
    func showsMenuBarGraph(_ provider: MonitorProvider) -> Bool {
        menuBarGraphProviders.contains(provider)
    }

    /// Shows or hides `provider`'s menu-bar graph.
    func setMenuBarGraph(_ provider: MonitorProvider, shown: Bool) {
        if shown {
            menuBarGraphProviders.insert(provider)
        } else {
            menuBarGraphProviders.remove(provider)
        }
    }

    /// When on, TokenMon checks GitHub for a newer release and shows a row in
    /// the menu when one exists. Installing it is a separate, user-initiated
    /// action (`UpdateChecker.installAvailableUpdate`).
    var checksForUpdates: Bool {
        didSet {
            guard checksForUpdates != oldValue else { return }
            defaults.set(checksForUpdates, forKey: Keys.checksForUpdates)
        }
    }

    /// When on, the menu bar shows only the selected provider (icon + % + bar);
    /// when off, it shows the pinned graph composite.
    var showSelectedProviderInMenuBar: Bool {
        didSet {
            guard showSelectedProviderInMenuBar != oldValue else { return }
            defaults.set(showSelectedProviderInMenuBar, forKey: Keys.showSelectedProvider)
        }
    }

    var activePollSeconds: Int {
        didSet {
            let clamped = Self.clampActivePoll(activePollSeconds)
            if activePollSeconds != clamped { activePollSeconds = clamped }
            defaults.set(activePollSeconds, forKey: Keys.activePoll)
        }
    }

    var idlePollSeconds: Int {
        didSet {
            let clamped = Self.clampIdlePoll(idlePollSeconds)
            if idlePollSeconds != clamped { idlePollSeconds = clamped }
            defaults.set(idlePollSeconds, forKey: Keys.idlePoll)
        }
    }

    var thresholdEnabled: Bool {
        didSet { defaults.set(thresholdEnabled, forKey: Keys.thresholdEnabled) }
    }

    /// Providers the usage alert watches while it is on. Only these keep
    /// polling for the alert when they are not otherwise needed.
    var alertProviders: Set<MonitorProvider> {
        didSet {
            guard alertProviders != oldValue else { return }
            defaults.set(alertProviders.map(\.rawValue).sorted(), forKey: Keys.alertProviders)
        }
    }

    /// Whether the usage alert is on for `provider`.
    func alertWatches(_ provider: MonitorProvider) -> Bool {
        thresholdEnabled && alertProviders.contains(provider)
    }

    var thresholdPercent: Double {
        didSet {
            let clamped = Self.clampThreshold(thresholdPercent)
            if thresholdPercent != clamped { thresholdPercent = clamped }
            defaults.set(thresholdPercent, forKey: Keys.thresholdPercent)
        }
    }

    var visibleProductIDs: Set<String> {
        didSet {
            defaults.set(Array(visibleProductIDs), forKey: Keys.visibleProducts)
        }
    }

    /// Panel sections the user has closed; every other section is open.
    var collapsedPanelSections: Set<PanelSection> {
        didSet {
            guard collapsedPanelSections != oldValue else { return }
            defaults.set(collapsedPanelSections.map(\.rawValue).sorted(), forKey: Keys.collapsedPanelSections)
        }
    }

    /// Whether `section` is open.
    func isExpanded(_ section: PanelSection) -> Bool {
        !collapsedPanelSections.contains(section)
    }

    /// Opens or closes `section` and saves the choice.
    func setExpanded(_ expanded: Bool, for section: PanelSection) {
        if expanded {
            collapsedPanelSections.remove(section)
        } else {
            collapsedPanelSections.insert(section)
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
    var providerOrder: [MonitorProvider] {
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

    var enabledProviderIDs: Set<MonitorProvider> {
        didSet {
            guard enabledProviderIDs != oldValue else { return }
            if enabledProviderIDs.isEmpty || !enabledProviderIDs.isSubset(of: Set(MonitorProvider.usageProviders)) {
                enabledProviderIDs = oldValue
                return
            }
            defaults.set(enabledProviderIDs.map(\.rawValue).sorted(), forKey: Keys.enabledProviders)
            // Selecting a disabled tab falls back to Overview.
            if selectedProvider != .overview, !enabledProviderIDs.contains(selectedProvider) {
                selectedProvider = .overview
            }
        }
    }

    var selectedProvider: MonitorProvider {
        didSet {
            guard selectedProvider != oldValue else { return }
            defaults.set(selectedProvider.rawValue, forKey: Keys.selectedProvider)
        }
    }

    /// On when the login item is registered, including while macOS still waits
    /// for the user to approve it (see `launchAtLoginNeedsApproval`).
    var launchAtLogin: Bool {
        didSet {
            guard !isRevertingLaunchAtLogin, launchAtLogin != oldValue else { return }
            updateLaunchAtLogin()
        }
    }

    /// True while the login item is registered but awaiting approval in
    /// System Settings › General › Login Items.
    private(set) var launchAtLoginNeedsApproval = false

    /// A provider polls only when the user has it enabled. The selection and
    /// menu-bar flags filter visibility; this gate stops a disabled provider
    /// (e.g. Grokbot) from running and invalidating a shared session (e.g. Cursor's).
    func isProviderEnabled(_ provider: MonitorProvider) -> Bool {
        enabledProviderIDs.contains(provider)
    }

    /// Whether `provider` needs polling now: it is enabled and its panel tab
    /// (or Overview) is selected, its menu-bar graph is on, or the usage alert
    /// watches it (the alert is evaluated on each poll).
    func needsPolling(_ provider: MonitorProvider) -> Bool {
        guard provider != .overview, isProviderEnabled(provider) else { return false }
        return selectedProvider.polls(provider) || showsMenuBarGraph(provider) || alertWatches(provider)
    }

    /// Guards against recursive `didSet` when registration fails and the value is reverted.
    private var isRevertingLaunchAtLogin = false

    init(defaults: UserDefaults = .standard, loginItem: LoginItemService = SMAppService.mainApp) {
        self.defaults = defaults
        self.loginItem = loginItem
        showCategoriesInMenuBar = defaults.object(forKey: Keys.showCategories) as? Bool ?? true
        menuBarGraphProviders = Self.loadMenuBarGraphs(from: defaults)
        showSelectedProviderInMenuBar = defaults.object(forKey: Keys.showSelectedProvider) as? Bool ?? false
        checksForUpdates = defaults.object(forKey: Keys.checksForUpdates) as? Bool ?? true
        // Clamps on load, since `didSet` runs only after init.
        activePollSeconds = Self.clampActivePoll(defaults.object(forKey: Keys.activePoll) as? Int ?? 60)
        idlePollSeconds = Self.clampIdlePoll(defaults.object(forKey: Keys.idlePoll) as? Int ?? 300)
        thresholdEnabled = defaults.object(forKey: Keys.thresholdEnabled) as? Bool ?? false
        alertProviders = defaults.stringArray(forKey: Keys.alertProviders)
            .map { Set($0.compactMap(MonitorProvider.init(rawValue:))).intersection(MonitorProvider.usageProviders) }
            ?? Set(MonitorProvider.usageProviders)
        thresholdPercent = Self.clampThreshold(defaults.object(forKey: Keys.thresholdPercent) as? Double ?? 80)
        selectedProvider = MonitorProvider(rawValue: defaults.string(forKey: Keys.selectedProvider) ?? "") ?? .grok
        collapsedPanelSections = Set(
            (defaults.stringArray(forKey: Keys.collapsedPanelSections) ?? []).compactMap(PanelSection.init(rawValue:))
        )
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
                // Drops retired/renamed ids; if nothing survives, falls back to all
                // known products so the breakdown stays visible.
                let sanitized = parsed.intersection(known)
                visibleProductIDs = sanitized.isEmpty ? known : sanitized
            }
        } else {
            visibleProductIDs = Set(ProductCatalog.knownIDs)
        }
        launchAtLogin = Self.isRegistered(loginItem.status)
        launchAtLoginNeedsApproval = loginItem.status == .requiresApproval
    }

    /// The saved menu-bar graph set. Settings saved as one flag per provider
    /// are read once, saved as a set, and their flags removed.
    private static func loadMenuBarGraphs(from defaults: UserDefaults) -> Set<MonitorProvider> {
        let supported = Set(MonitorProvider.menuBarGraphProviders)
        if let saved = defaults.stringArray(forKey: Keys.menuBarGraphs) {
            return Set(saved.compactMap(MonitorProvider.init(rawValue:))).intersection(supported)
        }
        var graphs: Set<MonitorProvider> = []
        for (provider, key) in Keys.perProviderGraphFlags {
            let defaultOn = provider == .grok
            if defaults.object(forKey: key) as? Bool ?? defaultOn {
                graphs.insert(provider)
            }
            defaults.removeObject(forKey: key)
        }
        defaults.set(graphs.map(\.rawValue).sorted(), forKey: Keys.menuBarGraphs)
        return graphs
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
        static let menuBarGraphs = "menuBarGraphProviders"
        /// One saved flag per provider, read by `loadMenuBarGraphs` when no
        /// set is saved yet.
        static let perProviderGraphFlags: [(MonitorProvider, String)] = [
            (.grok, "showGrokBarInMenuBar"),
            (.opencode, "showOpenCodeBarInMenuBar"),
            (.cursor, "showCursorBarInMenuBar"),
            (.claude, "showClaudeBarInMenuBar"),
            (.grokbot, "showGrokbotBarInMenuBar")
        ]
        static let showSelectedProvider = "showSelectedProviderInMenuBar"
        static let checksForUpdates = "checksForUpdates"
        static let activePoll = "activePollSeconds"
        static let idlePoll = "idlePollSeconds"
        static let thresholdEnabled = "thresholdEnabled"
        static let thresholdPercent = "thresholdPercent"
        static let alertProviders = "alertProviders"
        static let selectedProvider = "selectedProvider"
        static let enabledProviders = "enabledProviderIDs"
        static let providerOrder = "providerOrder"
        static let visibleProducts = "visibleProductIDs"
        static let collapsedPanelSections = "collapsedPanelSections"
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

extension AppSettings {
    /// Seconds between polls: the active interval while the menu is open,
    /// the idle interval otherwise.
    func pollSeconds(menuIsOpen: Bool) -> TimeInterval {
        TimeInterval(menuIsOpen ? activePollSeconds : idlePollSeconds)
    }

    /// The poll interval for `provider`, or nil while it does not need
    /// polling, so its loop parks until woken.
    func pollInterval(for provider: MonitorProvider, menuIsOpen: Bool) -> TimeInterval? {
        needsPolling(provider) ? pollSeconds(menuIsOpen: menuIsOpen) : nil
    }
}
