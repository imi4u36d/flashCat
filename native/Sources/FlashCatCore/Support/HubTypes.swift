// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import Foundation

/// Hub 搜索与模型详情共用的几个小类型。放在 Core 里，App 的 HubClient 与
/// ModelScope 客户端才能共享同一套排序 / 筛选 / 文件形状。
package enum HubSort: String {
    case trending
    case downloads
}

/// 只要某一类权重。不同引擎吃的格式差别很大（MLX 权重 / GGUF 单文件），
/// 先在服务端筛掉一半噪音，比自己翻十页强。
package enum HubFilter: String, CaseIterable {
    case all
    case mlx
    case gguf

    /// HF 的 `filter` 参数值；`all` 不带这个参数。
    package var apiValue: String? {
        switch self {
        case .all: return nil
        case .mlx: return "mlx"
        case .gguf: return "gguf"
        }
    }
}

package struct HubFile: Hashable {
    package let name: String
    package let size: Int64?

    package var json: [String: Any] {
        var item: [String: Any] = ["name": name]
        if let size { item["size"] = size }
        return item
    }

    package init(name: String, size: Int64?) {
        self.name = name
        self.size = size
    }
}
