// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import FlashCatCore
import FlashCatKit
import SwiftUI

// MARK: - Engine presentation facts
//
// 引擎页的「选型语言」：模型格式、切换模式、投机解码与运行依赖。它们不是
// 运行时状态，而是每台引擎的固定画像，供目录卡、对比矩阵和筛选用。
// 描述符里已经有能力集合与切换模式，这里只把适配器差异翻译成人能读的短语，
// 避免把 `if engine == .splash` 再散落到各个卡片里。

enum EngineModelFormat: String, CaseIterable, Identifiable {
    case mlx
    case gguf

    var id: String { rawValue }

    var label: String { rawValue.uppercased() }

    var tint: Color {
        switch self {
        case .mlx: return DS.accent
        case .gguf: return Color(console: 0x0D9488)
        }
    }
}

extension EngineID {
    /// 引擎实际接受的权重格式。`mlx-serve` 同时支持两套，splash 只走 GGUF。
    var modelFormats: [EngineModelFormat] {
        switch self {
        case .splash: return [.gguf]
        case .omlx, .mtplx: return [.mlx]
        case .mlxServe: return [.mlx, .gguf]
        default: return [.mlx]
        }
    }

    /// 并发 / 切换模式：热切换还是停进程换模型。
    var switchModeText: String {
        switchMode == .hot ? L10n.t("多模型热切换") : L10n.t("单模型独占")
    }

    /// 投机解码方案。oMLX 按模型二选一，MTPLX 只做 Qwen MTP。
    var speculationLabel: String {
        switch self {
        case .splash: return "DFlash2"
        case .omlx: return "MTP / DFlash2"
        case .mtplx: return "Qwen MTP"
        case .mlxServe: return "标准草稿模型"
        default:
            if capabilities.contains(.mtp), capabilities.contains(.draft) {
                return "MTP / DFlash2"
            }
            if capabilities.contains(.mtp) { return "MTP" }
            if capabilities.contains(.draft) { return "DFlash2" }
            return L10n.t("不支持")
        }
    }

    /// 运行时依赖：给「装它要不要 Python」一个直接答案。
    var runtimeDependencyText: String {
        switch adapter {
        case .splash: return L10n.t("内置 Python + Metal")
        case .omlx: return L10n.t("内置 Python + MLX")
        case .mtplx: return L10n.t("内置 Python + MLX")
        case .mlxServe: return L10n.t("原生二进制 (无 Python)")
        default: return L10n.t("运行时 Pack")
        }
    }

    var supportsVision: Bool { capabilities.contains(.vision) }

    var visionText: String { supportsVision ? L10n.t("支持") : L10n.t("不支持") }
}
