// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import FlashCatCore
import FlashCatKit
import SwiftUI

// MARK: - Blocking notice

/// 阻塞通知出口：只有错误与「现在不能做」的警告会浮在窗口左下角。
/// 成功 / 信息回执一律走控件原位图标（`ActionFlash`），不再占用这里。
struct FloatingNoticeToast: View {
    let notice: IslandNotice
    var dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: notice.kind.symbol)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 20, height: 20)
                .background(DS.rect(DS.Radius.sm).fill(color.opacity(0.14)))
            VStack(alignment: .leading, spacing: 2) {
                Text(notice.title)
                    .font(DS.Font.prose(11.5, weight: .semibold))
                    .foregroundStyle(DS.text)
                Text(notice.message)
                    .font(DS.Font.prose(11.5))
                    .foregroundStyle(DS.text2)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(DS.text3)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.t("关闭通知"))
        }
        .padding(12)
        .frame(width: 340, alignment: .leading)
        .dsFloating(radius: DS.Radius.lg)
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
    }

    private var color: Color {
        switch notice.kind {
        case .info: return DS.info
        case .success: return DS.ok
        case .warning: return DS.warn
        case .error: return DS.err
        }
    }
}

// MARK: - Engine mark

/// 引擎图标：优先用 pack 里的上游 app icon，没有资产时退回引擎强调色的字母块。
struct EngineMark: View {
    let id: EngineID
    var size: CGFloat = 20
    var ring: Color? = nil

    var body: some View {
        Group {
            if let asset = engineArtwork(id), let image = BrandGlyph.artwork(named: asset) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
            } else {
                Text(String(id.displayName.prefix(1)).uppercased())
                    .font(.system(size: size * 0.46, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(
                        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                            .fill(engineAccent(id)))
            }
        }
        .frame(width: size, height: size)
        .overlay {
            if let ring {
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .strokeBorder(ring.opacity(0.45), lineWidth: 1)
            }
        }
        .accessibilityHidden(true)
    }
}
