import AppKit
import Combine
import SwiftUI

/// Owns the menu bar status item and its dropdown popover.
///
/// Replaces `MenuBarExtra`. The label is still a single rendered bitmap, but
/// because this controller owns the `NSStatusItem` it can hit-test a click
/// against the rendered provider segments and open the dropdown on the provider
/// whose bar was clicked.
@MainActor
final class MenuBarController: NSObject, ObservableObject {
    private let model: AppModel
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()
    private var regions: [MenuBarStatusRenderer.Region] = []

    init(model: AppModel) {
        self.model = model
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        let hosting = NSHostingController(rootView: MenuBarRoot(model: model))
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = false

        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            button.target = self
            button.action = #selector(handleStatusItemClick(_:))
            button.sendAction(on: [.leftMouseUp])
        }

        model.objectWillChange
            .sink { [weak self] _ in self?.refreshStatusItem() }
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
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        guard let button = statusItem.button else { return }

        // Open on the provider whose bar was clicked; a miss keeps the selection.
        if let provider = clickedProvider(in: button) {
            model.settings.selectedProvider = provider
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
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
