// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import Foundation

/// 模型广场的仓库来源。
///
/// 几家仓库的 API 形状并不相同，但用户看到的都是「一个模型仓库、一份文件
/// 清单、一条下载」。来源只影响查询与下载器，不改变落地目录和引擎授权：
/// 公共目录里的权重仍然只按 `owner/repo` 记账。
///
/// `hfMirror` 是 Hugging Face 的镜像通道：仓库 id、REST 路径和下载脚本都和
/// 官方一样，只是端点换成 hf-mirror.com；它和 `huggingFace` 的区别仅在
/// 端点解析（官方会读设置里的自定义镜像，hfMirror 固定走镜像站）。
package enum HubSource: String, CaseIterable, Identifiable, Codable, Sendable {
    case huggingFace = "huggingface"
    case hfMirror = "hf-mirror"
    case modelScope = "modelscope"

    package var id: String { rawValue }

    package var displayName: String {
        switch self {
        case .huggingFace: return "Hugging Face"
        case .hfMirror: return "HF-Mirror"
        case .modelScope: return "ModelScope"
        }
    }

    package var shortName: String {
        switch self {
        case .huggingFace: return "HF"
        case .hfMirror: return "HFM"
        case .modelScope: return "MS"
        }
    }

    package var endpoint: String {
        switch self {
        case .huggingFace: return HFEndpoint.resolved(for: .huggingFace) ?? HFEndpoint.official
        case .hfMirror: return HFEndpoint.mirror
        case .modelScope: return "https://www.modelscope.cn"
        }
    }

    /// 与 Hugging Face 共用 REST 接口和 `huggingface_hub` 下载器。
    package var isHuggingFaceCompatible: Bool { self != .modelScope }

    /// 广场顶部的一句话：搜哪家、下到哪。
    package var subtitle: String {
        switch self {
        case .huggingFace:
            return L10n.t("搜 Hugging Face 上的权重；下载时选一个引擎的模型目录")
        case .hfMirror:
            return L10n.t("经 hf-mirror.com 镜像搜 Hugging Face 权重；下载时选一个引擎的模型目录")
        case .modelScope:
            return L10n.t("搜 ModelScope 上的权重；下载时选一个引擎的模型目录")
        }
    }

    /// 手填仓库输入框的占位。ModelScope 的 id 同样写成 `owner/repo`。
    package var directRepoPlaceholder: String {
        switch self {
        case .hfMirror:
            return L10n.t("直接填 owner/repo，经 hf-mirror.com 下载")
        default:
            return L10n.format("直接填 %@ 的 owner/repo 下载", displayName)
        }
    }

    /// 排序菜单里「不指定排序」的那一项。HF 叫趋势，ModelScope 没这个
    /// 排序，默认就是综合相关度。
    package var defaultSortLabel: String {
        switch self {
        case .huggingFace, .hfMirror: return L10n.t("趋势")
        case .modelScope: return L10n.t("综合")
        }
    }

    package static var stored: HubSource {
        guard let raw = UserDefaults.standard.string(forKey: "hubSource"),
            let value = HubSource(rawValue: raw)
        else { return .huggingFace }
        return value
    }

    /// 引擎目录里的下载没有来源参数（模型 id 本身来自 Hugging Face 的推荐
    /// 清单或搜索结果），沿用设置里选的那条通道；ModelScope 的仓库 id 不能
    /// 拿去问 Hugging Face，所以退回官方/自定义端点那条。
    package static var downloadSource: HubSource {
        stored.isHuggingFaceCompatible ? stored : .huggingFace
    }
}

/// 镜像地址的归一化：允许用户只写 `hf-mirror.com`，补上 https；去掉末尾
/// 斜杠；空串表示「用官方」。返回 nil 表示不像一个 http(s) 地址，调用方
/// 应当拒绝写入而不是把下载器带到一个解析不了的 endpoint。
package enum HFEndpoint {
    package static let official = "https://huggingface.co"
    /// 国内可直连的 Hugging Face 镜像。`HubSource.hfMirror` 固定用它，
    /// 不受设置里的自定义端点影响。
    package static let mirror = "https://hf-mirror.com"

    package static func normalized(_ raw: String) -> String? {
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

    /// 设置页里填的自定义端点。空串表示官方地址。
    package static var configured: String {
        normalized(UserDefaults.standard.string(forKey: "hfEndpoint") ?? "") ?? ""
    }

    /// 某个来源实际使用的端点。ModelScope 不走 HF 端点，返回 nil。
    package static func resolved(for source: HubSource) -> String? {
        switch source {
        case .huggingFace:
            let custom = configured
            return custom.isEmpty ? official : custom
        case .hfMirror:
            return mirror
        case .modelScope:
            return nil
        }
    }
}
