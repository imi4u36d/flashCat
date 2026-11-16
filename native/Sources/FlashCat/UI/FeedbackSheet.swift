// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import SwiftUI

/// 侧栏反馈入口的集中配置。
enum FeedbackConfig {
    static let qqGroupName = "flashCat 用户群"
    static let qqGroupNumber = "931794134"
}

/// 反馈弹窗：展示 QQ 群号并支持一键复制。
struct FeedbackSheet: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            DSDivider()
            content
            DSDivider()
            footer
        }
        .frame(width: 440)
        .sheetCanvas()
    }

    private var header: some View {
        HStack(spacing: 10) {
            IconTile(symbol: "bubble.left.and.bubble.right", color: DS.info, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text("反馈与交流")
                    .font(DS.Font.lg.weight(.semibold))
                    .foregroundStyle(DS.text)
                Text("加入 QQ 群，和其他 flashCat 用户一起聊")
                    .font(DS.Font.xs)
                    .foregroundStyle(DS.text3)
            }
            Spacer(minLength: 8)
            DSIconButton(systemName: "xmark", help: "关闭") { dismiss() }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var content: some View {
        VStack(spacing: 16) {
            qqMark

            VStack(spacing: 6) {
                Text(FeedbackConfig.qqGroupName)
                    .font(DS.Font.lg.weight(.semibold))
                    .foregroundStyle(DS.text)
                Text("使用中遇到问题、想提新功能，或者只是想聊聊本地模型，都欢迎进群。")
                    .font(DS.Font.xs)
                    .foregroundStyle(DS.text3)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }

            groupNumberCard
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 24)
    }

    private var qqMark: some View {
        ZStack {
            DS.rect(DS.Radius.lg)
                .fill(DS.info.opacity(0.12))
            Image(systemName: "person.2.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(DS.info)
        }
        .frame(width: 56, height: 56)
        .overlay(
            DS.rect(DS.Radius.lg)
                .strokeBorder(DS.info.opacity(0.28), lineWidth: 1)
        )
    }

    private var groupNumberCard: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("QQ 群号")
                    .font(DS.Font.xs.weight(.medium))
                    .foregroundStyle(DS.text3)
                Text(FeedbackConfig.qqGroupNumber)
                    .font(DS.Font.mono(18, weight: .bold))
                    .foregroundStyle(DS.text)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            Button {
                state.copy(FeedbackConfig.qqGroupNumber, label: "已复制 QQ 群号")
            } label: {
                Label("复制", systemImage: "doc.on.doc")
            }
            .buttonStyle(.ds(.secondary, size: .small))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background {
            DS.rect(DS.Radius.md)
                .fill(DS.bg)
        }
        .overlay {
            DS.rect(DS.Radius.md)
                .strokeBorder(DS.line, lineWidth: 1)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "lightbulb")
                .font(.system(size: 10, weight: .medium))
            Text("反馈时附上引擎、模型名和日志片段，能更快定位问题。")
                .font(DS.Font.xs)
        }
        .foregroundStyle(DS.text3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }
}
