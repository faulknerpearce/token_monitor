import AppKit
import Combine
import SwiftUI

/// Owns the menu bar status item and its dropdown panel.
///
/// A plain `NSStatusItem` lets a click be hit-tested against the rendered
/// provider segments. The dropdown is a borderless `MenuBarPanel` positioned
/// under the status item, so the dropdown is arrow-less and the top edge stays
/// put while the bottom grows with the provider content.
///
/// The status image re-renders only when an input it draws changes (settings,
/// a provider snapshot, Grok sign-in state, the menu-bar appearance), at most
/// once per `AppModel.changeCoalescing`, and the button image is reassigned
/// only when the rendered image differs.
@MainActor
final class MenuBarController: NSObject {
    private let model: AppModel
    private let statusItem: NSStatusItem
    private let panel = MenuBarPanel()
    private var hosting: NSHostingController<MenuBarPanelContent>?
    private var cancellables = Set<AnyCancellable>()
    private var regions: [MenuBarStatusRenderer.Region] = []
    private var escapeMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var appearanceObservation: NSKeyValueObservation?
    /// Key of the image currently on the button.
    private var statusKey: String?

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

        observeStatusInputs()
        observeAppearance()

        // `AppModel` emits once per burst of changes, after the values are set.
        // Content height can change (e.g. switching provider tabs), so re-fit
        // the panel's bottom edge once SwiftUI has laid out.
        model.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.resizePanelIfNeeded() }
            }
            .store(in: &cancellables)

        refreshStatusItem()
    }

    /// Re-renders the status image when anything it draws changes. `@Published`
    /// emits in `willSet`; the throttle delivers on a later run-loop pass, after
    /// the new values are stored.
    private func observeStatusInputs() {
        let inputs: [AnyPublisher<Void, Never>] = [
            model.settings.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            model.poller.$snapshot.map { _ in () }.eraseToAnyPublisher(),
            model.openCodePoller.$snapshot.map { _ in () }.eraseToAnyPublisher(),
            model.cursorPoller.$snapshot.map { _ in () }.eraseToAnyPublisher(),
            model.claudePoller.$snapshot.map { _ in () }.eraseToAnyPublisher(),
            model.chatGPTPoller.$snapshot.map { _ in () }.eraseToAnyPublisher(),
            model.openRouterPoller.$snapshot.map { _ in () }.eraseToAnyPublisher(),
            model.grokbotPoller.$snapshot.map { _ in () }.eraseToAnyPublisher(),
            model.auth.$isSignedIn.map { _ in () }.eraseToAnyPublisher(),
            model.auth.$needsSignIn.map { _ in () }.eraseToAnyPublisher()
        ]
        Publishers.MergeMany(inputs)
            .throttle(for: AppModel.changeCoalescing, scheduler: RunLoop.main, latest: true)
            .sink { [weak self] in self?.refreshStatusItem() }
            .store(in: &cancellables)
    }

    /// The label bitmap bakes in the menu bar's label colour, so a light/dark
    /// switch (or a wallpaper-driven menu bar tint change) re-renders it.
    private func observeAppearance() {
        appearanceObservation = statusItem.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.refreshStatusItem() }
            }
        }
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // The status bar adopts the new appearance after this notification.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.refreshStatusItem() }
            }
        })
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
            visibleProductIDs: settings.visibleProductIDs,
            enabledProviders: settings.enabledProviderIDs,
            appearance: statusItem.button?.effectiveAppearance
        )
        regions = rendered.regions
        guard rendered.key != statusKey else { return }
        statusKey = rendered.key
        // The item stays `variableLength`: an explicit length animates the status
        // item, which makes the whole menu bar shift when the label updates.
        statusItem.button?.image = rendered.image
    }

    @objc private func handleStatusItemClick(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        let clicked = clickedProvider(in: button)

        if panel.isVisible {
            // Switch tabs in place when another provider's bar is clicked;
            // only toggle closed when the active provider (or a miss) is clicked.
            if let clicked, clicked != model.settings.selectedProvider {
                model.settings.selectedProvider = clicked
                return
            }
            hidePanel()
            return
        }

        // Open on the provider whose bar was clicked; a miss keeps the selection.
        if let clicked {
            model.settings.selectedProvider = clicked
        }
        showPanel()
    }

    // MARK: - Panel

    private func showPanel() {
        // `sizingOptions` stays at its default: a window AppKit resizes itself
        // grows from the wrong edge and the content shifts, so the panel frame
        // is set explicitly from the status item.
        let hosting = NSHostingController(rootView: MenuBarPanelContent(model: model))
        self.hosting = hosting
        panel.contentViewController = hosting

        panel.setFrame(panelFrame(for: panelContentSize()), display: true)
        panel.makeKeyAndOrderFront(nil)
        model.setMenuOpen(true)
    }

    private func hidePanel() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        panel.contentViewController = nil
        hosting = nil
        model.setMenuOpen(false)
    }

    /// Fits the panel to the SwiftUI content via `panelFrame(for:)`, which clamps
    /// height to the visible screen and re-anchors under the status item so a
    /// tall provider view stays above the bottom of the display.
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
    /// screen. Deterministic, so repeated calls keep the panel in place.
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
    /// provider segment under it. Uses gap-tolerant snapping so clicks landing
    /// in the inter-segment gap, the trailing image padding, or a few points
    /// of `variableLength` button padding still select the adjacent provider.
    private func clickedProvider(in button: NSStatusBarButton) -> MonitorProvider? {
        guard let window = button.window else { return nil }
        // Reads the live pointer position and maps it through the window. For
        // status items, `NSApp.currentEvent.locationInWindow` reports the
        // button's center, which would resolve every click to one provider.
        let pointInWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let pointInButton = button.convert(pointInWindow, from: nil)
        // Maps into the drawn bitmap's coordinate space. The button is wider than
        // the image (AppKit pads it), so the cell reports where the image
        // actually sits.
        let imageOriginX: CGFloat
        if let cell = button.cell as? NSButtonCell {
            imageOriginX = cell.imageRect(forBounds: button.bounds).minX
        } else {
            let imageWidth = button.image?.size.width ?? button.bounds.width
            imageOriginX = (button.bounds.width - imageWidth) / 2
        }
        let xInImage = pointInButton.x - imageOriginX
        return MenuBarStatusRenderer.providerSnapped(atX: xInImage, in: regions)
    }
}

/// Top-aligned host for the dropdown content.
///
/// The panel resizes to the content a tick after SwiftUI lays out, so for a
/// moment the window height can differ from the content height. SwiftUI
/// centers content in a taller window, which visibly moves the provider tabs;
/// anchoring to the top keeps them fixed.
///
/// The panel's height is clamped to the screen. The content sits in one
/// scroll view: measured unconstrained (the hosting view's `fittingSize`) it
/// reports the content's full height, it bounces only when the content is
/// taller than the panel, and once the panel is shorter the content scrolls.
private struct MenuBarPanelContent: View {
    let model: AppModel

    var body: some View {
        ScrollView(.vertical) {
            MenuBarRoot(model: model)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
