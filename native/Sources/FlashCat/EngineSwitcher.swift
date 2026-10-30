import SwiftUI
import FlashCatKit

/// Compact engine picker in the sidebar card. Every known engine gets a chip:
/// installed ones switch with one click, missing ones open the launch page,
/// which doubles as the download prompt (latest version only, one-click
/// install). Always visible — with a single engine it doubles as a map of what
/// else flashCat can run.
struct EngineSwitcherRow: View {
    @ObservedObject var state: AppState

    private var installed: Set<EngineID> { Set(state.availableEngines) }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(EngineID.allCases, id: \.self) { id in
                chip(id)
            }
            Spacer(minLength: 0)
        }
        .padding(3)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Native.overlay(0.045))
        }
    }

    private func chip(_ id: EngineID) -> some View {
        let active = state.activeEngine == id
        let isInstalled = installed.contains(id)
        return Button {
            if isInstalled {
                state.switchEngine(id)
            } else {
                // 没装就打开启动页当下载提示：那里只列最新版本，装完自动接管。
                state.showsLaunchPage = true
            }
        } label: {
            HStack(spacing: 3) {
                Text(id.displayName)
                if !isInstalled {
                    Image(systemName: "plus")
                        .font(.system(size: 7.5, weight: .bold))
                }
            }
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(chipTint(active: active, installed: isInstalled))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background {
                // 三个芯片都是按钮：已装的实心高亮，未装的浅底 + 虚线描边。
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(active ? Native.accent
                                  : (isInstalled ? Color.clear : Native.overlay(0.05)))
            }
            .overlay {
                if !isInstalled {
                    // Dashed outline reads as "slot for something not here yet".
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Native.overlay(0.18),
                                      style: StrokeStyle(lineWidth: 0.8, dash: [2.5, 2]))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(chipHelp(id, active: active, installed: isInstalled))
        .accessibilityLabel(accessibility(id, active: active, installed: isInstalled))
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }

    private func chipTint(active: Bool, installed: Bool) -> Color {
        if active { return Native.pillText }
        return installed ? Native.secondary : Native.tertiary
    }

    private func version(of id: EngineID) -> String? {
        state.engines?.controller(id)?.installation.version
    }

    private func chipHelp(_ id: EngineID, active: Bool, installed: Bool) -> String {
        if active, let version = version(of: id) {
            return "当前引擎 \(id.displayName) \(version)"
        }
        if installed {
            let suffix = version(of: id).map { " \($0)" } ?? ""
            return "切换到 \(id.displayName)\(suffix)"
        }
        return "\(id.displayName) 未安装 · 点击前往安装"
    }

    private func accessibility(_ id: EngineID, active: Bool, installed: Bool) -> String {
        if installed {
            return active ? "当前引擎 \(id.displayName)" : "切换到 \(id.displayName)"
        }
        return "安装 \(id.displayName)"
    }
}
