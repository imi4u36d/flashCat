// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import FlashCatCore
import FlashCatKit

/// 输入卡右下角的两个切换器（都在发送按钮左边）：模型切换、思考等级。
enum ChatComposerControls {
    /// 当前模型要不要露出思考等级。
    ///
    /// 图像 / 视频模型的请求里没有推理等级这回事，露出控件只会让人以为调得动，
    /// 所以只跟纯对话模型走。引擎没报能力（`capabilities` 为空）按对话模型处理，
    /// 和 `EngineModel.supportsChat` 的兜底一致；还没选模型时也先留着。
    ///
    /// 模型切换不能跟着模型类型一起消失：选中图像 / 视频模型时它要是也没了，
    /// 对话页就再没有切回文本模型的入口（设置页之外没有第二处能换模型）。
    static func showsThinkingLevel(for model: EngineModel?) -> Bool {
        guard let model else { return true }
        return model.supportsChat && !model.supportsImage && !model.supportsVideo
    }
}
