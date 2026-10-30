import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

/// Settings window, in four tabs: General, Providers, Accounts, and Data.
///
/// Observes only the objects its own rows read (`settings`, `history`,
/// `updateChecker`); account and refresh rows are subviews that observe their
/// provider's session or poller.
struct PreferencesView: View {
    let model: AppModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var history: GrokHistoryStore
    @ObservedObject var updateChecker: UpdateChecker
    let openWindow: (AppWindow) -> Void

    var body: some View {
        TabView {
            GeneralSettingsTab(model: model, settings: settings, updateChecker: updateChecker)
                .tabItem { Label("General", systemImage: "gearshape") }
            ProvidersSettingsTab(settings: settings)
                .tabItem { Label("Providers", systemImage: "square.stack.3d.up") }
            AccountsSettingsTab(model: model, openWindow: openWindow)
                .tabItem { Label("Accounts", systemImage: "person.crop.circle") }
            DataSettingsTab(settings: settings, history: history)
                .tabItem { Label("Data", systemImage: "externaldrive") }
        }
        .font(.system(size: 14))
        .padding()
        .frame(minWidth: 460, minHeight: 520)
        .onAppear {
            settings.refreshLaunchAtLoginStatus()
        }
        .onDisappear {
            AppDelegate.hideDockIfNoWindows()
        }
    }
}

/// Startup, updates, refresh timing, alerts, and quitting.
private struct GeneralSettingsTab: View {
    let model: AppModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var updateChecker: UpdateChecker

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at Login", isOn: $settings.launchAtLogin)
                    .settingsSwitch()
                if settings.launchAtLoginNeedsApproval {
                    Text("Waiting for approval in System Settings › General › Login Items.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                }
            }

            Section {
                Toggle("Check automatically", isOn: $settings.checksForUpdates)
                    .settingsSwitch()
                LabeledContent("Version \(Self.appVersion)") {
                    Button(updateChecker.actionTitle) {
                        Task { await updateChecker.performPrimaryAction() }
                    }
                    .disabled(!updateChecker.canAct)
                }
                if let statusMessage = updateChecker.statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Updates")
            } footer: {
                Text("Checks GitHub for a newer release. Update downloads the release and replaces this copy of TokenMon.")
            }

            Section("Refresh") {
                Stepper(value: $settings.activePollSeconds, in: AppSettings.activePollRange, step: 15) {
                    LabeledContent("While menu is open", value: "\(settings.activePollSeconds)s")
                }
                Stepper(value: $settings.idlePollSeconds, in: AppSettings.idlePollRange, step: 60) {
                    LabeledContent("While idle", value: "\(settings.idlePollSeconds)s")
                }
                refreshStatus
            }

            Section("Alerts") {
                Toggle("Notify when usage exceeds threshold", isOn: $settings.thresholdEnabled)
                    .settingsSwitch()
                if settings.thresholdEnabled {
                    Slider(value: $settings.thresholdPercent, in: AppSettings.thresholdRange, step: 1) {
                        Text("Alert at \(Int(settings.thresholdPercent))%")
                    } minimumValueLabel: {
                        Text("\(Int(AppSettings.thresholdRange.lowerBound))%")
                    } maximumValueLabel: {
                        Text("\(Int(AppSettings.thresholdRange.upperBound))%")
                    }
                }
            }

            Section {
                Button("Quit TokenMon") {
                    NSApp.terminate(nil)
                }
            }
        }
        .formStyle(.grouped)
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    /// Last refresh (and error) of the selected provider, or every provider's
    /// last refresh on Overview.
    @ViewBuilder
    private var refreshStatus: some View {
        if settings.selectedProvider == .overview {
            ForEach(model.providers.all, id: \.provider) { entry in
                pollerStatus(entry.poller, label: entry.provider.displayName)
            }
        } else if let entry = model.providers.all.first(where: { $0.provider == settings.selectedProvider }) {
            pollerStatus(entry.poller, label: nil)
        }
    }

    private func pollerStatus(_ poller: some ProviderUsagePoller, label: String?) -> AnyView {
        AnyView(PollerRefreshStatus(poller: poller, label: label))
    }
}

/// Which provider tabs show and in what order, and what the menu bar draws.
private struct ProvidersSettingsTab: View {
    @ObservedObject var settings: AppSettings
    @State private var draggingProvider: MonitorProvider?

    var body: some View {
        Form {
            Section {
                ForEach(settings.orderedUsageProviders) { provider in
                    providerRow(provider)
                }
                // Reordering uses the explicit drop delegate in `providerRow`,
                // since `onMove` is effectively inert on a macOS `Form`.
            } header: {
                Text("Providers")
            } footer: {
                Text("Turn a provider on to show its tab in the menu. Drag a row to set the order of tabs, Overview cards, and menu bar graphs.")
            }

            Section {
                Toggle("Show selected provider only", isOn: $settings.showSelectedProviderInMenuBar)
                    .settingsSwitch()
                if !settings.showSelectedProviderInMenuBar {
                    ForEach(MonitorProvider.menuBarGraphProviders) { provider in
                        Toggle("\(provider.displayName) bar graph", isOn: Binding(
                            get: { settings.showsMenuBarGraph(provider) },
                            set: { settings.setMenuBarGraph(provider, shown: $0) }
                        ))
                        .settingsSwitch()
                        if provider == .grok {
                            Toggle("Grok categories", isOn: $settings.showCategoriesInMenuBar)
                                .settingsSwitch()
                        }
                    }
                }
            } header: {
                Text("Menu Bar")
            } footer: {
                Text(settings.showSelectedProviderInMenuBar
                    ? "The menu bar shows only the active provider's icon, percentage, and usage bar."
                    : "Choose which graphs stay pinned in the menu bar.")
            }
        }
        .formStyle(.grouped)
    }

    private func providerRow(_ provider: MonitorProvider) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 24)
                .contentShape(Rectangle())
                .onDrag {
                    draggingProvider = provider
                    return NSItemProvider(object: NSString(string: provider.rawValue))
                }
            Image(nsImage: ProviderLogo.image(for: provider))
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 16, height: 16)
            Toggle(provider.displayName, isOn: Binding(
                get: { settings.enabledProviderIDs.contains(provider) },
                set: { on in
                    if on {
                        settings.enabledProviderIDs.insert(provider)
                    } else {
                        settings.enabledProviderIDs.remove(provider)
                    }
                }
            ))
            .settingsSwitch()
            .disabled(settings.enabledProviderIDs == [provider])
        }
        .contentShape(Rectangle())
        .onDrop(
            of: [.utf8PlainText, .text, .plainText],
            delegate: ProviderReorderDropDelegate(
                target: provider,
                dragging: $draggingProvider,
                move: settings.moveProvider
            )
        )
    }
}

/// One row per provider account: who is signed in, and sign-in actions.
private struct AccountsSettingsTab: View {
    let model: AppModel
    let openWindow: (AppWindow) -> Void

    var body: some View {
        Form {
            Section {
                ProviderAccountRow(
                    provider: .grok,
                    auth: model.grokAuth,
                    signInTitle: "Sign In…",
                    openSignIn: { openWindow(.signIn(.grok)) }
                )
                ProviderAccountRow(
                    provider: .claude,
                    auth: model.claudeAuth,
                    signInTitle: "Sign In…",
                    openSignIn: { openWindow(.signIn(.claude)) }
                )
                ProviderAccountRow(
                    provider: .chatgpt,
                    auth: model.chatGPTAuth,
                    signInTitle: "Sign In…",
                    openSignIn: { openWindow(.signIn(.chatgpt)) }
                )
                ProviderAccountRow(
                    provider: .cursor,
                    auth: model.cursorAuth,
                    signInTitle: "Sign In…",
                    openSignIn: { openWindow(.signIn(.cursor)) }
                )
                ProviderAccountRow(
                    provider: .opencode,
                    auth: model.openCodeAuth,
                    signInTitle: "Sign In…",
                    openSignIn: { openWindow(.signIn(.opencode)) }
                )
            } header: {
                Text("Accounts")
            } footer: {
                Text("Grokbot uses your Cursor account.")
            }

            OpenRouterAccountSection(auth: model.openRouterAuth, poller: model.openRouterPoller)
        }
        .formStyle(.grouped)
    }
}

/// SuperGrok categories plus exporting and clearing local history.
private struct DataSettingsTab: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var history: GrokHistoryStore
    @State private var exportError: String?

    var body: some View {
        Form {
            Section {
                ForEach(ProductCatalog.knownIDs, id: \.self) { id in
                    Toggle(ProductCatalog.displayName(for: id), isOn: Binding(
                        get: { settings.visibleProductIDs.contains(id) },
                        set: { on in
                            if on {
                                settings.visibleProductIDs.insert(id)
                            } else {
                                settings.visibleProductIDs.remove(id)
                            }
                        }
                    ))
                    .settingsSwitch()
                }
            } header: {
                Text("SuperGrok Categories")
            } footer: {
                Text("Categories shown in the Grok breakdown.")
            }

            Section {
                LabeledContent("Export history") {
                    HStack {
                        Button("CSV…") { export(.csv) }
                        Button("JSON…") { export(.json) }
                    }
                }
                Button("Clear Local History", role: .destructive) {
                    history.clear()
                }
                if let exportError {
                    Text(exportError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if history.storeFailed {
                    Text("History storage is unavailable — usage is kept for this session only "
                        + "and will not survive a relaunch.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("SuperGrok History")
            } footer: {
                Text("Clearing history does not reset your SuperGrok weekly pool.")
            }
        }
        .formStyle(.grouped)
    }

    private func export(_ format: GrokExportService.Format) {
        // Clears any prior failure so a successful export dismisses the red
        // message.
        exportError = nil
        do {
            let data = try GrokExportService.export(history.allSnapshots(), format: format)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [format == .csv ? .commaSeparatedText : .json]
            panel.nameFieldStringValue = format == .csv ? "grok-usage.csv" : "grok-usage.json"
            if panel.runModal() == .OK, let url = panel.url {
                try data.write(to: url)
            }
        } catch {
            exportError = error.localizedDescription
        }
    }
}

/// Form rows ignore `onMove` on macOS; this delegate reorders while dragging
/// a handle over another provider row.
private struct ProviderReorderDropDelegate: DropDelegate {
    let target: MonitorProvider
    @Binding var dragging: MonitorProvider?
    let move: (MonitorProvider, MonitorProvider) -> Void

    func validateDrop(info: DropInfo) -> Bool { true }

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target else { return }
        withAnimation(.easeInOut(duration: 0.12)) {
            move(dragging, target)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

/// One cookie-session provider's account on a single row: its logo and name,
/// who is signed in, and the sign-in actions.
private struct ProviderAccountRow: View {
    let provider: MonitorProvider
    @ObservedObject var auth: ProviderAuthSession
    let signInTitle: String
    let openSignIn: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(nsImage: ProviderLogo.image(for: provider))
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 16, height: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.displayName)
                    Text(auth.isSignedIn ? (auth.accountEmail ?? "Signed in") : "Not signed in")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if auth.isSignedIn {
                    Button("Re-authenticate…") { openSignIn() }
                    Button("Sign Out", role: .destructive) {
                        auth.signOut()
                    }
                } else {
                    Button(signInTitle) { openSignIn() }
                }
            }
            if let err = auth.lastAuthError {
                Text(err).foregroundStyle(.red).font(.caption)
            }
        }
    }
}

/// OpenRouter account rows; OpenRouter connects with an API key.
private struct OpenRouterAccountSection: View {
    @ObservedObject var auth: OpenRouterAuthSession
    let poller: OpenRouterUsagePoller
    @State private var keyDraft = ""

    var body: some View {
        Section("OpenRouter") {
            if auth.isSignedIn {
                LabeledContent("Connected with") {
                    Text("OpenRouter API key")
                }
                Button("Sign Out", role: .destructive) {
                    auth.signOut()
                    keyDraft = ""
                }
            } else {
                Text("Not connected")
                    .foregroundStyle(.secondary)
                SecureField("sk-or-v1-…", text: $keyDraft)
                Button("Save API Key") { saveKey() }
                    .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if let err = auth.lastAuthError {
                    Text(err).foregroundStyle(.red).font(.caption)
                }
            }
        }
    }

    private func saveKey() {
        if auth.saveAPIKey(keyDraft) {
            keyDraft = ""
            Task { await poller.refreshNow() }
        }
    }
}

/// A poller's last refresh time and, without a `label`, its last error.
private struct PollerRefreshStatus<Poller: ProviderUsagePoller>: View {
    @ObservedObject var poller: Poller
    /// Prefixes the time with the provider name (Overview lists every provider).
    let label: String?

    var body: some View {
        if let last = poller.lastRefreshedAt {
            let time = last.formatted(date: .abbreviated, time: .shortened)
            Text(label.map { "\($0): \(time)" } ?? "Last refresh: \(time)")
                .foregroundStyle(.secondary)
        }
        if label == nil, let error = poller.lastError {
            Text(error)
                .foregroundStyle(.red)
                .font(.caption)
        }
    }
}

private extension View {
    /// A switch at the compact mini size macOS System Settings uses.
    func settingsSwitch() -> some View {
        toggleStyle(.switch).controlSize(.mini)
    }
}
