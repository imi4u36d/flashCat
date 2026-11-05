import SwiftUI

/// macOS 26 Liquid Glass 的统一入口。
///
/// 所有需要原生玻璃材质的自定义控件都通过这里取材质，避免每个视图各写一份
/// `glassEffect` 参数。玻璃只用于导航层、浮层与控件；正文卡片仍然靠层级排版，
/// 不把内容本身也做成玻璃。
struct LiquidGlassSurface<S: Shape>: View {
    var shape: S
    var tint: Color? = nil
    var interactive: Bool = false

    var body: some View {
        shape
            .fill(.clear)
            .glassEffect(glass, in: shape)
    }

    private var glass: Glass {
        var glass: Glass = .regular
        if let tint {
            glass = glass.tint(tint)
        }
        if interactive {
            glass = glass.interactive()
        }
        return glass
    }
}

extension View {
    /// 在视图背后加一层原生 Liquid Glass。
    func liquidGlassSurface<S: Shape>(_ shape: S,
                                      tint: Color? = nil,
                                      interactive: Bool = false) -> some View {
        background {
            LiquidGlassSurface(shape: shape, tint: tint, interactive: interactive)
        }
    }
}

/// 玻璃分段控件。`embedded` 为 true 时不画自己的轨道，直接坐进外层玻璃胶囊。
struct GlassSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    var options: [(value: Value, label: String)]
    var embedded: Bool = false

    @Namespace private var pill
    @State private var segmentFrames: [Int: CGRect] = [:]
    @Environment(\.colorScheme) private var scheme

    private let space = "glass.segmented.space"

    private var selectionTint: Color {
        scheme == .dark ? Color.white.opacity(0.12) : Color.white.opacity(0.45)
    }

    private var rim: LinearGradient {
        LinearGradient(
            colors: [
                Color.white.opacity(scheme == .dark ? 0.80 : 0.95),
                Color.white.opacity(scheme == .dark ? 0.06 : 0.30),
                Color.white.opacity(scheme == .dark ? 0.45 : 0.75),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.element.value) { index, option in
                let active = selection == option.value
                Button {
                    select(option.value)
                } label: {
                    Text(option.label)
                        .font(.system(size: 12.5, weight: active ? .semibold : .regular))
                        .foregroundStyle(active ? Console.text : Console.secondary)
                        .padding(.horizontal, 11)
                        .frame(height: 28)
                        .background {
                            if active {
                                Capsule()
                                    .fill(.clear)
                                    .glassEffect(.regular
                                        .tint(selectionTint)
                                        .interactive(), in: Capsule())
                                    .overlay {
                                        Capsule().strokeBorder(rim, lineWidth: 0.9)
                                    }
                                    .shadow(color: .black.opacity(scheme == .dark ? 0.35 : 0.10),
                                            radius: 5, x: 0, y: 2)
                                    .matchedGeometryEffect(id: "glass.selection", in: pill)
                            }
                        }
                        .background {
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: SegmentFrameKey.self,
                                    value: [index: proxy.frame(in: .named(space))]
                                )
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plainHit)
            }
        }
        .padding(embedded ? 2 : 3)
        .background {
            if !embedded {
                Capsule().fill(Console.inset)
                    .overlay(Capsule().strokeBorder(Console.insetStroke, lineWidth: 0.8))
            }
        }
        .coordinateSpace(name: space)
        .onPreferenceChange(SegmentFrameKey.self) { segmentFrames = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
                .onChanged { value in
                    guard let hit = segmentFrames.first(where: { $0.value.contains(value.location) }),
                          options.indices.contains(hit.key) else { return }
                    select(options[hit.key].value)
                }
        )
        .animation(.smooth(duration: 0.20), value: selection)
    }

    private func select(_ value: Value) {
        guard value != selection else { return }
        withAnimation(.smooth(duration: 0.16)) { selection = value }
    }
}

private struct SegmentFrameKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]

    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

/// 一行玻璃胶囊：分段选项 + 分隔线 + 搜索框，合成一个整体。
struct GlassFilterBar<Value: Hashable>: View {
    @Binding var selection: Value
    var options: [(value: Value, label: String)]
    @Binding var query: String
    var placeholder: String
    var maxSearchWidth: CGFloat = 200

    @State private var searching = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            GlassSegmented(selection: $selection, options: options, embedded: true)

            if searching {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Console.tertiary)
                    TextField(placeholder, text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .focused($focused)
                        .onSubmit { collapseIfEmpty() }
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Console.tertiary)
                        }
                        .buttonStyle(.plainHit)
                    }
                }
                .padding(.leading, 2)
                .frame(width: maxSearchWidth)
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            } else {
                Button {
                    withAnimation(.smooth(duration: 0.20)) { searching = true }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Console.secondary)
                        .frame(width: 26, height: 26)
                        .contentShape(Circle())
                }
                .buttonStyle(.plainHit)
                .help(placeholder)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background {
            LiquidGlassSurface(shape: Capsule())
        }
        .animation(.smooth(duration: 0.22), value: searching)
        .onAppear { searching = !query.isEmpty }
        .onChange(of: query) { _, value in
            if !value.isEmpty, !searching {
                withAnimation(.smooth(duration: 0.20)) { searching = true }
            }
        }
        .onChange(of: searching) { _, value in
            guard value else { return }
            DispatchQueue.main.async { focused = true }
        }
        .onChange(of: focused) { _, value in
            if !value { collapseIfEmpty() }
        }
    }

    private func collapseIfEmpty() {
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        withAnimation(.smooth(duration: 0.20)) { searching = false }
    }
}
