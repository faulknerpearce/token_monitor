import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

/// Settings window: providers, menu bar, accounts, refresh, alerts, and data.
///
/// Observes only the objects its own rows read (`settings`, `history`,
/// `updateChecker`); account and refresh rows are subviews that observe their
/// provider's session or poller.
struct PreferencesView: View {
    let model: AppModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var history: HistoryStore
    @ObservedObject var updateChecker: UpdateChecker
    let openWindow: (AppWindowID) -> Void
    @State private var exportError: String?
    @State private var draggingProvider: MonitorProvider?

    var body: some View {
        List {
            Section {
                ForEach(settings.orderedUsageProviders) { provider in
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
                        .toggleStyle(.switch)
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
                // Reordering uses the explicit drop delegate above, since `onMove`
                // is effectively inert on a macOS `List`.
            } header: {
                Text("Providers")
            } footer: {
                Text("Toggle which tabs appear in the menu dropdown. Drag a row (or its handle) to set tab, Overview, and menu-bar graph order.")
            }

            Section {
                Toggle("Show selected provider", isOn: $settings.showSelectedProviderInMenuBar)
                    .toggleStyle(.switch)
                Toggle("Grok categories", isOn: $settings.showCategoriesInMenuBar)
                    .toggleStyle(.switch)
                Toggle("Grok bar graph", isOn: $settings.showGrokBarInMenuBar)
                    .toggleStyle(.switch)
                Toggle("OpenCode bar graph", isOn: $settings.showOpenCodeBarInMenuBar)
                    .toggleStyle(.switch)
                Toggle("Cursor bar graph", isOn: $settings.showCursorBarInMenuBar)
                    .toggleStyle(.switch)
                Toggle("Claude bar graph", isOn: $settings.showClaudeBarInMenuBar)
                    .toggleStyle(.switch)
                Toggle("Grokbot bar graph", isOn: $settings.showGrokbotBarInMenuBar)
                    .toggleStyle(.switch)
            } header: {
                Text("Menu Bar")
            } footer: {
                Text("Show selected provider replaces the pinned graphs with just the active provider's icon, percentage, and usage bar.")
            }

            ProviderAccountSection(
                title: "Grok Account",
                auth: model.auth,
                accountFallback: "Grok account",
                signInTitle: "Sign In to grok.com…",
                clearSnapshot: model.poller.clearSnapshot,
                openSignIn: { openWindow(.grokSignIn) }
            )
            ProviderAccountSection(
                title: "OpenCode Account",
                auth: model.openCodeAuth,
                accountFallback: "OpenCode account",
                signInTitle: "Sign In to OpenCode…",
                clearSnapshot: model.openCodePoller.clearSnapshot,
                openSignIn: { openWindow(.openCodeSignIn) }
            )
            ProviderAccountSection(
                title: "Cursor Account",
                auth: model.cursorAuth,
                accountFallback: "Cursor account",
                signInTitle: "Sign In to Cursor…",
                clearSnapshot: model.cursorPoller.clearSnapshot,
                openSignIn: { openWindow(.cursorSignIn) }
            )
            ProviderAccountSection(
                title: "Claude Account",
                auth: model.claudeAuth,
                accountFallback: "Claude account",
                signInTitle: "Sign In to Claude…",
                clearSnapshot: model.claudePoller.clearSnapshot,
                openSignIn: { openWindow(.claudeSignIn) }
            )
            ProviderAccountSection(
                title: "ChatGPT Account",
                auth: model.chatGPTAuth,
                accountFallback: "ChatGPT account",
                signInTitle: "Sign In to ChatGPT…",
                clearSnapshot: model.chatGPTPoller.clearSnapshot,
                openSignIn: { openWindow(.chatGPTSignIn) }
            )
            OpenRouterAccountSection(auth: model.openRouterAuth, poller: model.openRouterPoller)

            Section("Refresh") {
                Stepper(value: $settings.activePollSeconds, in: AppSettings.activePollRange, step: 15) {
                    Text("While menu open: \(settings.activePollSeconds)s")
                }
                Stepper(value: $settings.idlePollSeconds, in: AppSettings.idlePollRange, step: 60) {
                    Text("While idle: \(settings.idlePollSeconds)s")
                }
                refreshStatus
            }

            Section("Alerts") {
                Toggle("Notify when usage exceeds threshold", isOn: $settings.thresholdEnabled)
                    .toggleStyle(.switch)
                if settings.thresholdEnabled {
                    Slider(value: $settings.thresholdPercent, in: AppSettings.thresholdRange, step: 1) {
                        Text("Threshold")
                    } minimumValueLabel: {
                        Text("\(Int(AppSettings.thresholdRange.lowerBound))%")
                    } maximumValueLabel: {
                        Text("\(Int(AppSettings.thresholdRange.upperBound))%")
                    }
                    Text("Alert at \(Int(settings.thresholdPercent))% used")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Categories") {
                ForEach(ProductCatalog.knownIDs, id: \.self) { id in
                    Toggle(ProductCatalog.displayName(for: id), isOn: Binding(
                        get: { settings.visibleProductIDs.contains(id) },
                        set: { on in
                            if on { settings.visibleProductIDs.insert(id) } else { settings.visibleProductIDs.remove(id) }
                        }
                    ))
                    .toggleStyle(.switch)
                }
            }

            Section("System") {
                Toggle("Launch at Login", isOn: $settings.launchAtLogin)
                    .toggleStyle(.switch)
                if settings.launchAtLoginNeedsApproval {
                    Text("Waiting for approval in System Settings › General › Login Items.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                }
                Toggle("Check for Updates", isOn: $settings.checksForUpdates)
                    .toggleStyle(.switch)
                Button(updateChecker.actionTitle) {
                    Task { await updateChecker.performPrimaryAction() }
                }
                .disabled(!updateChecker.canAct)
                if let statusMessage = updateChecker.statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Checks GitHub for a newer release. Update downloads the release "
                    + "and replaces this copy of TokenMon.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Data") {
                Button("Export CSV…") { export(.csv) }
                Button("Export JSON…") { export(.json) }
                Button("Clear Local History", role: .destructive) {
                    history.clear()
                }
                Text("Clearing history does not reset your SuperGrok weekly pool.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if history.storeFailed {
                    Text("History storage is unavailable — usage is kept for this session only "
                        + "and will not survive a relaunch.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section {
                Button("Quit TokenMon") {
                    NSApp.terminate(nil)
                }
            }

            if let exportError {
                Section {
                    Text(exportError).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .font(.system(size: 14))
        .padding()
        .frame(minWidth: 440, minHeight: 520)
        .onAppear {
            settings.refreshLaunchAtLoginStatus()
        }
        .onDisappear {
            AppDelegate.hideDockIfNoWindows()
        }
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

    private func export(_ format: ExportService.Format) {
        // Clears any prior failure so a successful export dismisses the red
        // banner.
        exportError = nil
        do {
            let data = try ExportService.export(history.allSnapshots(), format: format)
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

/// One cookie-session provider's account rows: who is signed in, sign out,
/// and (re-)authenticate.
private struct ProviderAccountSection: View {
    let title: String
    @ObservedObject var auth: ProviderAuthSession
    let accountFallback: String
    let signInTitle: String
    let clearSnapshot: () -> Void
    let openSignIn: () -> Void

    var body: some View {
        Section(title) {
            if auth.isSignedIn {
                LabeledContent("Signed in as") {
                    Text(auth.accountEmail ?? accountFallback)
                }
                Button("Sign Out", role: .destructive) {
                    auth.signOut()
                    clearSnapshot()
                }
                Button("Re-authenticate…") { openSignIn() }
            } else {
                Text("Not signed in")
                    .foregroundStyle(.secondary)
                Button(signInTitle) { openSignIn() }
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
        Section("OpenRouter Account") {
            if auth.isSignedIn {
                LabeledContent("Connected with") {
                    Text("OpenRouter API key")
                }
                Button("Sign Out", role: .destructive) {
                    auth.signOut()
                    poller.clearSnapshot()
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
