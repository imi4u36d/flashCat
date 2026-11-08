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

/// 悬浮玻璃面板：导航列这类「浮在画布上」的整块容器使用。
///
/// 相比 `LiquidGlassSurface`，它额外补了三层在原生玻璃上做不出来的细节：
/// 一层极淡的半透明底色（区分深浅色）、1px 的折射边缘光和内外两圈柔和投影，
/// 让面板与右侧主视口之间形成明确的层次，而不是一块贴死的侧栏。
struct LiquidGlassPanel<Content: View>: View {
    var radius: CGFloat = 26
    @ViewBuilder var content: () -> Content

    @Environment(\.colorScheme) private var scheme

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }

    private var rim: LinearGradient {
        LinearGradient(
            colors: [
                Color.white.opacity(scheme == .dark ? 0.34 : 0.90),
                Color.white.opacity(scheme == .dark ? 0.05 : 0.12),
                Color.white.opacity(scheme == .dark ? 0.22 : 0.48),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var body: some View {
        content()
            .background {
                ZStack {
                    shape
                        .fill(.clear)
                        .glassEffect(.regular, in: shape)

                    // 极淡的白/黑罩色：日间提亮玻璃，夜间压暗，避免材质发灰。
                    shape.fill(
                        scheme == .dark
                            ? Color.black.opacity(0.14)
                            : Color.white.opacity(0.08)
                    )
                }
                // 投影只挂在玻璃底板这一层，避免文字和图标也被阴影描边。
                .compositingGroup()
                .shadow(color: .black.opacity(scheme == .dark ? 0.50 : 0.16),
                        radius: 30, x: 0, y: 16)
                .shadow(color: .black.opacity(scheme == .dark ? 0.28 : 0.06),
                        radius: 4, x: 0, y: 1)
            }
            .overlay {
                // 边缘高光 + 内侧一圈更细的折射线。
                shape.strokeBorder(rim, lineWidth: 1)
                shape.inset(by: 1)
                    .strokeBorder(Color.white.opacity(scheme == .dark ? 0.08 : 0.35),
                                  lineWidth: 0.6)
            }
    }
}

/// 弹层画布：日间纯白、夜间近黑。
///
/// 内容区必须保持不透明：整页半透明玻璃会削弱文字对比度，也让滚动时
/// 底层内容透上来。玻璃只留给标题栏控件、搜索框和卡片这类「浮在画布上」
/// 的元素，画布本身保持纯色。
struct SheetCanvas: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        (scheme == .dark ? Color(console: 0x100F15) : Color.white)
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }
}

extension View {
    /// 给弹层铺纯白画布，替代系统默认的偏灰奶白窗口底色。
    func sheetCanvas() -> some View {
        background { SheetCanvas() }
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
    static let defaultValue: [Int: CGRect] = [:]

    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

/// 一行筛选栏：原生玻璃分段控件 + 独立玻璃搜索按钮。
///
/// 分段部分直接复用 `NativeSegmented`，与设置页、模型广场保持同一套系统
/// Liquid Glass 外观（按住拖动时由 AppKit 绘制大块玻璃选中态）。
struct GlassFilterBar<Value: Hashable>: View {
    @Binding var selection: Value
    var options: [(value: Value, label: String)]
    @Binding var query: String
    var placeholder: String
    var maxSearchWidth: CGFloat = 200

    @State private var searching = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            // 与设置页、模型广场保持同一套原生分段控件，按住拖动时由系统
            // 绘制 macOS 27 的大块 Liquid Glass 选中态。
            NativeSegmented(selection: $selection, options: options)

            if searching {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Console.tertiary)
                    TextField(placeholder, text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .focused($focused)
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
                .padding(.horizontal, 10)
                .frame(width: maxSearchWidth, height: 34)
                .background { LiquidGlassSurface(shape: Capsule()) }
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            } else {
                Button {
                    withAnimation(.smooth(duration: 0.20)) { searching = true }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Console.secondary)
                        .frame(width: 34, height: 34)
                        .background { LiquidGlassSurface(shape: Circle(), interactive: true) }
                        .contentShape(Circle())
                }
                .buttonStyle(.plainHit)
                .help(placeholder)
            }
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
