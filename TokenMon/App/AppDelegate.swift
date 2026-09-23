import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let dockHideGracePeriod: TimeInterval = 0.25

    /// Bumped on every reveal so a deferred hide scheduled by an earlier close
    /// is discarded when a window reopens within the grace period.
    @MainActor private static var revealGeneration = 0

    func applicationDidFinishLaunching(_ notification: Notification) {}

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @MainActor
    static func revealWindow() {
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
