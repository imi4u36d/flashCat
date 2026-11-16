// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import Foundation

/// 一个引擎能提供的具体模型。
public struct GatewayModelRoute: Equatable, Sendable {
    public let model: String
    public let engine: EngineID

    public init(model: String, engine: EngineID) {
        self.model = model
        self.engine = engine
    }
}

/// 把 API 请求里的 `model` 字段映射到真正持有那份权重的引擎。
///
/// 网关客户端只发一个固定的 model id，而 flashCat 可以装好几个引擎，每个引擎
/// 各有自己的模型目录。把请求转给「碰巧在运行」的那个引擎是错的：忽略未知
/// `model` 字段的引擎会拿它已经加载的模型作答，请求看起来成功了，跑的却是别的
/// 权重。所以解析要放在上游调用之前完成，不能交给引擎去判断。
public enum GatewayModelRouting {
    /// `orderedEngines` 里第一个确实能提供 `requestedModel` 的引擎。调用方把正在
    /// 运行的引擎排在最前，这样同一个 id 落在多个引擎上时，优先级和
    /// `GET /v1/models` 的展示顺序一致。
    public static func resolve(
        requestedModel: String?,
        orderedEngines: [EngineID],
        modelsByEngine: [EngineID: [String]]
    ) -> GatewayModelRoute? {
        let wanted = requestedModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !wanted.isEmpty else { return nil }
        for engine in orderedEngines {
            if modelsByEngine[engine]?.contains(wanted) == true {
                return GatewayModelRoute(model: wanted, engine: engine)
            }
        }
        return nil
    }
}
