// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import FlashCatCore
import FlashCatKit
import Foundation

/// 网关与端点地址：界面要的 Base URL、以及「按设置把网关启停到正确端口」。
///
/// 单独一页是因为它与引擎编排状态无关——只读端口与设置；放在派生量中间会让
/// 「网关现在在哪、什么时候重启」这件事实散掉。
extension AppState {
    var endpointURL: String { "http://127.0.0.1:\(port)/v1" }

    /// The gateway's address for OpenAI-dialect clients: engine-independent, so
    /// a client's Base URL never needs to change when the engine or its port does.
    var gatewayURL: String { "http://127.0.0.1:\(settings.gatewayPort)/v1" }

    /// The same gateway for Anthropic-dialect clients. Anthropic SDKs and Claude
    /// Code append `/v1/messages` themselves, so this one stops at the root.
    var gatewayClaudeURL: String { "http://127.0.0.1:\(settings.gatewayPort)" }

    /// Start the gateway when enabled; restart it onto a new port when the
    /// setting changed, or stop it when disabled.
    func applyGatewaySettings() {
        if !settings.gatewayEnabled {
            gateway.stop()
            return
        }
        let port = UInt16(settings.gatewayPort)
        if gateway.isRunning, gateway.port == port { return }
        if gateway.isRunning { gateway.stop() }
        Task { [gateway] in
            await gateway.start(port: port)
        }
    }

    /// The speculative head the active engine runs with its stored tuning
    /// (DFlash2, MTP or none). Reading `tuningRevision` keeps the dependency
    /// alive for SwiftUI: views that show the mode refresh after a save.
    var speculativeMode: SpeculativeMode {
        _ = tuningRevision
        return EngineStore.shared.tuning(for: activeEngine).speculativeMode(for: activeEngine)
    }
}
