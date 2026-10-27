import SwiftUI
import FlashCatKit

/// Compact engine picker. Shown in the sidebar card whenever more than one
/// runtime pack is installed; splash is always present.
struct EngineSwitcherRow: View {
    @ObservedObject var state: AppState

    var body: some View {
        HStack(spacing: 3) {
            ForEach(state.availableEngines, id: \.self) { id in
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
        return Button {
            state.switchEngine(id)
        } label: {
            Text(id.displayName)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(active ? Native.pillText : Native.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(active ? Native.accent : .clear)
                }
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(active ? "当前引擎" : "切换到 \(id.displayName)")
        .accessibilityLabel("切换到 \(id.displayName)")
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }
}
