// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import Foundation

/// 模型广场的仓库来源。
///
/// 两家仓库的 API 形状完全不同，但用户看到的都是「一个模型仓库、一份文件
/// 清单、一条下载」。来源只影响查询与下载器，不改变落地目录和引擎授权：
/// 公共目录里的权重仍然只按 `owner/repo` 记账。
enum HubSource: String, CaseIterable, Identifiable {
    case huggingFace = "huggingface"
    case modelScope = "modelscope"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .huggingFace: return "Hugging Face"
        case .modelScope: return "ModelScope"
        }
    }

    var shortName: String {
        switch self {
        case .huggingFace: return "HF"
        case .modelScope: return "MS"
        }
    }

    var endpoint: String {
        switch self {
        case .huggingFace: return HubClient.endpoint
        case .modelScope: return ModelScopeClient.endpoint
        }
    }

    /// 广场顶部的一句话：搜哪家、下到哪。
    var subtitle: String {
        switch self {
        case .huggingFace:
            return L10n.t("搜 Hugging Face 上的权重，下载到公共目录，所有引擎共用一份")
        case .modelScope:
            return L10n.t("搜 ModelScope 上的权重，下载到公共目录，所有引擎共用一份")
        }
    }

    /// 手填仓库输入框的占位。ModelScope 的 id 同样写成 `owner/repo`。
    var directRepoPlaceholder: String {
        L10n.format("直接填 %@ 的 owner/repo 下载", displayName)
    }

    /// 排序菜单里「不指定排序」的那一项。HF 叫趋势，ModelScope 没这个
    /// 排序，默认就是综合相关度。
    var defaultSortLabel: String {
        switch self {
        case .huggingFace: return L10n.t("趋势")
        case .modelScope: return L10n.t("综合")
        }
    }

    static var stored: HubSource {
        guard let raw = UserDefaults.standard.string(forKey: "hubSource"),
            let value = HubSource(rawValue: raw)
        else { return .huggingFace }
        return value
    }
}

/// 镜像地址的归一化：允许用户只写 `hf-mirror.com`，补上 https；去掉末尾
/// 斜杠；空串表示「用官方」。返回 nil 表示不像一个 http(s) 地址，调用方
/// 应当拒绝写入而不是把下载器带到一个解析不了的 endpoint。
enum HFEndpoint {
    static func normalized(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return "" }
        if !value.contains("://") { value = "https://" + value }
        while value.hasSuffix("/") { value.removeLast() }
        guard let url = URL(string: value),
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = url.host,
            !host.isEmpty
        else { return nil }
        return value
    }
}
