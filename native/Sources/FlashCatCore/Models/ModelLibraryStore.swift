// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import FlashCatKit
import Foundation

/// 本机模型库的状态：扫盘得到的清单、公共目录里已落盘的仓库、以及「看的是哪个
/// 引擎的模型页」。
///
/// 命名避开 `ModelLibrary`——那是 FlashCatKit 里的值类型（模型条目/引擎判定），
/// 两者一个是状态一个是数据，混名会让人以为这里是它的缓存。
///
/// 这里只放**状态**，不放编排：什么时候重扫（下载完成、授权变更、引擎装/卸）
/// 由 AppState 决定，因为那些时刻还要同时通知引擎、换选中模型。store 只负责把
/// 结果摆好并按需发布；视图仍然只订阅 AppState（见 `AppState.modelLibraryBridge`）。
@MainActor
package final class ModelLibraryStore: ObservableObject {
    package init() {}
    /// 机器上能跑、且下载器认识的模型清单（`reloadModels()` 的产物）。
    @Published package var catalog = ModelCatalog()
    /// 公共目录里已落盘的仓库 id（模型广场标「已在本机」用）。
    @Published package var sharedRepos: [String] = []
    /// 本机已有的全部仓库：公共目录加各引擎自己的模型目录。比 `sharedRepos`
    /// 宽——引擎目录里手放的、或从引擎推荐里下的权重同样算「已经有了」，下载
    /// 弹窗据此把下载按钮换成「已下载」。跟着 `reloadModels` 走，不进两秒一次的
    /// 每帧都会读的热路径。
    @Published package var localModelRepos: [String] = []
    /// Which engine's model library the model page shows. Browsing is
    /// deliberately independent of the running engine, so an engine that is
    /// stopped — or that has no weights at all — can still be inspected,
    /// filled from the Hub and compared with the others.
    @Published package var libraryEngine: EngineID = .splash
    /// Set when a model is picked for an engine that is not running: the switch
    /// is a bigger step than a model change, so it asks first.
    @Published package var pendingLibraryUse: LibraryUseRequest?
    /// What this Mac should run, per engine; `nil` until the first launch has
    /// decided. Stored in `AppSettings`, so the model page's tags outlive a
    /// relaunch without touching the hardware again.
    @Published package var hardwareRecommendation: HardwareRecommendation?
    /// The first-run page is up. Only when nothing is installed yet and the
    /// question has not been answered before.
    @Published package var showsRecommendationPage = false
    /// Model to download as soon as the recommended engine's install finishes:
    /// the downloader refuses to run while the pack is missing.
    @Published package var pendingRecommendedDownload: (engine: EngineID, model: String)?
    /// Bumped whenever any engine's tuning is saved. `speculativeMode` reads it
    /// so a view showing the mode re-renders after the config page saves.
    @Published package var tuningRevision = 0
}
