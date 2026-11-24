// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import FlashCatCore
import FlashCatKit
import SwiftUI

// MARK: - Engine comparison matrix
//
// 选型参考表：格式、切换模式、投机解码、视觉与运行依赖并排。当前活跃引擎
// 整行高亮；窗口太窄时表格横向滚动，不把列挤成不可读的细条。

struct EngineMatrixCard: View {
    let installed: Set<EngineID>
    let active: EngineID?
    let running: Bool

    fileprivate enum Column {
        static let engine: CGFloat = 170
        static let formats: CGFloat = 110
        static let mode: CGFloat = 150
        static let speculation: CGFloat = 140
        static let vision: CGFloat = 100
        static let minWidth: CGFloat = 760
        static let rowHeight: CGFloat = 38
        static let headerHeight: CGFloat = 28
    }

    private var ids: [EngineID] { EngineCatalog.allIDs }

    private var tableHeight: CGFloat {
        let rows = CGFloat(ids.count)
        let dividers = max(0, rows - 1) + 1
        return Column.headerHeight + rows * Column.rowHeight + dividers + 2
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    title
                    Spacer(minLength: 8)
                    note
                }
                HStack(spacing: 8) {
                    title
                    Spacer(minLength: 0)
                }
            }

            GeometryReader { proxy in
                ScrollView(.horizontal) {
                    table
                        .frame(width: max(Column.minWidth, proxy.size.width))
                }
                .scrollIndicators(.never)
            }
            .frame(height: tableHeight)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .dsSurface(radius: DS.Radius.card)
    }

    private var title: some View {
        HStack(spacing: 8) {
            Text(L10n.t("引擎能力对比矩阵"))
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(DS.text)
                .lineLimit(1)
            Text(L10n.t("选型参考"))
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(DS.accent)
                .padding(.horizontal, 7)
                .frame(height: 18)
                .background(Capsule().fill(DS.accentSoft))
                .overlay(Capsule().strokeBorder(DS.accent.opacity(0.20), lineWidth: 1))
                .fixedSize()
        }
        .fixedSize()
    }

    private var note: some View {
        Text(L10n.t("高亮行表示当前活跃运行时"))
            .font(.system(size: 11))
            .foregroundStyle(DS.text3)
            .lineLimit(1)
            .fixedSize()
    }

    private var table: some View {
        VStack(spacing: 0) {
            headerRow
            DSDivider()
            ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                if index > 0 {
                    DSDivider().padding(.horizontal, 6)
                }
                EngineMatrixRow(
                    id: id,
                    installed: installed.contains(id),
                    current: id == active,
                    running: running && id == active)
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            Text(L10n.t("引擎"))
                .frame(width: Column.engine, alignment: .leading)
            Text(L10n.t("模型格式"))
                .frame(width: Column.formats, alignment: .leading)
            Text(L10n.t("并发 / 切换模式"))
                .frame(width: Column.mode, alignment: .leading)
            Text(L10n.t("投机解码支持"))
                .frame(width: Column.speculation, alignment: .leading)
            Text(L10n.t("多模态视觉"))
                .frame(width: Column.vision, alignment: .leading)
            Text(L10n.t("运行时依赖"))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(DS.text3)
        .padding(.horizontal, 10)
        .frame(height: Column.headerHeight)
    }
}

private struct EngineMatrixRow: View {
    let id: EngineID
    let installed: Bool
    let current: Bool
    let running: Bool

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var dotColor: Color {
        if current { return running ? DS.ok : DS.warn }
        return installed ? engineAccent(id) : DS.text4
    }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 7) {
                DSStatusDot(color: dotColor, live: running, size: 6)
                Text(id.displayName)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(DS.text)
                    .lineLimit(1)
                if current {
                    Text(L10n.t("当前"))
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(running ? DS.ok : DS.warn)
                        .padding(.horizontal, 5)
                        .frame(height: 16)
                        .background(
                            Capsule().fill((running ? DS.ok : DS.warn).opacity(0.12)))
                        .fixedSize()
                }
            }
            .frame(width: EngineMatrixCard.Column.engine, alignment: .leading)

            HStack(spacing: 4) {
                ForEach(id.modelFormats) { format in
                    EngineFormatBadge(format: format)
                }
            }
            .frame(width: EngineMatrixCard.Column.formats, alignment: .leading)

            Text(id.switchModeText)
                .font(.system(size: 12))
                .foregroundStyle(DS.text2)
                .lineLimit(1)
                .frame(width: EngineMatrixCard.Column.mode, alignment: .leading)

            Text(verbatim: id.speculationLabel)
                .font(DS.Font.mono(11.5))
                .foregroundStyle(DS.text)
                .lineLimit(1)
                .frame(width: EngineMatrixCard.Column.speculation, alignment: .leading)

            Text(id.visionText)
                .font(.system(size: 12, weight: id.supportsVision ? .medium : .regular))
                .foregroundStyle(id.supportsVision ? DS.ok : DS.text4)
                .lineLimit(1)
                .frame(width: EngineMatrixCard.Column.vision, alignment: .leading)

            Text(id.runtimeDependencyText)
                .font(.system(size: 12))
                .foregroundStyle(DS.text3)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .frame(height: EngineMatrixCard.Column.rowHeight)
        .background(
            current ? DS.accentSoft : (hovering ? DS.hover : .clear),
            in: DS.rect(8))
        .onHover { inside in
            if reduceMotion {
                hovering = inside
            } else {
                withAnimation(DS.Motion.snappy) { hovering = inside }
            }
        }
    }
}

private struct EngineFormatBadge: View {
    let format: EngineModelFormat

    var body: some View {
        Text(verbatim: format.label)
            .font(DS.Font.mono(10, weight: .semibold))
            .foregroundStyle(format.tint)
            .padding(.horizontal, 5)
            .frame(height: 18)
            .background(DS.rect(5).fill(format.tint.opacity(0.10)))
            .overlay(DS.rect(5).strokeBorder(format.tint.opacity(0.20), lineWidth: 1))
            .fixedSize()
    }
}
