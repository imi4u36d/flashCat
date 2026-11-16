// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import FlashCatKit

/// 网关打点类现在住在 `FlashCatKit`（`Meter/GatewaySessionMeter.swift`）。
///
/// 拆分的理由：这套数学（指数遗忘速率、TTFT、cache-hit、会话生命周期、
/// `overview()` 快照）只有 Foundation 依赖，但原先住在 App target，所以 CLI 与
/// Kit 里的聚合代码都拿不到，只能各自重写一遍口径——`status --json` 的会话视图
/// 就是受害者。搬到 Kit 之后只有一份实现。
///
/// App 侧保留这个名字，是因为 `UI/OverviewPage.swift`（`GatewayMeter.SessionSnapshot`）、
/// `MetricsStore.swift`（`GatewayMeter.Overview`）与 `AppState.swift` 都按
/// `GatewayMeter` 取值。别名让它们一行都不用改，也让以后想回到 facade 类时
/// 不用再动调用点：把这一行换成 `final class GatewayMeter: GatewaySessionMeter {}`
/// 之类即可。
typealias GatewayMeter = GatewaySessionMeter
