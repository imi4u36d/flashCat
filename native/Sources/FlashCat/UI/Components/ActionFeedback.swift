// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import Combine
import FlashCatCore
import SwiftUI

/// 一次动作的原位回执。
///
/// 刷新、保存、复制这类动作的结果本来就在读者手边（列表已经重扫、设置已经
/// 落盘、粘贴板已经换过内容），再浮一张带标题的卡片只是重复。控件把自己的
/// 图标换成结果图标、停一秒多再换回来，既说清了「这一下成功了」，也不占
/// 通知历史、不挡内容。
enum ActionFlash: Equatable {
    case success
    case warning
    case failure

    var symbol: String {
        switch self {
        case .success: return "checkmark"
        case .warning: return "exclamationmark"
        case .failure: return "xmark"
        }
    }

    var tint: Color {
        switch self {
        case .success: return DS.ok
        case .warning: return DS.warn
        case .failure: return DS.err
        }
    }

    var accessibilitySuffix: String {
        switch self {
        case .success: return "已成功"
        case .warning: return "需注意"
        case .failure: return "失败"
        }
    }
}

/// 控件持有的回执状态：`show` 之后按固定时长自己清空。
///
/// 只负责「现在该显示哪个结果图标」，不参与业务判断。视图侧拿它喂给
/// `ActionFlashIcon`（或在 `DSIconButton` / `CircleGlassButton` 上传 `flash:`）。
@MainActor
final class ActionFlashState: ObservableObject {
    @Published private(set) var value: ActionFlash?

    private var resetTask: Task<Void, Never>?

    /// - Parameter seconds: 结果图标停留时长。默认 1.4 秒：够读一眼，又不会
    ///   让下一次点击落在「还在显示对勾」的按钮上。
    func show(_ value: ActionFlash, seconds: Double = 1.4) {
        resetTask?.cancel()
        withAnimation(DS.Motion.snappy) { self.value = value }
        resetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            withAnimation(DS.Motion.snappy) { self?.value = nil }
        }
    }

    func succeed() { show(.success) }
    func warn() { show(.warning) }
    func fail() { show(.failure) }

    func clear() {
        resetTask?.cancel()
        resetTask = nil
        value = nil
    }
}

/// 原图标与结果图标叠在同一格里做交叉淡化 + 轻微缩放。
///
/// 尺寸只由 `size` 决定，两种图标共用同一格，控件不会被对勾撑宽。
struct ActionFlashIcon: View {
    var systemName: String
    var flash: ActionFlash?
    var size: CGFloat
    var baseColor: Color = DS.text2
    var weight: Font.Weight = .medium

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Image(systemName: systemName)
                .font(.system(size: size, weight: weight))
                .foregroundStyle(baseColor)
                .opacity(flash == nil ? 1 : 0)
                .accessibilityHidden(true)
            if let flash {
                Image(systemName: flash.symbol)
                    .font(.system(size: size, weight: .bold))
                    .foregroundStyle(flash.tint)
                    .transition(
                        .scale(scale: 0.72).combined(with: .opacity)
                    )
                    .accessibilityLabel(L10n.t(flash.accessibilitySuffix))
            }
        }
        .animation(reduceMotion ? nil : DS.Motion.snappy, value: flash)
    }
}

/// 文字按钮的回执：结果图标短暂顶替标题，按钮宽度不跳。
///
/// 设置页的「应用」、复制按钮这类窄按钮如果改成「标题 + 图标」并排，回执
/// 出现时会把整行顶宽；原位替换标题就不会。
struct ActionFlashLabel: View {
    var title: String
    var flash: ActionFlash?
    var size: CGFloat = 11

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Text(L10n.t(title))
                .opacity(flash == nil ? 1 : 0)
                .accessibilityHidden(flash != nil)
            if let flash {
                Image(systemName: flash.symbol)
                    .font(.system(size: size, weight: .bold))
                    .foregroundStyle(flash.tint)
                    .transition(.scale(scale: 0.7).combined(with: .opacity))
                    .accessibilityLabel(L10n.t(flash.accessibilitySuffix))
            }
        }
        .animation(reduceMotion ? nil : DS.Motion.snappy, value: flash)
    }
}
