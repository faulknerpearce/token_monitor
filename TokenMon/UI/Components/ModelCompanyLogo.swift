import SwiftUI

/// Company behind a model id, for its logo.
enum ModelCompany {
    case kimi, qwen, glm, minimax, deepseek, nvidia, muse, anthropic, openai, meta, other

    static func forModelID(_ id: String) -> Self {
        let lower = id.lowercased()
        // Muse Spark is Meta, so it is checked before generic "muse".
        if lower.contains("muse-spark") || lower.contains("muse_spark") { return .meta }
        if lower.contains("kimi") { return .kimi }
        if lower.contains("qwen") { return .qwen }
        if lower.contains("glm") { return .glm }
        if lower.contains("mimo") || lower.contains("minimax") { return .minimax }
        if lower.contains("deepseek") { return .deepseek }
        if lower.contains("nvidia") { return .nvidia }
        if lower.contains("muse") { return .muse }
        if lower.contains("claude") || lower.contains("anthropic") { return .anthropic }
        if lower.contains("gpt") || lower.contains("openai") { return .openai }
        if lower.contains("llama") || lower.contains("meta") { return .meta }
        return .other
    }

    var assetName: String? {
        switch self {
        case .kimi: return "KimiLogo"
        case .qwen: return "AlibabaLogo"
        case .glm: return "ZaiLogo"
        case .minimax: return "MinimaxLogo"
        case .deepseek: return "DeepSeekLogo"
        case .nvidia: return "NvidiaLogo"
        case .muse: return nil
        case .anthropic: return "AnthropicLogo"
        case .openai: return "OpenAILogo"
        case .meta: return "MetaLogo"
        case .other: return nil
        }
    }

    var letter: String {
        switch self {
        case .kimi: return "K"
        case .qwen: return "Q"
        case .glm: return "Z"
        case .minimax: return "M"
        case .deepseek: return "D"
        case .nvidia: return "N"
        case .muse: return "M"
        case .anthropic: return "A"
        case .openai: return "O"
        case .meta: return "M"
        case .other: return "•"
        }
    }

    var logoBackground: Color {
        switch self {
        case .kimi: return Color(red: 0.12, green: 0.12, blue: 0.13)
        case .qwen: return Color(red: 0.32, green: 0.25, blue: 0.65)
        case .glm: return Color.white
        case .minimax: return Color(red: 0.95, green: 0.25, blue: 0.40)
        case .deepseek: return Color(red: 0.11, green: 0.38, blue: 0.82)
        case .nvidia: return Color(red: 0.45, green: 0.72, blue: 0.11)
        case .muse: return Color(red: 0.90, green: 0.20, blue: 0.22)
        case .anthropic: return Color(red: 0.85, green: 0.65, blue: 0.25)
        case .openai: return Color(red: 0.10, green: 0.10, blue: 0.10)
        case .meta: return Color(red: 0.05, green: 0.45, blue: 0.95)
        case .other: return Color.primary.opacity(0.12)
        }
    }

    var logoForeground: Color {
        self == .glm ? .black : .white
    }
}

/// Round company logo for a model id, or a lettered circle when no asset exists.
struct ModelCompanyLogo: View {
    let modelID: String
    private var company: ModelCompany { ModelCompany.forModelID(modelID) }

    var body: some View {
        Group {
            if let asset = company.assetName {
                ZStack {
                    Circle().fill(Color.white)
                    Image(asset, bundle: nil)
                        .resizable()
                        .scaledToFit()
                        // Template logos (OpenAI, Anthropic) must tint dark so they
                        // stay visible on the white backing in dark mode.
                        .foregroundStyle(Color.black)
                        .padding(company == .deepseek ? 5 : 4)
                        .frame(width: 28, height: 28, alignment: .center)
                }
            } else {
                ZStack {
                    Circle().fill(company.logoBackground)
                    Text(company.letter)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(company.logoForeground)
                }
            }
        }
        .frame(width: 28, height: 28)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }
}
