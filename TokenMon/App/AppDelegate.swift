import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let dockHideGracePeriod: TimeInterval = 0.25

    /// Bumped on every reveal so a deferred hide scheduled by an earlier close
    /// is discarded when a window reopens within the grace period.
    @MainActor private static var revealGeneration = 0

    /// Set the first time the user opens a window themselves. Until then any
    /// window the system presents on our behalf is dismissed.
    @MainActor private static var userOpenedWindow = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // TokenMon is a menu bar app, but SwiftUI presents the app's first scene
        // at launch. Dismiss it (and re-check one runloop later, in case SwiftUI
        // presents it after this callback) so launching shows the menu bar item
        // alone — Settings opens only when the user asks for it.
        Self.dismissAutoPresentedWindows()
        DispatchQueue.main.async { Self.dismissAutoPresentedWindows() }
    }

    /// Closes normal app windows the system opened without the user asking.
    /// Status-bar and dropdown-panel windows are excluded: the status item can't
    /// become key, and the panel is a nonactivating panel.
    @MainActor
    private static func dismissAutoPresentedWindows() {
        guard !userOpenedWindow else { return }
        for window in NSApp.windows
        where window.isVisible
            && window.canBecomeKey
            && !window.styleMask.contains(.nonactivatingPanel) {
            window.close()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @MainActor
    static func revealWindow() {
        userOpenedWindow = true
        revealGeneration += 1
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    @MainActor
    static func hideDockIfNoWindows() {
        let generation = revealGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + dockHideGracePeriod) {
            MainActor.assumeIsolated {
                guard generation == revealGeneration else { return }
                let visible = NSApp.windows.contains {
                    $0.isVisible && !$0.styleMask.contains(.nonactivatingPanel) && $0.canBecomeKey
                }
                if !visible {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }
    }
}
