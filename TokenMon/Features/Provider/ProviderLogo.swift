import AppKit
import SwiftUI

enum ProviderLogo {
    static func image(for provider: MonitorProvider) -> NSImage {
        switch provider {
        case .overview:
            // Overview uses an SF Symbol in SwiftUI; return Grok mark as a safe fallback.
            return grok
        case .grok: return grok
        case .opencode: return openCode
        case .cursor: return cursor
        case .claude: return claude
        case .chatgpt: return chatgpt
        case .openrouter: return openRouter
        case .grokbot: return grokbot
        }
    }

    /// Official Grok singularity mark from the asset catalog (template, so SwiftUI tints it).
    static let grok: NSImage = {
        let image = (NSImage(named: "MenuBarIcon")?.copy() as? NSImage) ?? NSImage(size: NSSize(width: 16, height: 16))
        image.isTemplate = true
        return image
    }()

    /// Official OpenCode square O mark from the asset catalog (template for menu-bar tinting).
    static let openCode: NSImage = {
        let image = (NSImage(named: "OpenCodeLogo")?.copy() as? NSImage)
            ?? NSImage(size: NSSize(width: 16, height: 16))
        image.isTemplate = true
        return image
    }()

    /// Official Cursor cube mark from the asset catalog (template for menu-bar tinting).
    static let cursor: NSImage = {
        let image = (NSImage(named: "CursorLogo")?.copy() as? NSImage)
            ?? NSImage(size: NSSize(width: 16, height: 16))
        image.isTemplate = true
        return image
    }()

    /// Anthropic mark from the asset catalog (template for menu-bar tinting).
    static let claude: NSImage = {
        let image = (NSImage(named: "AnthropicLogo")?.copy() as? NSImage)
            ?? NSImage(size: NSSize(width: 16, height: 16))
        image.isTemplate = true
        return image
    }()

    /// OpenAI mark from the asset catalog (template for menu-bar tinting).
    static let chatgpt: NSImage = {
        let image = (NSImage(named: "OpenAILogo")?.copy() as? NSImage)
            ?? NSImage(size: NSSize(width: 16, height: 16))
        image.isTemplate = true
        return image
    }()

    /// OpenRouter mark; falls back to a network glyph until a brand asset lands.
    static let openRouter: NSImage = {
        let image = (NSImage(named: "OpenRouterLogo")?.copy() as? NSImage)
            ?? NSImage(systemSymbolName: "network", accessibilityDescription: "OpenRouter")
            ?? NSImage(size: NSSize(width: 16, height: 16))
        image.isTemplate = true
        return image
    }()

    /// Grok Bot logomark from the asset catalog (template for menu-bar tinting).
    static let grokbot: NSImage = {
        let image = (NSImage(named: "GrokbotLogo")?.copy() as? NSImage)
            ?? NSImage(systemSymbolName: "circle.dashed", accessibilityDescription: "Grokbot")
            ?? NSImage(size: NSSize(width: 16, height: 16))
        image.isTemplate = true
        return image
    }()

    /// TokenMon's own mascot mark, silhouetted from the app icon (template for tinting).
    static let tokenmon: NSImage = {
        let image = (NSImage(named: "TokenMonMark")?.copy() as? NSImage)
            ?? NSImage(size: NSSize(width: 16, height: 16))
        image.isTemplate = true
        return image
    }()
}

/// Section header with the provider logo, used in the menu dropdown.
struct ProviderHeaderLabel: View {
    let provider: MonitorProvider
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            headerMark
                .frame(width: 14, height: 14)
            Text(title)
                .font(PanelTypography.title)
        }
    }

    @ViewBuilder
    private var headerMark: some View {
        if provider == .overview {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
        } else {
            Image(nsImage: ProviderLogo.image(for: provider))
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        }
    }
}
