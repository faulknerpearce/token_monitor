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
    private var hosting: NSHostingController<MenuBarPanelContent>?
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
        // No `sizingOptions`: AppKit must not resize the window itself, or it
        // grows from the wrong edge and the content shifts. The panel frame is
        // set explicitly from the status item instead.
        let hosting = NSHostingController(rootView: MenuBarPanelContent(model: model))
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

    /// Fits the panel to the SwiftUI content via `panelFrame(for:)`, which clamps
    /// height to the visible screen and re-anchors under the status item so a
    /// tall provider view cannot grow past the bottom of the display.
    private func resizePanelIfNeeded() {
        guard panel.isVisible, hosting != nil else { return }
        let size = panelContentSize()
        let frame = panelFrame(for: size)
        guard abs(frame.height - panel.frame.height) > 0.5
            || abs(frame.origin.x - panel.frame.origin.x) > 0.5
            || abs(frame.origin.y - panel.frame.origin.y) > 0.5 else { return }
        panel.setFrame(frame, display: true)
    }

    private func panelContentSize() -> NSSize {
        guard let hosting else { return NSSize(width: MenuBarPanelView.panelWidth, height: 480) }
        hosting.view.layoutSubtreeIfNeeded()
        let height = max(200, hosting.view.fittingSize.height)
        return NSSize(width: MenuBarPanelView.panelWidth, height: height)
    }

    /// Frame for `size`, anchored just under the status item and clamped to the
    /// screen. Deterministic, so repeated calls never move the panel.
    private func panelFrame(for size: NSSize) -> NSRect {
        guard let button = statusItem.button, let buttonWindow = button.window else {
            return NSRect(origin: panel.frame.origin, size: size)
        }
        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let height = min(size.height, visible.height - 16)
        var x = buttonFrame.midX - size.width / 2
        var y = buttonFrame.minY - panelGap - height
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

/// Top-aligned host for the dropdown content.
///
/// The panel resizes to the content a tick after SwiftUI lays out, so for a
/// moment the window height can differ from the content height. Without this
/// alignment SwiftUI centers the content in the taller window, which visibly
/// moves the provider tabs. Anchoring to the top keeps them fixed.
private struct MenuBarPanelContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            MenuBarRoot(model: model)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
