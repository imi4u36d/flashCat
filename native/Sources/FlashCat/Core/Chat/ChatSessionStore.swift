// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import Foundation

/// 对话页自己的会话状态：待删 / 待改名线程，以及图像工具的开关。
///
/// 消息/线程列表在 `ChatStore` 里（那是上一轮抽的），这里放的是**界面会话**：
/// 还没被用户确认的删除与改名、以及「图像工具用哪个模型、画完留不留显存」。
/// 图像工具虽然落在对话页，但它的开关是用户设置，所以 setter 顺手写盘
/// （`didSet` 里做），而不是等某个读取点去补写。
///
/// 草稿在单独的 `ChatDraftStore` 里，刻意不桥回 AppState：它每敲一个字都会
/// 发布，桥回来会让整个控制台壳层跟着逐字重绘。这个 store 仍然桥回 AppState，
/// 因为壳层要弹删除 / 改名确认。
@MainActor
final class ChatSessionStore: ObservableObject {
    /// 侧栏与「最近对话」弹层共用的待删线程：删除会重写整份历史文件，删掉就
    /// 找不回来，所以两个入口都只挂起这一条，等壳层弹完确认再落盘。
    @Published var pendingThreadDelete: ChatThread?
    /// 待改名的线程。壳层统一弹输入框；侧栏与对话页标题菜单都只挂起这一条。
    @Published var pendingThreadRename: ChatThread?
    @Published var imageToolEnabled = ImageToolSettings.enabled {
        didSet { ImageToolSettings.setEnabled(imageToolEnabled) }
    }
    /// 工具借用的图像模型。空串表示用当前引擎里第一个能出图的模型。
    @Published var imageToolModelID = ImageToolSettings.modelID {
        didSet { ImageToolSettings.setModelID(imageToolModelID) }
    }
    /// 画完图后图像模型是否留在显存里。开着时下一轮生图直接复用权重，
    /// 代价是对话模型和图像模型同时占内存；设置页可以关掉。
    @Published var imageToolResident = ImageToolSettings.resident {
        didSet { ImageToolSettings.setResident(imageToolResident) }
    }
}
