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
            Hairline()
            content
            Hairline()
            footer
        }
        .frame(width: 440)
    }

    private var header: some View {
        HStack(spacing: 10) {
            ArcadeIcon(symbol: "bubble.left.and.bubble.right",
                       colors: [Color(hex: 0x12B7F5), Native.blue],
                       size: 28,
                       glyphScale: 0.46,
                       glow: false)
            VStack(alignment: .leading, spacing: 2) {
                Text("反馈与交流")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Native.label)
                Text("加入 QQ 群，和其他 flashCat 用户一起聊")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Native.tertiary)
            }
            Spacer(minLength: 8)
            IconAction(systemName: "xmark", help: "关闭") { dismiss() }
        }
        .padding(.horizontal, Native.pagePadding)
        .padding(.vertical, 14)
    }

    private var content: some View {
        VStack(spacing: 16) {
            qqMark

            VStack(spacing: 6) {
                Text(FeedbackConfig.qqGroupName)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Native.label)
                Text("使用中遇到问题、想提新功能，或者只是想聊聊本地模型，都欢迎进群。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Native.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }

            groupNumberCard
        }
        .padding(.horizontal, Native.pagePadding)
        .padding(.vertical, 24)
    }

    private var qqMark: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(
                    LinearGradient(colors: [Color(hex: 0x12B7F5), Color(hex: 0x0A84C8)],
                                   startPoint: .topLeading,
                                   endPoint: .bottomTrailing)
                )
            Image(systemName: "person.2.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.22), radius: 2, x: 0, y: 1)
        }
        .frame(width: 64, height: 64)
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.white.opacity(0.32), lineWidth: 0.8)
        )
        .shadow(color: Color(hex: 0x12B7F5).opacity(0.28), radius: 12, x: 0, y: 6)
    }

    private var groupNumberCard: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("QQ 群号")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Native.tertiary)
                Text(FeedbackConfig.qqGroupNumber)
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .foregroundStyle(Native.label)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            Button {
                state.copy(FeedbackConfig.qqGroupNumber, label: "已复制 QQ 群号")
            } label: {
                Label("复制", systemImage: "doc.on.doc")
            }
            .buttonStyle(ArcadePillStyle(tone: .glass, compact: true))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: Native.radiusTile, style: .continuous)
                .fill(Native.recess)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Native.radiusTile, style: .continuous)
                .stroke(Native.hairline, lineWidth: 1)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "lightbulb")
                .font(.system(size: 10, weight: .medium))
            Text("反馈时附上引擎、模型名和日志片段，能更快定位问题。")
                .font(.system(size: 10.5))
        }
        .foregroundStyle(Native.tertiary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Native.pagePadding)
        .padding(.vertical, 12)
    }
}
