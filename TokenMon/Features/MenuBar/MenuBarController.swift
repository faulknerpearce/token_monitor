import AppKit
import Combine
import SwiftUI

/// Owns the menu bar status item and its dropdown panel.
///
/// Replaces `MenuBarExtra` (so a click can be hit-tested against the rendered
/// provider segments) and `NSPopover` (which always draws an arrow). The
/// dropdown is a borderless `MenuBarPanel` positioned under the status item, so
/// there is no arrow and the top edge stays put while the bottom grows with the
/// provider content.
@MainActor
final class MenuBarController: NSObject, ObservableObject {
    private let model: AppModel
    private let statusItem: NSStatusItem
    private let panel = MenuBarPanel()
    private var hosting: NSHostingController<MenuBarRoot>?
    private var cancellables = Set<AnyCancellable>()
    private var regions: [MenuBarStatusRenderer.Region] = []
    private var escapeMonitor: Any?
    private var observers: [NSObjectProtocol] = []

    /// Gap between the status item and the top of the panel.
    private let panelGap: CGFloat = 4

    init(model: AppModel) {
        self.model = model
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            button.target = self
            button.action = #selector(handleStatusItemClick(_:))
            button.sendAction(on: [.leftMouseUp])
        }

        // Dismiss when focus leaves the panel or the app.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hidePanel() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hidePanel() }
        })

        // Local monitors run on the main thread, so the MainActor state is safe.
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard event.keyCode == 53 else { return event } // Escape
            return MainActor.assumeIsolated {
                guard self?.panel.isVisible == true else { return event }
                self?.hidePanel()
                return nil
            }
        }

        model.objectWillChange
            .sink { [weak self] _ in
                self?.refreshStatusItem()
                // Content height can change (e.g. switching provider tabs);
                // let SwiftUI lay out, then re-fit the panel's bottom edge.
                DispatchQueue.main.async { self?.resizePanelIfNeeded() }
            }
            .store(in: &cancellables)

        refreshStatusItem()
    }

    private func refreshStatusItem() {
        let settings = model.settings
        let rendered = MenuBarStatusRenderer.render(
            selectedProvider: settings.selectedProvider,
            showSelectedProvider: settings.showSelectedProviderInMenuBar,
            snapshot: model.poller.snapshot,
            openCodeSnapshot: model.openCodePoller.snapshot,
            cursorSnapshot: model.cursorPoller.snapshot,
            claudeSnapshot: model.claudePoller.snapshot,
            chatGPTSnapshot: model.chatGPTPoller.snapshot,
            openRouterSnapshot: model.openRouterPoller.snapshot,
            grokbotSnapshot: model.grokbotPoller.snapshot,
            isGrokSignedIn: model.auth.isSignedIn && !model.auth.needsSignIn,
            showGrokBar: settings.showGrokBarInMenuBar,
            showGrokCategories: settings.showCategoriesInMenuBar,
            showOpenCodeBar: settings.showOpenCodeBarInMenuBar,
            showCursorBar: settings.showCursorBarInMenuBar,
            showClaudeBar: settings.showClaudeBarInMenuBar,
            showGrokbotBar: settings.showGrokbotBarInMenuBar,
            providerOrder: settings.orderedUsageProviders,
            visibleProductIDs: settings.visibleProductIDs
        )
        regions = rendered.regions
        // Keep `variableLength`: assigning an explicit length animates the status
        // item, which makes the whole menu bar shift when the label updates.
        statusItem.button?.image = rendered.image
    }

    @objc private func handleStatusItemClick(_ sender: Any?) {
        if panel.isVisible {
            hidePanel()
            return
        }
        guard let button = statusItem.button else { return }

        // Open on the provider whose bar was clicked; a miss keeps the selection.
        if let provider = clickedProvider(in: button) {
            model.settings.selectedProvider = provider
        }
        showPanel()
    }

    // MARK: - Panel

    private func showPanel() {
        let hosting = NSHostingController(rootView: MenuBarRoot(model: model))
        hosting.sizingOptions = [.preferredContentSize]
        self.hosting = hosting
        panel.contentViewController = hosting

        panel.setFrame(panelFrame(for: panelContentSize()), display: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func hidePanel() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        // Detaching fires the panel content's `onDisappear` (menuIsOpen resets).
        panel.contentViewController = nil
        hosting = nil
    }

    /// Fits the panel to the SwiftUI content, anchoring the top edge so only the
    /// bottom grows or shrinks.
    private func resizePanelIfNeeded() {
        guard panel.isVisible, hosting != nil else { return }
        let size = panelContentSize()
        guard size.height > 0, abs(size.height - panel.frame.height) > 0.5 else { return }
        panel.setFrame(panelFrame(for: size, topEdge: panel.frame.maxY), display: true)
    }

    private func panelContentSize() -> NSSize {
        guard let hosting else { return NSSize(width: 420, height: 480) }
        hosting.view.layoutSubtreeIfNeeded()
        let preferred = hosting.preferredContentSize
        let fitting = hosting.view.fittingSize
        let width = max(320, preferred.width > 0 ? preferred.width : fitting.width)
        let height = max(200, preferred.height > 0 ? preferred.height : fitting.height)
        return NSSize(width: width, height: height)
    }

    /// Frame for `size`, centered under the status item when `topEdge` is nil,
    /// otherwise keeping `topEdge`, clamped to the screen.
    private func panelFrame(for size: NSSize, topEdge: CGFloat? = nil) -> NSRect {
        guard let button = statusItem.button, let buttonWindow = button.window else {
            return NSRect(origin: panel.frame.origin, size: size)
        }
        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let height = min(size.height, visible.height - 16)
        let top = topEdge ?? (buttonFrame.minY - panelGap)
        var x = buttonFrame.midX - size.width / 2
        var y = top - height
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        y = min(max(y, visible.minY + 8), visible.maxY - height - 8)
        return NSRect(x: x, y: y, width: size.width, height: height)
    }

    /// Maps the click's x onto the status-image coordinate space and resolves the
    /// provider segment under it.
    private func clickedProvider(in button: NSStatusBarButton) -> MonitorProvider? {
        guard let event = NSApp.currentEvent else { return nil }
        let pointInButton = button.convert(event.locationInWindow, from: nil)
        // The button is sized to the bitmap, but center the image defensively in
        // case AppKit insets it.
        let imageWidth = button.image?.size.width ?? button.bounds.width
        let imageOriginX = (button.bounds.width - imageWidth) / 2
        let xInImage = pointInButton.x - imageOriginX
        return MenuBarStatusRenderer.provider(atX: xInImage, in: regions)
    }
}
