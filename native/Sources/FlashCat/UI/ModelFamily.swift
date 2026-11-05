import SwiftUI

/// 模型家族：从仓库 id / 标签里认出来的权重来源。
///
/// 广场的列表行、详情卡片和模型页卡片都用同一套判断，
/// 免得同一个仓库在不同地方显示成不同的家族。
enum ModelFamily: String, CaseIterable {
    case qwen
    case deepseek
    case llama
    case mistral
    case gemma
    case phi
    case gpt
    case nemotron
    case granite
    case glm
    case kimi
    case flux
    case liquid
    case minimax
    case other

    /// 按 id 优先、提示词最后兜底的顺序识别家族。
    static func resolve(id: String, hint: String? = nil, tags: [String] = []) -> ModelFamily {
        let haystack = ([id, hint ?? ""] + tags).joined(separator: " ").lowercased()
        for family in detectionOrder where family.matches(haystack) {
            return family
        }
        return .other
    }

    private static let detectionOrder: [ModelFamily] = [
        .qwen, .deepseek, .llama, .mistral, .gemma, .phi, .gpt,
        .nemotron, .granite, .glm, .kimi, .flux, .liquid, .minimax,
    ]

    private func matches(_ text: String) -> Bool {
        keywords.contains { text.contains($0) }
    }

    private var keywords: [String] {
        switch self {
        case .qwen: return ["qwen"]
        case .deepseek: return ["deepseek"]
        case .llama: return ["llama", "meta-llama"]
        case .mistral: return ["mistral", "mixtral", "devstral"]
        case .gemma: return ["gemma"]
        case .phi: return ["microsoft/phi", "phi-"]
        case .gpt: return ["gpt-oss", "openai/gpt", "gpt4", "chatgpt"]
        case .nemotron: return ["nemotron"]
        case .granite: return ["granite"]
        case .glm: return ["glm", "chatglm"]
        case .kimi: return ["kimi", "moonshot"]
        case .flux: return ["flux"]
        case .liquid: return ["liquidai", "lfm"]
        case .minimax: return ["minimax"]
        case .other: return []
        }
    }

    var name: String {
        switch self {
        case .qwen: return "Qwen"
        case .deepseek: return "DeepSeek"
        case .llama: return "Llama"
        case .mistral: return "Mistral"
        case .gemma: return "Gemma"
        case .phi: return "Phi"
        case .gpt: return "GPT"
        case .nemotron: return "Nemotron"
        case .granite: return "Granite"
        case .glm: return "GLM"
        case .kimi: return "Kimi"
        case .flux: return "FLUX"
        case .liquid: return "Liquid"
        case .minimax: return "MiniMax"
        case .other: return "本地权重"
        }
    }

    var symbol: String {
        switch self {
        case .qwen: return "cloud.fill"
        case .deepseek: return "water.waves"
        case .llama: return "hare.fill"
        case .mistral: return "wind"
        case .gemma: return "diamond.fill"
        case .phi: return "circle.grid.2x2.fill"
        case .gpt: return "circle.hexagongrid.fill"
        case .nemotron: return "cpu.fill"
        case .granite: return "square.stack.3d.up.fill"
        case .glm: return "sparkle"
        case .kimi: return "moon.stars.fill"
        case .flux: return "paintbrush.pointed.fill"
        case .liquid: return "drop.fill"
        case .minimax: return "waveform.circle.fill"
        case .other: return "cube.fill"
        }
    }

    var colors: [Color] {
        switch self {
        case .qwen: return [Native.violet, Native.blue]
        case .deepseek: return [Native.blue, Native.indigo]
        case .llama: return [Native.blue, Native.teal]
        case .mistral: return [Native.orange, Native.yellow]
        case .gemma: return [Native.blue, Native.teal]
        case .phi: return [Native.blue, Native.indigo]
        case .gpt: return [Native.green, Native.teal]
        case .nemotron: return [Native.green, Native.mint]
        case .granite: return [Native.indigo, Native.blue]
        case .glm: return [Native.violet, Native.pink]
        case .kimi: return [Native.indigo, Native.violet]
        case .flux: return [Native.pink, Native.orange]
        case .liquid: return [Native.teal, Native.blue]
        case .minimax: return [Native.red, Native.orange]
        case .other: return [Native.blue, Native.indigo]
        }
    }
}

/// 家族图标：和引擎图标同一种彩色方块，只是换成家族自己的颜色和符号。
struct ModelFamilyIcon: View {
    let family: ModelFamily
    var size: CGFloat = 30

    var body: some View {
        ArcadeIcon(symbol: family.symbol,
                   colors: family.colors,
                   size: size,
                   glyphScale: 0.46,
                   glow: false)
            .accessibilityLabel(family.name)
    }
}
