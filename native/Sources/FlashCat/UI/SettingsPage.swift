import SwiftUI
import AppKit
import FlashCatKit

/// 设置页：按 WebUI 版式——左右两列卡片，行内即改即生效。
struct SettingsPage: View {
    @ObservedObject var state: AppState
    @ObservedObject private var background = BackgroundSettings.shared
    @State private var ports: [String: String] = [:]
    @State private var gatewayPort = ""
    @State private var controlPort = ""
    @State private var cachePath = ""
    /// 思考设置走 `@AppStorage` 而不是本地镜像：`AppSettings` 不是
    /// ObservableObject，只写 UserDefaults 不会触发 SwiftUI 重新求值。
    /// 观察这两个键之后，聊天浮层滑杆与这里的分段控件才能互相同步。
    @AppStorage("thinkingMode") private var storedThinkingMode = ThinkingMode.automatic.rawValue
    @AppStorage("reasoningEffort") private var storedReasoningEffort = ReasoningEffort.medium.rawValue

    private var thinkingMode: ThinkingMode {
        ThinkingMode(rawValue: storedThinkingMode) ?? .automatic
    }

    private var reasoningEffort: ReasoningEffort {
        ReasoningEffort.stored(storedReasoningEffort)
    }

    var body: some View {
        GeometryReader { proxy in
            let wide = proxy.size.width >= Console.compactContentWidth
            ScrollView {
                // 窄窗口下两列会互相挤压，改为单列依次排布并交给滚动承载。
                if !wide {
                    VStack(alignment: .leading, spacing: 18) {
                        leftColumn(wide: false)
                        rightColumn(wide: false)
                    }
                    .padding(.horizontal, Console.contentPadding)
                    .padding(.top, Console.contentTopInset)
                } else {
                    HStack(alignment: .top, spacing: 18) {
                        leftColumn(wide: true)
                        rightColumn(wide: true)
                    }
                    .padding(.horizontal, Console.contentPadding)
                    .padding(.top, Console.contentTopInset)
                }
            }
            .scrollIndicators(.never)
        }
        // 设置页没有独立标题栏，滚动视口的下沿同样收在侧栏底边上。
        .padding(.bottom, Console.contentBottomInset)
        .onAppear(perform: load)
        .onChange(of: state.activeEngine) { _, _ in load() }
    }

    private func leftColumn(wide: Bool) -> some View {
        VStack(spacing: 18) {
            appearanceCard(wide: wide)
            backgroundCard
            launchCard
            portsCard
            cacheCard
        }
    }

    private func rightColumn(wide: Bool) -> some View {
        VStack(spacing: 18) {
            gatewayCard
            cliCard
            thinkingCard(wide: wide)
            imageCard
            infoCard
        }
    }

    private func load() {
        var values: [String: String] = [:]
        for id in EngineCatalog.allIDs {
            values[id.rawValue] = String(EngineStore.shared.configuration(for: id).port ?? id.defaultPort)
        }
        ports = values
        gatewayPort = String(state.settings.gatewayPort)
        controlPort = String(state.settings.controlPort)
        cachePath = state.settings.hfCache
    }

    // MARK: Left column

    private func appearanceCard(wide: Bool) -> some View {
        SettingsCard {
            SettingsRow(title: "外观", detail: "跟随系统或固定外观") {
                NativeSegmented(selection: Binding(
                    get: { state.theme.mode },
                    set: { state.theme.set($0) }),
                    options: AppAppearance.allCases.map { ($0, $0.label) })
                    // 宽版式里把宽度交给标签：不参与行内剩余空间的分配，
                    // 切换选中项时才不会把整行挤得一宽一窄。窄版式留出压缩
                    // 余地，免得控件把文字列挤出卡片。
                    .fixedSizeWhen(wide)
            }
        }
    }

    private var backgroundCard: some View {
        SettingsCard {
            SettingsRow(title: "自定义背景",
                        detail: background.isEnabled ? "使用自定义图片作为画布背景" : "选择一张图片作为画布背景") {
                HStack(spacing: 8) {
                    if background.isEnabled {
                        if let image = background.image {
                            Image(nsImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 32, height: 32)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(Console.insetStroke, lineWidth: 0.8)
                                }
                        }
                        Button("更换") { background.chooseImage() }
                            .buttonStyle(.consoleSoft)
                            .fixedSize()
                        Button("移除") { background.clear() }
                            .buttonStyle(.consoleDanger)
                            .fixedSize()
                    } else {
                        Button("选择图片") { background.chooseImage() }
                            .buttonStyle(.consoleSecondary)
                            .fixedSize()
                    }
                }
            }
            Divider().overlay(Console.insetStroke)
            SettingsRow(title: "界面透明度",
                        detail: background.isEnabled
                            ? "数值越高图片越清晰；会自动柔化以保证可读性"
                            : "数值越高越透出桌面；会自动柔化以保证可读性") {
                HStack(spacing: 10) {
                    Slider(value: $background.opacity, in: 0...1)
                        .frame(width: 150)
                        .tint(Console.accent)
                    Text(verbatim: background.opacity.formatted(.percent.precision(.fractionLength(0))))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Console.tertiary)
                        .frame(width: 36, alignment: .trailing)
                }
            }
            Divider().overlay(Console.insetStroke)
            SettingsRow(title: "背景模糊",
                        detail: blurDetail) {
                HStack(spacing: 10) {
                    Slider(value: $background.blur, in: 0...40)
                        .frame(width: 150)
                        .tint(Console.accent)
                    Text(background.blur < 0.5 ? "关闭" : "\(Int(background.blur.rounded())) pt")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Console.tertiary)
                        .frame(width: 36, alignment: .trailing)
                }
                // 没有图片、透明度又是 0 时整窗不透明，模糊确实没有任何可见效果。
                // 以前这里照常可拖，拖完什么都没发生，看起来就像滑杆坏了。
                .disabled(frostIsInert)
                .opacity(frostIsInert ? 0.45 : 1)
            }
        }
    }

    /// 没有自定义图片、且 APP 透明度为 0：窗口完全不透明，桌面没露出来，
    /// 模糊再怎么调也看不见。
    private var frostIsInert: Bool {
        !background.isEnabled && background.opacity <= 0.001
    }

    private var blurDetail: String {
        if frostIsInert { return "先把界面透明度调高，桌面露出来之后模糊才可见" }
        return background.isEnabled
            ? "数值越高背景越柔和，文字越清晰"
            : "数值越高桌面越柔和，文字越清晰"
    }

    private var launchCard: some View {
        SettingsCard {
            SettingsRow(title: "登录时启动", detail: "加入 macOS 登录项") {
                Toggle("", isOn: Binding(
                    get: { state.settings.launchAtLogin },
                    set: { value in
                        state.settings.setLaunchAtLogin(value)
                        LoginItem.set(enabled: value)
                    }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .tint(Console.accent)
            }
            Divider().overlay(Console.insetStroke)
            SettingsRow(title: "随应用启动引擎", detail: "打开应用时拉起默认引擎") {
                Toggle("", isOn: Binding(
                    get: { state.settings.autoStart },
                    set: { state.settings.setAutoStart($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .tint(Console.accent)
            }
        }
    }

    private var portsCard: some View {
        SettingsCard {
            SettingsRow(title: "引擎端口", detail: "各引擎固定起始端口，互不抢占", trailingTop: true) {
                EmptyView()
            }
            ForEach(EngineCatalog.allIDs, id: \.self) { id in
                HStack(spacing: 10) {
                    LetterTile(letter: String(id.displayName.prefix(1)).uppercased(),
                               color: engineAccent(id), size: 26)
                    Text(id.displayName)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Console.text)
                        .frame(width: 84, alignment: .leading)
                    Spacer(minLength: 0)
                    portField(id)
                }
                .padding(.horizontal, 20)
                .frame(height: 48)
                if id != EngineCatalog.allIDs.last {
                    Divider().overlay(Console.insetStroke).padding(.leading, 56)
                }
            }
        }
    }

    private func portField(_ id: EngineID) -> some View {
        HStack(spacing: 4) {
            Text(":")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Console.tertiary)
            TextField("端口", text: Binding(
                get: { ports[id.rawValue] ?? "" },
                set: { ports[id.rawValue] = $0 }))
                .textFieldStyle(.plain)
                .font(.system(size: 11.5, design: .monospaced))
                .frame(width: 54)
            VStack(spacing: 0) {
                Button { stepPort(id, by: 1) } label: {
                    Image(systemName: "chevron.up").font(.system(size: 7, weight: .bold))
                }
                .buttonStyle(.plainHit)
                Button { stepPort(id, by: -1) } label: {
                    Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
                }
                .buttonStyle(.plainHit)
            }
            .foregroundStyle(Console.tertiary)
            // 输入框没有回车提交：改完端口点这个按钮才生效。
            Button { applyPort(id) } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Console.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plainHit)
            .help(L10n.t("应用"))
            .accessibilityLabel(L10n.t("应用"))
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Console.inset))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Console.insetStroke, lineWidth: 0.8))
    }

    private func stepPort(_ id: EngineID, by delta: Int) {
        let current = Int(ports[id.rawValue] ?? "") ?? id.defaultPort
        ports[id.rawValue] = String(min(max(current + delta, 1024), 65535))
        applyPort(id)
    }

    private func applyPort(_ id: EngineID) {
        guard let port = Int(ports[id.rawValue] ?? ""), (1024...65535).contains(port) else { return }
        state.switchEnginePort(id, port: port)
    }

    /// 网关 / 控制端口的输入胶囊。应用按钮放在胶囊外面：它是 32 pt 高的
    /// 玻璃胶囊，塞进 28 pt 的输入框会上下溢出，还会在右端留下一圈
    /// 「胶囊套胶囊」的毛边。缓存那一行也是「输入框 + 按钮」的排法。
    private func portInput(_ text: Binding<String>, placeholder: String) -> some View {
        HStack(spacing: 4) {
            Text(":")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Console.tertiary)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5, design: .monospaced))
                .frame(width: 54)
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Console.inset))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Console.insetStroke, lineWidth: 0.8)
        }
    }

    private var cacheCard: some View {
        SettingsCard {
            SettingsRow(title: "下载缓存", detail: "Hugging Face 缓存目录，留空用默认") {
                HStack(spacing: 8) {
                    TextField("默认使用 HF_HUB_CACHE", text: $cachePath)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(minWidth: 120, idealWidth: 200, maxWidth: 220)
                        .padding(.horizontal, 9)
                        .frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Console.inset))
                    Button("应用") {
                        state.settings.setHfCache(cachePath.trimmingCharacters(in: .whitespaces))
                        state.toast("缓存目录已保存")
                    }
                    .buttonStyle(.consoleSoft)
                    .fixedSize()
                }
            }
        }
    }

    // MARK: Right column

    private var gatewayCard: some View {
        SettingsCard {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("API 网关")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Console.text)
                    Text("OpenAI 与 Claude 双协议")
                        .font(.system(size: 11))
                        .foregroundStyle(Console.tertiary)
                }
                Spacer(minLength: 0)
                Toggle("", isOn: Binding(
                    get: { state.settings.gatewayEnabled },
                    set: { value in
                        state.settings.setGatewayEnabled(value)
                        state.applyGatewaySettings()
                    }))
                    .toggleStyle(.switch)
                    .controlSize(.regular)
                    .labelsHidden()
                    .tint(Console.accent)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider().overlay(Console.insetStroke)

            SettingsRow(title: "网关端口", detail: "固定入口，客户端不用改") {
                HStack(spacing: 8) {
                    portInput($gatewayPort, placeholder: "9000")
                    Button("应用") {
                        if let port = Int(gatewayPort), (1024...65535).contains(port) {
                            state.settings.setGatewayPort(port)
                            state.applyGatewaySettings()
                        }
                    }
                    .buttonStyle(.consoleSoft)
                    .fixedSize()
                }
            }
        }
    }

    private var cliCard: some View {
        SettingsCard {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.t("命令行接口"))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Console.text)
                    Text(L10n.t("本机 flashcat 命令的连接端口"))
                        .font(.system(size: 11))
                        .foregroundStyle(Console.tertiary)
                }
                Spacer(minLength: 0)
                Toggle("", isOn: Binding(
                    get: { state.settings.controlAPIEnabled },
                    set: { value in
                        state.settings.setControlAPIEnabled(value)
                        state.applyControlSettings()
                    }))
                    .toggleStyle(.switch)
                    .controlSize(.regular)
                    .labelsHidden()
                    .tint(Console.accent)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider().overlay(Console.insetStroke)

            SettingsRow(title: "控制端口", detail: "被占用时会自动顺延，实际端口写在 control.json") {
                HStack(spacing: 8) {
                    portInput($controlPort, placeholder: "9100")
                    Button("应用") {
                        if let port = Int(controlPort), (1024...65535).contains(port) {
                            state.settings.setControlPort(port)
                            state.applyControlSettings()
                        }
                    }
                    .buttonStyle(.consoleSoft)
                    .fixedSize()
                }
            }

            Divider().overlay(Console.insetStroke)

            SettingsRow(title: "命令行工具", detail: "在终端运行 flashcat --help 查看全部命令") {
                Button("复制") {
                    state.copy("flashcat --help", label: "命令行用法已复制")
                }
                .buttonStyle(.consoleSecondary)
            }
        }
    }

    /// The row names the startup default, which can belong to an engine that is
    /// not the one serving right now. Say so instead of showing a model id that
    /// looks like the live selection.
    private var defaultModelDetail: String {
        guard let selection = state.defaultSelection else { return "未选择" }
        let name = state.shortModelName(selection.model)
        guard selection.engine != state.activeEngine else { return name }
        return L10n.format("%@ · %@（下次启动）", name, selection.engine.displayName)
    }

    private func thinkingCard(wide: Bool) -> some View {
        SettingsCard {
            SettingsRow(title: "思考模式", detail: "回答前是否输出推理过程") {
                NativeSegmented(selection: Binding(
                    get: { thinkingMode },
                    set: {
                        storedThinkingMode = $0.rawValue
                        state.settings.setThinkingMode($0)
                    }),
                    options: ThinkingMode.allCases.map { ($0, $0.label) })
                    .fixedSizeWhen(wide)
            }
            Divider().overlay(Console.insetStroke)
            SettingsRow(title: "默认模型", detail: defaultModelDetail) {
                Menu {
                    ForEach(EngineCatalog.allIDs.filter { state.engineIsInstalled($0) }, id: \.self) { id in
                        let models = state.engineModels(for: id)
                            .filter { !$0.hidden && !$0.helper && !ModelLibraryEntry.isDraftModel($0.id) }
                        let selection = state.defaultSelection
                        if !models.isEmpty {
                            Section(id.displayName) {
                                ForEach(models) { model in
                                    Button {
                                        // 只记下默认选择，不在这里切换引擎：正在跑的
                                        // 引擎可能属于另一台，切过去会停掉它的服务。
                                        state.setDefaultModel(model.id, engine: id)
                                    } label: {
                                        if selection?.engine == id, selection?.model == model.id {
                                            Label(state.shortModelName(model.id), systemImage: "checkmark")
                                        } else {
                                            Text(state.shortModelName(model.id))
                                        }
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    Label("更改", systemImage: "line.3.horizontal")
                }
                .buttonStyle(.consoleSecondary)
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            Divider().overlay(Console.insetStroke)
            SettingsRow(title: "思考等级", detail: "等级由当前引擎提供") {
                NativeSegmented(selection: Binding(
                    get: { reasoningEffort },
                    set: {
                        storedReasoningEffort = $0.rawValue
                        state.settings.setReasoningEffort($0)
                    }),
                    options: ReasoningEffort.allCases.map { ($0, $0.label) })
                    .fixedSizeWhen(wide)
                    .disabled(thinkingMode != .on)
            }
        }
    }

    private var imageCard: some View {
        SettingsCard {
            SettingsRow(title: "图像模型常驻",
                        detail: "画完图后图像模型留在显存里，下一轮生图不必重新加载；内存不够时引擎仍会自己换出") {
                Toggle("", isOn: Binding(
                    get: { state.imageToolResident },
                    set: { state.imageToolResident = $0 }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .tint(Console.accent)
            }
        }
    }

    private var infoCard: some View {
        SettingsCard {
            infoRow("flashCat", detail: L10n.format("本地推理控制台 · v%@", appVersion), trailing: device.chipName)
            Divider().overlay(Console.insetStroke)
            infoRow("这台 Mac", detail: L10n.format("%@ · %lld GB 统一内存", device.chipName, device.memoryGB),
                    trailing: L10n.format("可用 %@", Format.size(Int(device.freeDiskBytes))))
            Divider().overlay(Console.insetStroke)
            SettingsRow(title: "对话参数", detail: L10n.format("温度 %.1f · Top P %.2f · 最大输出 %lld", state.settings.temperature, state.settings.topP, state.effectiveMaxTokens)) {
                Button("调整") { state.section = .chat }
                    .buttonStyle(.consoleSecondary)
            }
            Divider().overlay(Console.insetStroke)
            SettingsRow(title: "首次启动引导", detail: "重新打开引擎安装页") {
                Button("打开") { state.showsLaunchPage = true }
                    .buttonStyle(.consoleSecondary)
            }
            Divider().overlay(Console.insetStroke)
            SettingsRow(title: "恢复默认", detail: "外观、背景、启动与网关设置") {
                Button("恢复") {
                    state.theme.set(.system)
                    background.clear()
                    background.opacity = 0.35
                    background.blur = 18
                    state.settings.setAutoStart(false)
                    state.settings.setGatewayEnabled(true)
                    state.settings.setControlAPIEnabled(true)
                    state.settings.setControlPort(9100)
                    state.resetChatParameters()
                    state.applyGatewaySettings()
                    state.applyControlSettings()
                    state.toast("已恢复默认设置")
                }
                .buttonStyle(.consoleSoft)
            }
        }
    }

    private func infoRow(_ title: String, detail: String, trailing: String) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.t(title))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Console.text)
                Text(L10n.t(detail))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Console.tertiary)
            }
            Spacer(minLength: 8)
            Text(L10n.t(trailing))
                .font(.system(size: 10.5))
                .foregroundStyle(Console.tertiary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
    }

    /// 芯片/内存/磁盘在会话内基本不变，不必每次重绘都跑一遍 sysctl + statfs。
    @State private var device = DeviceProfile.current()

    private var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "—"
    }

    // MARK: Parts

}

// MARK: - Settings chrome

struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        GlassCard(padding: 0) {
            VStack(spacing: 0) { content() }
        }
    }
}

struct SettingsRow<Trailing: View>: View {
    var title: String
    var detail: String? = nil
    var trailingTop: Bool = false
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: trailingTop ? .top : .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.t(title))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Console.text)
                if let detail {
                    Text(L10n.t(detail))
                        .font(.system(size: 10.5))
                        .foregroundStyle(Console.tertiary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
        .frame(minHeight: 58)
    }
}

private extension View {
    /// 只在宽版式里把分段控件按标签宽度钉住；窄版式允许它压缩。
    @ViewBuilder
    func fixedSizeWhen(_ condition: Bool) -> some View {
        if condition { fixedSize() } else { self }
    }
}
