import AppKit

/// Borderless, arrow-less panel for the menu bar dropdown.
///
/// `NSPopover` always draws an arrow at its anchor edge and offers no API to
/// hide it, which also makes the content shift as the popover re-lays out. This
/// plain panel is positioned under the status item instead, so the dropdown has
/// no arrow and its top edge stays put while the bottom grows with content.
final class MenuBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 480),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    }
}
