import AppKit
import SwiftUI

/// Renders the menu bar status as a single bitmap.
/// MenuBarExtra drops GeometryReader / Circle SwiftUI, so we draw explicitly.
///
/// Composites enabled provider segments in `providerOrder`:
/// Grok (always) + optional Cursor / OpenCode / Claude.
///
/// The mutable statics (image cache, cached appearance, observer) are isolated
/// to the main actor since rendering drives off SwiftUI's main-actor label.
@MainActor
enum MenuBarStatusRenderer {
    private static let _cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 40
        return cache
    }()

    private static var appearanceObserver: NSObjectProtocol?

    // swiftlint:disable:next function_parameter_count
    static func image(
        selectedProvider: MonitorProvider,
        showSelectedProvider: Bool,
        snapshot: WeeklyUsageSnapshot?,
        openCodeSnapshot: OpenCodeSnapshot?,
        cursorSnapshot: CursorSnapshot?,
        claudeSnapshot: ClaudeSnapshot?,
        chatGPTSnapshot: ChatGPTSnapshot?,
        openRouterSnapshot: OpenRouterSnapshot?,
        isGrokSignedIn: Bool,
        showGrokBar: Bool,
        showGrokCategories: Bool,
        showOpenCodeBar: Bool,
        showCursorBar: Bool,
        showClaudeBar: Bool,
        providerOrder: [MonitorProvider],
        visibleProductIDs: Set<String>
    ) -> NSImage {
        ensureAppearanceObserver()

        let grokProducts: [ProductUsage] = {
            guard let snapshot else { return [] }
            return menuBarProducts(from: snapshot, visibleProductIDs: visibleProductIDs)
        }()

        let cacheKey = _cacheKey(
            grokProducts: grokProducts,
            selectedProvider: selectedProvider,
            showSelectedProvider: showSelectedProvider,
            snapshot: snapshot,
            openCodeSnapshot: openCodeSnapshot,
            cursorSnapshot: cursorSnapshot,
            claudeSnapshot: claudeSnapshot,
            chatGPTSnapshot: chatGPTSnapshot,
            openRouterSnapshot: openRouterSnapshot,
            isGrokSignedIn: isGrokSignedIn,
            showGrokBar: showGrokBar,
            showGrokCategories: showGrokCategories,
            showOpenCodeBar: showOpenCodeBar,
            showCursorBar: showCursorBar,
            showClaudeBar: showClaudeBar,
            providerOrder: providerOrder,
            visibleProductIDs: visibleProductIDs
        )
        if let cached = _cache.object(forKey: cacheKey as NSString) {
            return cached
        }

        let image = _render(
            grokProducts: grokProducts,
            selectedProvider: selectedProvider,
            showSelectedProvider: showSelectedProvider,
            snapshot: snapshot,
            openCodeSnapshot: openCodeSnapshot,
            cursorSnapshot: cursorSnapshot,
            claudeSnapshot: claudeSnapshot,
            chatGPTSnapshot: chatGPTSnapshot,
            openRouterSnapshot: openRouterSnapshot,
            isGrokSignedIn: isGrokSignedIn,
            showGrokBar: showGrokBar,
            showGrokCategories: showGrokCategories,
            showOpenCodeBar: showOpenCodeBar,
            showCursorBar: showCursorBar,
            showClaudeBar: showClaudeBar,
            providerOrder: providerOrder
        )
        _cache.setObject(image, forKey: cacheKey as NSString)
        return image
    }

    // swiftlint:disable:next function_parameter_count
    private static func _cacheKey(
        grokProducts: [ProductUsage],
        selectedProvider: MonitorProvider,
        showSelectedProvider: Bool,
        snapshot: WeeklyUsageSnapshot?,
        openCodeSnapshot: OpenCodeSnapshot?,
        cursorSnapshot: CursorSnapshot?,
        claudeSnapshot: ClaudeSnapshot?,
        chatGPTSnapshot: ChatGPTSnapshot?,
        openRouterSnapshot: OpenRouterSnapshot?,
        isGrokSignedIn: Bool,
        showGrokBar: Bool,
        showGrokCategories: Bool,
        showOpenCodeBar: Bool,
        showCursorBar: Bool,
        showClaudeBar: Bool,
        providerOrder: [MonitorProvider],
        visibleProductIDs: Set<String>
    ) -> String {
        let chrome = menuBarAppearanceName
        let grok = snapshot.map { Int($0.usedPercent.rounded()) } ?? -1
        let openCode = openCodeSnapshot.map { Int($0.primaryUsedPercent.rounded()) } ?? -1
        let cursor = cursorSnapshot.map { Int($0.usedPercent.rounded()) } ?? -1
        let claude = claudeSnapshot.map { Int($0.headlineUsedPercent.rounded()) } ?? -1
        let chatGPT = chatGPTSnapshot.map { Int($0.headlineUsedPercent.rounded()) } ?? -1
        let openRouter = openRouterSnapshot?.usedPercent.map { Int($0.rounded()) } ?? -1

        let productKey = grokProducts
            .map { "\($0.id):\(Int($0.percentOfPool.rounded()))" }
            .joined(separator: ",")
        let productIDs = visibleProductIDs.sorted().joined(separator: ",")
        let parts = [
            "mb-\(showSelectedProvider ? 1 : 0)-\(selectedProvider)-\(grok)-\(openCode)-\(cursor)"
                + "-\(claude)-\(chatGPT)-\(openRouter)",
            "\(isGrokSignedIn)-\(showGrokBar)-\(showGrokCategories)-\(showOpenCodeBar)-\(showCursorBar)-\(showClaudeBar)",
            "\(providerOrder.map(\.rawValue).joined(separator: ","))",
            "\(productKey)-\(productIDs)-\(chrome)"
        ]
        return parts.joined(separator: "-")
    }

    private struct CompositeSolidSegment {
        let usedPercent: Double?
        let text: String
        let textSize: NSSize
        let color: NSColor
        let icon: NSImage
        let iconInset: CGFloat
    }

    private enum CompositePiece {
        case grok
        case solid(CompositeSolidSegment)
    }

    private static func compositePieces(
        usedAttrs: [NSAttributedString.Key: Any],
        cursorSnapshot: CursorSnapshot?,
        openCodeSnapshot: OpenCodeSnapshot?,
        claudeSnapshot: ClaudeSnapshot?,
        showCursorBar: Bool,
        showOpenCodeBar: Bool,
        showClaudeBar: Bool,
        providerOrder: [MonitorProvider]
    ) -> [CompositePiece] {
        func solid(
            used: Double?,
            color: NSColor,
            icon: NSImage,
            iconInset: CGFloat
        ) -> CompositeSolidSegment {
            let text = used.map { "\(Int($0.rounded()))%" } ?? "—"
            return CompositeSolidSegment(
                usedPercent: used,
                text: text,
                textSize: text.size(withAttributes: usedAttrs),
                color: color,
                icon: icon,
                iconInset: iconInset
            )
        }

        var pieces: [CompositePiece] = []
        for provider in MonitorProvider.normalizedOrder(providerOrder) {
            switch provider {
            case .grok:
                pieces.append(.grok)
            case .cursor:
                guard showCursorBar else { continue }
                pieces.append(.solid(solid(
                    used: cursorSnapshot?.usedPercent,
                    color: ConcentricUsageRingView.cursorSRGB.nsColor,
                    icon: ProviderLogo.cursor,
                    iconInset: 0
                )))
            case .opencode:
                guard showOpenCodeBar else { continue }
                pieces.append(.solid(solid(
                    used: openCodeSnapshot?.primaryUsedPercent,
                    color: NSColor(calibratedRed: 0.90, green: 0.45, blue: 0.20, alpha: 1),
                    icon: ProviderLogo.openCode,
                    iconInset: 2.5
                )))
            case .claude:
                guard showClaudeBar else { continue }
                pieces.append(.solid(solid(
                    used: claudeSnapshot?.headlineUsedPercent,
                    color: ConcentricUsageRingView.claudeSRGB.nsColor,
                    icon: ProviderLogo.claude,
                    iconInset: 0
                )))
            case .overview, .chatgpt, .openrouter:
                continue
            }
        }
        return pieces
    }

    // swiftlint:disable:next function_parameter_count
    private static func _render(
        grokProducts: [ProductUsage],
        selectedProvider: MonitorProvider,
        showSelectedProvider: Bool,
        snapshot: WeeklyUsageSnapshot?,
        openCodeSnapshot: OpenCodeSnapshot?,
        cursorSnapshot: CursorSnapshot?,
        claudeSnapshot: ClaudeSnapshot?,
        chatGPTSnapshot: ChatGPTSnapshot?,
        openRouterSnapshot: OpenRouterSnapshot?,
        isGrokSignedIn: Bool,
        showGrokBar: Bool,
        showGrokCategories: Bool,
        showOpenCodeBar: Bool,
        showCursorBar: Bool,
        showClaudeBar: Bool,
        providerOrder: [MonitorProvider]
    ) -> NSImage {
        if showSelectedProvider {
            return renderSelectedProvider(
                selectedProvider,
                snapshot: snapshot,
                openCodeSnapshot: openCodeSnapshot,
                cursorSnapshot: cursorSnapshot,
                claudeSnapshot: claudeSnapshot,
                chatGPTSnapshot: chatGPTSnapshot,
                openRouterSnapshot: openRouterSnapshot,
                isGrokSignedIn: isGrokSignedIn
            )
        }
        let height: CGFloat = 22
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .medium)
        let smallFont = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        let textColor = chromeColor
        let iconSize: CGFloat = 16
        let barWidth: CGFloat = 48
        let barHeight: CGFloat = 8
        let dotSize: CGFloat = 7
        let gap: CGFloat = 7
        let segmentGap: CGFloat = 10

        let usedAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor
        ]
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: smallFont,
            .foregroundColor: textColor
        ]

        let grokSigned = isGrokSignedIn && snapshot != nil
        let grokUsedText: String
        let grokUsedSize: NSSize
        let categoryLabels: [(label: String, size: NSSize)]
        if grokSigned, let snap = snapshot {
            grokUsedText = "\(Int(snap.usedPercent.rounded()))%"
            grokUsedSize = grokUsedText.size(withAttributes: usedAttrs)
            categoryLabels = showGrokCategories
                ? grokProducts.map {
                    let label = "\(ProductCatalog.shortName(for: $0.id)) \(Int($0.percentOfPool.rounded()))%"
                    return (label, label.size(withAttributes: labelAttrs))
                }
                : []
        } else {
            grokUsedText = "Grok"
            grokUsedSize = grokUsedText.size(withAttributes: usedAttrs)
            categoryLabels = []
        }

        var grokBlockWidth = iconSize + gap + grokUsedSize.width
        // Keep the bar slot even before the first snapshot / after sign-out so
        // the status item width does not collapse (that read as the graph vanishing).
        if showGrokBar { grokBlockWidth += gap + barWidth }
        if grokSigned, showGrokCategories {
            for item in categoryLabels {
                grokBlockWidth += gap + dotSize + 4 + item.size.width
            }
        }

        let pieces = compositePieces(
            usedAttrs: usedAttrs,
            cursorSnapshot: cursorSnapshot,
            openCodeSnapshot: openCodeSnapshot,
            claudeSnapshot: claudeSnapshot,
            showCursorBar: showCursorBar,
            showOpenCodeBar: showOpenCodeBar,
            showClaudeBar: showClaudeBar,
            providerOrder: providerOrder
        )

        var width: CGFloat = 0
        for (index, piece) in pieces.enumerated() {
            if index > 0 { width += segmentGap }
            switch piece {
            case .grok:
                width += grokBlockWidth
            case let .solid(segment):
                width += iconSize + gap + segment.textSize.width + gap + barWidth
            }
        }

        width = ceil(width + 2)
        let size = NSSize(width: max(width, 20), height: height)
        return makeImage(size: size) {
            var x: CGFloat = 0
            let midY = height / 2

            for (index, piece) in pieces.enumerated() {
                if index > 0 { x += segmentGap }
                switch piece {
                case .grok:
                    drawGrokIcon(in: NSRect(x: x, y: midY - iconSize / 2, width: iconSize, height: iconSize))
                    x += iconSize + gap
                    grokUsedText.draw(
                        at: NSPoint(x: x, y: midY - grokUsedSize.height / 2 - 0.5),
                        withAttributes: usedAttrs
                    )
                    x += grokUsedSize.width
                    if showGrokBar {
                        x += gap
                        let barRect = NSRect(
                            x: x, y: midY - barHeight / 2, width: barWidth, height: barHeight
                        )
                        drawSolidBar(
                            in: barRect,
                            usedPercent: grokSigned ? (snapshot?.usedPercent ?? 0) : 0,
                            color: nsColor(.chat)
                        )
                        x += barWidth
                    }
                    if grokSigned, showGrokCategories {
                        for (product, item) in zip(grokProducts, categoryLabels) {
                            x += gap
                            let dotRect = NSRect(
                                x: x, y: midY - dotSize / 2, width: dotSize, height: dotSize
                            )
                            nsColor(product.colorToken).setFill()
                            NSBezierPath(ovalIn: dotRect).fill()
                            x += dotSize + 4
                            item.label.draw(
                                at: NSPoint(x: x, y: midY - item.size.height / 2 - 0.5),
                                withAttributes: labelAttrs
                            )
                            x += item.size.width
                        }
                    }
                case let .solid(segment):
                    let iconRect = NSRect(x: x, y: midY - iconSize / 2, width: iconSize, height: iconSize)
                    drawProviderIcon(segment.icon, in: iconRect, inset: segment.iconInset)
                    x += iconSize + gap
                    segment.text.draw(
                        at: NSPoint(x: x, y: midY - segment.textSize.height / 2 - 0.5),
                        withAttributes: usedAttrs
                    )
                    x += segment.textSize.width + gap
                    let barRect = NSRect(
                        x: x, y: midY - barHeight / 2, width: barWidth, height: barHeight
                    )
                    drawSolidBar(in: barRect, usedPercent: segment.usedPercent ?? 0, color: segment.color)
                    x += barWidth
                }
            }
        }
    }

    /// Single-provider label with fixed geometry: icon | percent slot | usage bar.
    ///
    /// Every selection — Overview included — renders through this template while
    /// "show selected provider" is on, so the status item width never changes and
    /// the dropdown anchored beneath it keeps one x position when switching
    /// providers. The bar is tinted with the provider's brand accent; Overview
    /// has no single headline metric, so it shows the TokenMon mark over an
    /// empty track. Grok category labels are composite-only since their
    /// variable widths would break the fixed anchor.
    private static func renderSelectedProvider(
        _ provider: MonitorProvider,
        snapshot: WeeklyUsageSnapshot?,
        openCodeSnapshot: OpenCodeSnapshot?,
        cursorSnapshot: CursorSnapshot?,
        claudeSnapshot: ClaudeSnapshot?,
        chatGPTSnapshot: ChatGPTSnapshot?,
        openRouterSnapshot: OpenRouterSnapshot?,
        isGrokSignedIn: Bool
    ) -> NSImage {
        let height: CGFloat = 22
        let iconSize: CGFloat = 16
        let gap: CGFloat = 7
        let barWidth: CGFloat = 48
        let barHeight: CGFloat = 8
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: chromeColor]

        let usedPercent: Double?
        switch provider {
        case .overview:
            usedPercent = nil
        case .grok:
            usedPercent = isGrokSignedIn ? snapshot?.usedPercent : nil
        case .opencode:
            usedPercent = openCodeSnapshot?.primaryUsedPercent
        case .cursor:
            usedPercent = cursorSnapshot?.usedPercent
        case .claude:
            usedPercent = claudeSnapshot?.headlineUsedPercent
        case .chatgpt:
            usedPercent = chatGPTSnapshot?.headlineUsedPercent
        case .openrouter:
            usedPercent = openRouterSnapshot?.usedPercent
        }

        // Monospaced digits make every "NN%" string the same width; the slot
        // reserves that width so "—" (no data) renders at identical geometry.
        let textSlotWidth = ceil("100%".size(withAttributes: attrs).width)
        let textX = iconSize + gap
        let barX = textX + textSlotWidth + gap
        let width = ceil(barX + barWidth + 2)

        let size = NSSize(width: max(width, 20), height: height)
        return makeImage(size: size) {
            let midY = height / 2
            let icon = provider == .overview ? ProviderLogo.tokenmon : ProviderLogo.image(for: provider)
            drawProviderIcon(icon, in: NSRect(x: 0, y: midY - iconSize / 2, width: iconSize, height: iconSize), inset: 0)
            let text = usedPercent.map { "\(Int($0.rounded()))%" } ?? "—"
            let textSize = text.size(withAttributes: attrs)
            text.draw(at: NSPoint(x: textX, y: midY - textSize.height / 2 - 0.5), withAttributes: attrs)
            drawSolidBar(
                in: NSRect(x: barX, y: midY - barHeight / 2, width: barWidth, height: barHeight),
                usedPercent: usedPercent ?? 0,
                color: providerAccent(provider)
            )
        }
    }

    /// Bake a bitmap via `NSBitmapImageRep` instead of `lockFocus`. MenuBarExtra
    /// often has no focused graphics context; `lockFocus` then produced an empty
    /// image that got cached, so the graph vanished until the cache key changed.
    private static func makeImage(size: NSSize, draw: () -> Void) -> NSImage {
        let scale: CGFloat = 2
        let pixelsWide = max(1, Int((size.width * scale).rounded(.up)))
        let pixelsHigh = max(1, Int((size.height * scale).rounded(.up)))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return NSImage(size: size)
        }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        draw()
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        image.isTemplate = false
        return image
    }

    /// Brand accent per provider; values mirror `ConcentricUsageRingView`.
    private static func providerAccent(_ provider: MonitorProvider) -> NSColor {
        switch provider {
        case .overview:
            return chromeColor
        case .grok:
            return SRGB(red: 0.11, green: 0.38, blue: 0.82).nsColor
        case .opencode:
            return ModelPalette.orange.nsColor
        case .cursor:
            return ConcentricUsageRingView.cursorSRGB.nsColor
        case .claude:
            return ConcentricUsageRingView.claudeSRGB.nsColor
        case .chatgpt:
            return SRGB(red: 0.16, green: 0.52, blue: 0.46).nsColor
        case .openrouter:
            return SRGB(red: 0.45, green: 0.36, blue: 0.90).nsColor
        }
    }

    private static func drawSolidBar(in barRect: NSRect, usedPercent: Double, color: NSColor) {
        drawBarTrack(in: barRect)
        // Keep a 2pt sliver at 0% so the brand fill never collapses to nothing
        // after a weekly reset (fillWidth was 0, so the "always draw a fill"
        // path still skipped, leaving only a washed-out track).
        let raw = barRect.width * CGFloat(Percent.clamp(usedPercent) / 100)
        let fillWidth = max(2, raw)
        let fillRect = NSRect(x: barRect.minX, y: barRect.minY, width: fillWidth, height: barRect.height)
        color.setFill()
        let clip = NSBezierPath(roundedRect: barRect, xRadius: barRect.height / 2, yRadius: barRect.height / 2)
        NSGraphicsContext.saveGraphicsState()
        clip.addClip()
        NSBezierPath(rect: fillRect).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawBarTrack(in barRect: NSRect) {
        // Opaque enough to read as a visible empty graph slot against a
        // translucent menu bar, unlike the previous 0.14 alpha which washed out.
        chromeColor.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: barRect, xRadius: barRect.height / 2, yRadius: barRect.height / 2).fill()
    }

    private static func drawProviderIcon(_ icon: NSImage, in rect: NSRect, inset: CGFloat) {
        let drawRect = inset > 0 ? rect.insetBy(dx: inset, dy: inset) : rect
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: drawRect).addClip()
        // `from: .zero` draws the full glyph; a destination-sized source rect
        // cropped large SVGs (OpenCode 300×300, Cursor ~65×68) to empty corners.
        icon.draw(
            in: drawRect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        if icon.isTemplate {
            chromeColor.setFill()
            drawRect.fill(using: .sourceIn)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawGrokIcon(in rect: NSRect) {
        drawProviderIcon(ProviderLogo.grok, in: rect, inset: 0)
    }

    private static func menuBarProducts(
        from snapshot: WeeklyUsageSnapshot,
        visibleProductIDs: Set<String>
    ) -> [ProductUsage] {
        ProductCatalog.filtered(
            snapshot.products,
            visible: visibleProductIDs,
            threshold: 0.05
        )
    }

    private static func nsColor(_ token: ProductColor) -> NSColor {
        colorCache[token] ?? makeColor(token)
    }

    private static let colorCache: [ProductColor: NSColor] = {
        ProductColor.allCases.reduce(into: [:]) { cache, token in
            cache[token] = makeColor(token)
        }
    }()

    private static func makeColor(_ token: ProductColor) -> NSColor {
        token.sRGB.nsColor
    }

    private static var chromeColor: NSColor {
        var cg: CGColor = .black
        menuBarAppearance().performAsCurrentDrawingAppearance {
            cg = NSColor.labelColor.cgColor
        }
        return NSColor(cgColor: cg) ?? .labelColor
    }

    private static var menuBarAppearanceName: String {
        let bestMatch = menuBarAppearance().bestMatch(from: [.darkAqua, .aqua])
        return bestMatch?.rawValue ?? menuBarAppearance().name.rawValue
    }

    private static func menuBarAppearance() -> NSAppearance {
        // Prefer the status item, never the dropdown panel. Matching
        // "MenuBarExtra" first flipped chrome to the panel appearance when the
        // menu opened, which washed out (or cached) the graph until it closed.
        var extra: NSAppearance?
        for window in NSApp.windows {
            let name = window.className
            if name.contains("StatusBar") || name.contains("NSStatusItem") {
                return window.effectiveAppearance
            }
            if extra == nil, name.contains("MenuBarExtra") {
                extra = window.effectiveAppearance
            }
        }
        return extra ?? NSApp.effectiveAppearance
    }

    private static func ensureAppearanceObserver() {
        guard appearanceObserver == nil else { return }
        appearanceObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { _ in
            _cache.removeAllObjects()
        }
    }
}
