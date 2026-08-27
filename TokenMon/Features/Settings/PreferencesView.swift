import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PreferencesView: View {
    @ObservedObject var auth: AuthSessionService
    @ObservedObject var openCodeAuth: OpenCodeAuthSession
    @ObservedObject var cursorAuth: CursorAuthSession
    @ObservedObject var claudeAuth: ClaudeAuthSession
    @ObservedObject var chatGPTAuth: ChatGPTAuthSession
    @ObservedObject var openRouterAuth: OpenRouterAuthSession
    @ObservedObject var settings: AppSettings
    @ObservedObject var history: HistoryStore
    @ObservedObject var poller: UsagePoller
    @ObservedObject var openCodePoller: OpenCodeUsagePoller
    @ObservedObject var cursorPoller: CursorUsagePoller
    @ObservedObject var claudePoller: ClaudeUsagePoller
    @ObservedObject var chatGPTPoller: ChatGPTUsagePoller
    @ObservedObject var openRouterPoller: OpenRouterUsagePoller
    @ObservedObject var grokbotPoller: GrokbotUsagePoller
    let openSignIn: () -> Void
    let openOpenCodeSignIn: () -> Void
    let openCursorSignIn: () -> Void
    let openClaudeSignIn: () -> Void
    let openChatGPTSignIn: () -> Void
    @State private var exportError: String?
    @State private var openRouterKeyDraft = ""
    @State private var draggingProvider: MonitorProvider?

    var body: some View {
        List {
            Section {
                ForEach(settings.orderedUsageProviders) { provider in
                    HStack(spacing: 8) {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 18, height: 22)
                            .contentShape(Rectangle())
                            .onDrag {
                                draggingProvider = provider
                                return NSItemProvider(object: NSString(string: provider.rawValue))
                            }
                        Image(nsImage: ProviderLogo.image(for: provider))
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .frame(width: 14, height: 14)
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
                .onMove(perform: settings.moveOrderedProviders)
            } header: {
                Text("Providers")
            } footer: {
                Text("Toggle which tabs appear in the menu dropdown. Drag a row (or its handle) to set tab, Overview, and menu-bar graph order.")
            }

            Section {
                Toggle("Show selected provider", isOn: $settings.showSelectedProviderInMenuBar)
                Toggle("Grok categories", isOn: $settings.showCategoriesInMenuBar)
                Toggle("Grok bar graph", isOn: $settings.showGrokBarInMenuBar)
                Toggle("OpenCode bar graph", isOn: $settings.showOpenCodeBarInMenuBar)
                Toggle("Cursor bar graph", isOn: $settings.showCursorBarInMenuBar)
                Toggle("Claude bar graph", isOn: $settings.showClaudeBarInMenuBar)
                Toggle("Grokbot bar graph", isOn: $settings.showGrokbotBarInMenuBar)
            } header: {
                Text("Menu Bar")
            } footer: {
                Text("Show selected provider replaces the pinned graphs with just the active provider's icon, percentage, and usage bar.")
            }

            Section("Grok Account") {
                if auth.isSignedIn {
                    LabeledContent("Signed in as") {
                        Text(auth.accountEmail ?? "Grok account")
                    }
                    Button("Sign Out", role: .destructive) {
                        auth.signOut()
                        poller.clearSnapshot()
                    }
                    Button("Re-authenticate…") { openSignIn() }
                } else {
                    Text("Not signed in")
                        .foregroundStyle(.secondary)
                    Button("Sign In to grok.com…") { openSignIn() }
                }
                if let err = auth.lastAuthError {
                    Text(err).foregroundStyle(.red).font(.caption)
                }
            }

            Section("OpenCode Account") {
                if openCodeAuth.isSignedIn {
                    LabeledContent("Signed in as") {
                        Text(openCodeAuth.accountEmail ?? "OpenCode account")
                    }
                    Button("Sign Out", role: .destructive) {
                        openCodeAuth.signOut()
                        openCodePoller.clearSnapshot()
                    }
                    Button("Re-authenticate…") { openOpenCodeSignIn() }
                } else {
                    Text("Not signed in")
                        .foregroundStyle(.secondary)
                    Button("Sign In to OpenCode…") { openOpenCodeSignIn() }
                }
                if let err = openCodeAuth.lastAuthError {
                    Text(err).foregroundStyle(.red).font(.caption)
                }
            }

            Section("Cursor Account") {
                if cursorAuth.isSignedIn {
                    LabeledContent("Signed in as") {
                        Text(cursorAuth.accountEmail ?? "Cursor account")
                    }
                    Button("Sign Out", role: .destructive) {
                        cursorAuth.signOut()
                        cursorPoller.clearSnapshot()
                    }
                    Button("Re-authenticate…") { openCursorSignIn() }
                } else {
                    Text("Not signed in")
                        .foregroundStyle(.secondary)
                    Button("Sign In to Cursor…") { openCursorSignIn() }
                }
                if let err = cursorAuth.lastAuthError {
                    Text(err).foregroundStyle(.red).font(.caption)
                }
            }

            Section("Claude Account") {
                if claudeAuth.isSignedIn {
                    LabeledContent("Signed in as") {
                        Text(claudeAuth.accountEmail ?? "Claude account")
                    }
                    Button("Sign Out", role: .destructive) {
                        claudeAuth.signOut()
                        claudePoller.clearSnapshot()
                    }
                    Button("Re-authenticate…") { openClaudeSignIn() }
                } else {
                    Text("Not signed in")
                        .foregroundStyle(.secondary)
                    Button("Sign In to Claude…") { openClaudeSignIn() }
                }
                if let err = claudeAuth.lastAuthError {
                    Text(err).foregroundStyle(.red).font(.caption)
                }
            }

            Section("ChatGPT Account") {
                if chatGPTAuth.isSignedIn {
                    LabeledContent("Signed in as") {
                        Text(chatGPTAuth.accountEmail ?? "ChatGPT account")
                    }
                    Button("Sign Out", role: .destructive) {
                        chatGPTAuth.signOut()
                        chatGPTPoller.clearSnapshot()
                    }
                    Button("Re-authenticate…") { openChatGPTSignIn() }
                } else {
                    Text("Not signed in")
                        .foregroundStyle(.secondary)
                    Button("Sign In to ChatGPT…") { openChatGPTSignIn() }
                }
                if let err = chatGPTAuth.lastAuthError {
                    Text(err).foregroundStyle(.red).font(.caption)
                }
            }

            Section("OpenRouter Account") {
                if openRouterAuth.isSignedIn {
                    LabeledContent("Connected with") {
                        Text("OpenRouter API key")
                    }
                    Button("Sign Out", role: .destructive) {
                        openRouterAuth.signOut()
                        openRouterPoller.clearSnapshot()
                        openRouterKeyDraft = ""
                    }
                } else {
                    Text("Not connected")
                        .foregroundStyle(.secondary)
                    SecureField("sk-or-v1-…", text: $openRouterKeyDraft)
                    Button("Save API Key") { saveOpenRouterKey() }
                        .disabled(openRouterKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if let err = openRouterAuth.lastAuthError {
                        Text(err).foregroundStyle(.red).font(.caption)
                    }
                }
            }

            Section("Refresh") {
                Stepper(value: $settings.activePollSeconds, in: 15...300, step: 15) {
                    Text("While menu open: \(settings.activePollSeconds)s")
                }
                Stepper(value: $settings.idlePollSeconds, in: 60...3600, step: 60) {
                    Text("While idle: \(settings.idlePollSeconds)s")
                }
                refreshStatus
            }

            Section("Alerts") {
                Toggle("Notify when usage exceeds threshold", isOn: $settings.thresholdEnabled)
                if settings.thresholdEnabled {
                    Slider(value: $settings.thresholdPercent, in: 50...99, step: 1) {
                        Text("Threshold")
                    } minimumValueLabel: {
                        Text("50%")
                    } maximumValueLabel: {
                        Text("99%")
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
                }
            }

            Section("System") {
                Toggle("Launch at Login", isOn: $settings.launchAtLogin)
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
            }

            if let exportError {
                Section {
                    Text(exportError).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 440, minHeight: 520)
        .onDisappear {
            AppDelegate.hideDockIfNoWindows()
        }
    }

    @ViewBuilder
    private var refreshStatus: some View {
        switch settings.selectedProvider {
        case .opencode:
            if let last = openCodePoller.lastRefreshedAt {
                Text("Last refresh: \(last.formatted(date: .abbreviated, time: .shortened))")
                    .foregroundStyle(.secondary)
            }
            if let error = openCodePoller.lastError {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        case .cursor:
            if let last = cursorPoller.lastRefreshedAt {
                Text("Last refresh: \(last.formatted(date: .abbreviated, time: .shortened))")
                    .foregroundStyle(.secondary)
            }
            if let error = cursorPoller.lastError {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        case .claude:
            if let last = claudePoller.lastRefreshedAt {
                Text("Last refresh: \(last.formatted(date: .abbreviated, time: .shortened))")
                    .foregroundStyle(.secondary)
            }
            if let error = claudePoller.lastError {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        case .chatgpt:
            if let last = chatGPTPoller.lastRefreshedAt {
                Text("Last refresh: \(last.formatted(date: .abbreviated, time: .shortened))")
                    .foregroundStyle(.secondary)
            }
            if let error = chatGPTPoller.lastError {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        case .openrouter:
            if let last = openRouterPoller.lastRefreshedAt {
                Text("Last refresh: \(last.formatted(date: .abbreviated, time: .shortened))")
                    .foregroundStyle(.secondary)
            }
            if let error = openRouterPoller.lastError {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        case .grokbot:
            if let last = grokbotPoller.lastRefreshedAt {
                Text("Last refresh: \(last.formatted(date: .abbreviated, time: .shortened))")
                    .foregroundStyle(.secondary)
            }
            if let error = grokbotPoller.lastError {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        case .overview:
            if let last = openCodePoller.lastRefreshedAt {
                Text("OpenCode: \(last.formatted(date: .abbreviated, time: .shortened))")
                    .foregroundStyle(.secondary)
            }
            if let last = cursorPoller.lastRefreshedAt {
                Text("Cursor: \(last.formatted(date: .abbreviated, time: .shortened))")
                    .foregroundStyle(.secondary)
            }
            if let last = claudePoller.lastRefreshedAt {
                Text("Claude: \(last.formatted(date: .abbreviated, time: .shortened))")
                    .foregroundStyle(.secondary)
            }
            if let last = chatGPTPoller.lastRefreshedAt {
                Text("ChatGPT: \(last.formatted(date: .abbreviated, time: .shortened))")
                    .foregroundStyle(.secondary)
            }
            if let last = openRouterPoller.lastRefreshedAt {
                Text("OpenRouter: \(last.formatted(date: .abbreviated, time: .shortened))")
                    .foregroundStyle(.secondary)
            }
            if let last = grokbotPoller.lastRefreshedAt {
                Text("Grokbot: \(last.formatted(date: .abbreviated, time: .shortened))")
                    .foregroundStyle(.secondary)
            }
            if let last = poller.lastRefreshedAt {
                Text("Grok: \(last.formatted(date: .abbreviated, time: .shortened))")
                    .foregroundStyle(.secondary)
            }
        case .grok:
            if let last = poller.lastRefreshedAt {
                Text("Last refresh: \(last.formatted(date: .abbreviated, time: .shortened))")
                    .foregroundStyle(.secondary)
            }
            if let error = poller.lastError {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        }
    }

    private func saveOpenRouterKey() {
        if openRouterAuth.saveAPIKey(openRouterKeyDraft) {
            openRouterKeyDraft = ""
            Task { await openRouterPoller.refreshNow() }
        }
    }

    private func export(_ format: ExportService.Format) {
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
