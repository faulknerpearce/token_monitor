import AppKit
import SwiftUI

/// Menu-bar app root wiring `AppModel` to settings and sign-in scenes.
@main
struct TokenMonApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    /// Process-lifetime services. Held as a plain reference: scenes observe only
    /// the individual objects they render.
    private let model: AppModel
    /// Owns the `NSStatusItem` and its dropdown panel. Self-registers in `init`;
    /// this property retains it for the app's lifetime.
    private let menuBar: MenuBarController

    init() {
        let model = AppModel()
        self.model = model
        // A click on a provider's menu bar graph opens that provider's dropdown.
        menuBar = MenuBarController(model: model)
    }

    var body: some Scene {
        // TokenMon lives in the menu bar, but SwiftUI presents the app's *first*
        // scene at launch. `AppDelegate` dismisses that auto-presented window so
        // launching shows only the menu bar item; Settings opens on request from
        // the menu bar's Settings button.
        Window("TokenMon", id: AppWindow.preferencesID) {
            PreferencesRoot(model: model)
                .onDisappear { AppDelegate.hideDockIfNoWindows() }
        }
        .defaultSize(width: 480, height: 640)

        // One sign-in browser window per provider session; opening it again
        // for the same provider brings that window forward.
        WindowGroup(id: AppWindow.signInID, for: MonitorProvider.self) { $provider in
            if let provider {
                ProviderSignInRoot(model: model, provider: provider)
                    .background(
                        Color.clear
                            .frame(width: 0, height: 0)
                            .onDisappear { AppDelegate.hideDockIfNoWindows() }
                    )
            }
        }
        .defaultSize(width: 920, height: 700)
        .windowResizability(.contentMinSize)
    }
}

/// The sign-in sheet for `provider`'s session, titled from its config.
private struct ProviderSignInRoot: View {
    let model: AppModel
    let provider: MonitorProvider

    var body: some View {
        switch provider.signInProvider {
        case .grok: sheet(model.grokAuth)
        case .opencode: sheet(model.openCodeAuth)
        case .claude: sheet(model.claudeAuth)
        case .chatgpt: sheet(model.chatGPTAuth)
        default: sheet(model.cursorAuth)
        }
    }

    private func sheet(_ auth: some ProviderSignInProviding) -> some View {
        ProviderSignInSheet(auth: auth, config: auth.signInConfig) {
            model.signInCompleted(provider.signInProvider)
        }
        .navigationTitle(auth.signInConfig.title)
    }
}

/// The app's windows: Settings and each provider's sign-in browser.
enum AppWindow: Hashable {
    case preferences
    case signIn(MonitorProvider)

    static let preferencesID = "preferences"
    static let signInID = "signin"
}

/// Bridges `AppModel` into the menu-bar dropdown content. Holds the model as
/// a plain reference so only the visible tab's objects drive re-renders.
struct MenuBarRoot: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MenuBarPanelView(
            model: model,
            settings: model.settings,
            openWindow: { model.openWindow($0, openWindow: openWindow) }
        )
        .environment(\.updateChecker, model.updateChecker)
    }
}

private struct PreferencesRoot: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        PreferencesView(
            model: model,
            settings: model.settings,
            history: model.grokHistory,
            updateChecker: model.updateChecker,
            openWindow: { model.openWindow($0, openWindow: openWindow) }
        )
    }
}
