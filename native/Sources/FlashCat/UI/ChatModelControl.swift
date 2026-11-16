import SwiftUI
import FlashCatKit

/// 输入框里的「模型 + 思考强度」胶囊：点开是 Liquid Glass 浮层，
/// 上方是当前思考等级的汉字，下面用离散滑杆在四档之间切换。
struct ChatModelThinkingControl: View {
    @ObservedObject var state: AppState
    @ObservedObject var chat: ChatStore

    @State private var open = false

    /// 观察 UserDefaults 而不是只读 `AppSettings`：设置页和这里各有一份
    /// 思考等级控件，任一处改动都要让另一处立即重绘。
    @AppStorage("thinkingMode") private var storedThinkingMode = ThinkingMode.automatic.rawValue
    @AppStorage("reasoningEffort") private var storedEffort = ReasoningEffort.medium.rawValue

    private var thinkingMode: ThinkingMode {
        ThinkingMode(rawValue: storedThinkingMode) ?? .automatic
    }

    private var effort: ReasoningEffort { ReasoningEffort.stored(storedEffort) }

    var body: some View {
        Button {
            open.toggle()
        } label: {
            DSMenuTriggerLabel(title: modelName, badge: thinkingGlyph, size: .regular)
        }
        .buttonStyle(.ds(.secondary, size: .regular))
        .disabled(chat.generating)
        .popover(isPresented: $open, arrowEdge: .top) {
            ChatModelThinkingPopover(state: state, chat: chat)
        }
    }

    private var modelName: String {
        L10n.t(state.selectedModel.isEmpty ? "选择模型" : state.shortModelName(state.selectedModel))
    }

    private var thinkingGlyph: String {
        switch thinkingMode {
        case .automatic: return "自动"
        case .off: return "关"
        case .on: return effort.label
        }
    }
}

private struct ChatModelThinkingPopover: View {
    @ObservedObject var state: AppState
    @ObservedObject var chat: ChatStore

    @State private var showsModels = false

    @AppStorage("thinkingMode") private var storedThinkingMode = ThinkingMode.automatic.rawValue
    @AppStorage("reasoningEffort") private var storedEffort = ReasoningEffort.medium.rawValue

    private var tint: Color { DS.accent }

    private var thinkingMode: ThinkingMode {
        ThinkingMode(rawValue: storedThinkingMode) ?? .automatic
    }

    private var effort: ReasoningEffort { ReasoningEffort.stored(storedEffort) }

    var body: some View {
        Group {
            if showsModels {
                modelList
                    .transition(.opacity)
            } else {
                thinkingPanel
                    .transition(.opacity)
            }
        }
        .frame(width: 300)
        .dsPopoverSurface()
        .animation(DS.Motion.smooth, value: showsModels)
    }

    // MARK: Thinking panel

    private var thinkingPanel: some View {
        VStack(spacing: 12) {
            Button {
                showsModels = true
            } label: {
                HStack(spacing: 4) {
                    Text(modelName)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(DS.text2)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(DS.text3)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plainHit)
            .disabled(chat.generating)

            ThinkingLevelSlider(effort: effortBinding, efforts: availableEfforts, tint: tint)

            DSSegmented(selection: modeBinding,
                        options: ThinkingMode.allCases.map { ($0, $0.label) })
        }
        .padding(14)
    }

    private var modeBinding: Binding<ThinkingMode> {
        Binding(
            get: { thinkingMode },
            set: { mode in
                state.settings.setThinkingMode(mode)
                storedThinkingMode = mode.rawValue
            }
        )
    }

    private var effortBinding: Binding<ReasoningEffort> {
        Binding(
            get: { effort },
            set: {
                state.settings.setReasoningEffort($0)
                state.settings.setThinkingMode(.on)
                storedEffort = $0.rawValue
                storedThinkingMode = ThinkingMode.on.rawValue
            }
        )
    }

    private var modelName: String {
        L10n.t(state.selectedModel.isEmpty ? "选择模型" : state.shortModelName(state.selectedModel))
    }

    /// 引擎会报出当前模型支持的思考等级；没报就退回内置全集。
    private var availableEfforts: [ReasoningEffort] {
        guard let tokens = state.controller?.status?.reasoningEfforts, !tokens.isEmpty else {
            return ReasoningEffort.allCases
        }
        let mapped = tokens.compactMap { token in
            ReasoningEffort.allCases.first { $0.token == token.lowercased() }
        }
        return mapped.isEmpty ? ReasoningEffort.allCases : mapped
    }

    // MARK: Model list

    private var modelList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    showsModels = false
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(DS.text2)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plainHit)
                Text("选择模型")
                    .font(DS.Font.sm.weight(.medium))
                    .foregroundStyle(DS.text)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 4)

            DSDivider()

            ModelPickerPopover(state: state) { showsModels = false }
        }
    }
}

/// 思考级别滑杆：等级文字直接排在轨道上，选中的一档连同整格被强调色填满。
private struct ThinkingLevelSlider: View {
    @Binding var effort: ReasoningEffort
    var efforts: [ReasoningEffort]
    var tint: Color

    private let trackHeight: CGFloat = 30
    private var count: Int { max(items.count, 1) }

    private var items: [ReasoningEffort] {
        efforts.isEmpty ? ReasoningEffort.allCases : efforts
    }

    private var activeIndex: Int {
        max(items.firstIndex(of: effort) ?? 0, 0)
    }

    var body: some View {
        GeometryReader { proxy in
            let cell = proxy.size.width / CGFloat(count)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.adaptiveOverlay(0.05))

                Capsule()
                    .fill(tint)
                    .frame(width: cell * CGFloat(activeIndex + 1))

                HStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element) { index, item in
                        let active = item == effort
                        let filled = index <= activeIndex
                        Text(item.label)
                            .font(.system(size: 11, weight: active ? .semibold : (filled ? .medium : .regular)))
                            .foregroundStyle(filled ? Color.white : DS.text2)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(DS.Motion.smooth) { effort = item }
                            }
                            .accessibilityLabel(item.label)
                    }
                }
            }
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(DS.line, lineWidth: 1))
            .frame(height: trackHeight)
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        select(at: value.location.x, cell: cell)
                    }
            )
            .animation(DS.Motion.smooth, value: effort)
        }
        .frame(height: trackHeight)
    }

    private func select(at x: CGFloat, cell: CGFloat) {
        guard cell > 0 else { return }
        let index = min(max(Int(x / cell), 0), count - 1)
        let next = items[index]
        guard next != effort else { return }
        effort = next
    }
}
