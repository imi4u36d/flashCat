// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import FlashCatKit
import SwiftUI

/// 设置页：按 WebUI 版式——左右两列卡片，行内即改即生效。
struct SettingsPage: View {
    private enum FocusField: Hashable {
        case enginePort(EngineID)
        case gatewayPort
        case controlPort
        case endpoint
        case token
        case cachePath
    }

    @ObservedObject var state: AppState
    @State private var ports: [String: String] = [:]
    @State private var gatewayPort = ""
    @State private var controlPort = ""
    @State private var cachePath = ""
    @State private var endpoint = ""
    @State private var token = ""
    @State private var showsChatParameters = false
    @State private var confirmingResetDefaults = false
    @FocusState private var focusedField: FocusField?
    /// 思考设置走 `@AppStorage` 而不是本地镜像：`AppSettings` 不是
    /// ObservableObject，只写 UserDefaults 不会触发 SwiftUI 重新求值。
    /// 观察这两个键之后，聊天浮层滑杆与这里的分段控件才能互相同步。
    @AppStorage("thinkingMode") private var storedThinkingMode = ThinkingMode.automatic.rawValue
    @AppStorage("reasoningEffort") private var storedReasoningEffort = ReasoningEffort.medium.rawValue
    @AppStorage("hubSource") private var storedHubSource = HubSource.huggingFace.rawValue
    @AppStorage("chat.temperature") private var storedTemperature = 0.7
    @AppStorage("chat.topP") private var storedTopP = 0.95
    @AppStorage("chat.maxTokens") private var storedMaxTokens = 0

    private enum AppUpdateState {
        case idle
        case checking
        case upToDate
        case available(AppUpdateChecker.Release)
        case failed(String)
    }

    @State private var appUpdate: AppUpdateState = .idle

    private var hubSource: HubSource {
        HubSource(rawValue: storedHubSource) ?? .huggingFace
    }

    private var thinkingMode: ThinkingMode {
        ThinkingMode(rawValue: storedThinkingMode) ?? .automatic
    }

    private var reasoningEffort: ReasoningEffort {
        ReasoningEffort.stored(storedReasoningEffort)
    }

    var body: some View {
        GeometryReader { proxy in
            let wide = proxy.size.width >= Console.compactContentWidth
            VStack(alignment: .leading, spacing: 0) {
                DSPageHeader(
                    title: "设置",
                    subtitle: "flashCat v\(appVersion) · \(device.chipName)"
                )
                .padding(.leading, Console.topBarLeading(sidebarShown: state.showsSidebar))
                .padding(.trailing, Console.contentPadding)
                .padding(.top, Console.pageTopPadding)
                .padding(.bottom, 10)
                .background(WindowDragArea())

                ScrollView {
                    if wide {
                        HStack(alignment: .top, spacing: 20) {
                            settingsNav
                                .frame(width: 148)

                            Rectangle()
                                .fill(DS.line)
                                .frame(width: 1)

                            sectionContent(wide: true)
                                .frame(maxWidth: 760, alignment: .leading)

                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, Console.contentPadding)
                        .padding(.top, 2)
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            settingsMenu
                            sectionContent(wide: false)
                        }
                        .padding(.horizontal, Console.contentPadding)
                        .padding(.top, 2)
                    }
                }
                .scrollIndicators(.never)
            }
        }
        // 设置页滚动视口的下沿同样收在侧栏底边上。
        .dsPageColumn()
        .padding(.bottom, Console.contentBottomInset)
        .onAppear(perform: load)
        .onChange(of: state.activeEngine) { _, _ in load() }
        .onChange(of: focusedField) { previous, _ in
            if case .enginePort(let id) = previous {
                applyPort(id)
            }
        }
        .sheet(isPresented: $showsChatParameters) {
            ChatParametersSheet(state: state)
        }
        .alert(L10n.t("确认恢复默认设置？"), isPresented: $confirmingResetDefaults) {
            Button(L10n.t("恢复默认"), role: .destructive) {
                resetAllDefaults()
            }
            Button(L10n.t("取消"), role: .cancel) {}
        } message: {
            Text(L10n.t("将恢复外观、随应用启动、API 网关、控制接口及默认对话参数，自定义系统提示也会清空。"))
        }
    }

    /// 设置不再是一页两列的长表：左侧分区，右侧只显示当前分区。
    /// 端口回到引擎的配置里、token 留在模型来源，设置页只保留真正全局的东西。
    private var settingsNav: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsSection.allCases) { item in
                Button {
                    withAnimation(DS.Motion.snappy) { section = item }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 11.5, weight: .medium))
                            .frame(width: 15)
                            .foregroundStyle(section == item ? DS.text : DS.text3)
                        Text(L10n.t(item.title))
                            .font(DS.Font.prose(12.5, weight: section == item ? .medium : .regular))
                            .foregroundStyle(section == item ? DS.text : DS.text2)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 30)
                    .background(
                        DS.rect(DS.Radius.sm)
                            .fill(section == item ? DS.selected : .clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// 窄窗口下左侧分区栏会吃掉三分之一宽度，折叠成一个分区下拉。
    private var settingsMenu: some View {
        DSMenu(size: .regular) {
            DSMenuTriggerLabel(
                title: section.title,
                systemImage: section.symbol,
                kind: .secondary,
                size: .regular)
        } content: {
            ForEach(SettingsSection.allCases) { item in
                Button {
                    withAnimation(DS.Motion.snappy) { section = item }
                } label: {
                    if section == item {
                        Label(L10n.t(item.title), systemImage: "checkmark")
                    } else {
                        Text(L10n.t(item.title))
                    }
                }
            }
        }
        .help(L10n.t("切换设置分区"))
        .accessibilityLabel(L10n.t("切换设置分区"))
    }

    @ViewBuilder
    private func sectionContent(wide: Bool) -> some View {
        VStack(spacing: 16) {
            switch section {
            case .general:
                appearanceCard(wide: wide)
                launchCard
                maintenanceCard
            case .engine:
                settingsHint("端口点「应用」后生效；正在运行的引擎需要重启。")
                portsCard
            case .models:
                sourceCard(wide: wide)
                cacheCard
            case .api:
                settingsHint("开关即时生效；改网关端口会重启网关。")
                gatewayCard
                cliCard
            case .chat:
                thinkingCard(wide: wide)
                imageCard
                chatDefaultsCard
            case .about:
                infoCard
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func settingsHint(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 10.5))
            Text(L10n.t(text))
                .font(DS.Font.prose(11))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(DS.text3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 2)
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
        endpoint = state.settings.hfEndpoint
        token = state.settings.hfToken
    }

    // MARK: Left column

    private func appearanceCard(wide: Bool) -> some View {
        SettingsCard {
            SettingsRow(title: "外观", detail: "跟随系统或固定外观") {
                if wide {
                    NativeSegmented(
                        selection: Binding(
                            get: { state.theme.mode },
                            set: { state.theme.set($0) }),
                        options: AppAppearance.allCases.map { ($0, $0.label) }
                    )
                    // 宽版式里把宽度交给标签：不参与行内剩余空间的分配，
                    // 切换选中项时才不会把整行挤得一宽一窄。
                    .fixedSize()
                } else {
                    // 窄版式里三段控件会被压成一个看不清的胶囊，改成下拉。
                    DSMenu(size: .regular) {
                        DSMenuTriggerLabel(
                            title: state.theme.mode.label,
                            systemImage: state.theme.mode.symbol,
                            kind: .secondary,
                            size: .regular)
                    } content: {
                        ForEach(AppAppearance.allCases) { mode in
                            Button {
                                state.theme.set(mode)
                            } label: {
                                if state.theme.mode == mode {
                                    Label(L10n.t(mode.label), systemImage: "checkmark")
                                } else {
                                    Text(L10n.t(mode.label))
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var launchCard: some View {
        SettingsCard {
            SettingsRow(title: "登录时启动", detail: "加入 macOS 登录项") {
                Toggle(
                    "",
                    isOn: Binding(
                        get: { state.settings.launchAtLogin },
                        set: { value in
                            state.settings.setLaunchAtLogin(value)
                            LoginItem.set(enabled: value)
                        })
                )
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .tint(DS.accent)
                .accessibilityLabel(L10n.t("登录时启动"))
            }
            DSDivider()
            SettingsRow(title: "随应用启动引擎", detail: "打开应用时拉起默认引擎") {
                Toggle(
                    "",
                    isOn: Binding(
                        get: { state.settings.autoStart },
                        set: { state.settings.setAutoStart($0) })
                )
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .tint(DS.accent)
                .accessibilityLabel(L10n.t("随应用启动引擎"))
            }
        }
    }

    private var portsCard: some View {
        SettingsCard {
            SettingsRow(title: "引擎端口", detail: "各引擎固定起始端口，互不抢占", trailingTop: true) {
                EmptyView()
            }
            DSDivider()
            ForEach(EngineCatalog.allIDs, id: \.self) { id in
                HStack(spacing: 10) {
                    LetterTile(
                        letter: String(id.displayName.prefix(1)).uppercased(),
                        color: engineAccent(id), size: 24)
                    Text(id.displayName)
                        .font(DS.Font.md)
                        .foregroundStyle(DS.text)
                        .frame(width: 84, alignment: .leading)
                    Spacer(minLength: 0)
                    portField(id)
                }
                .padding(.horizontal, 16)
                .frame(height: 42)
                if id != EngineCatalog.allIDs.last {
                    DSDivider().padding(.leading, 50)
                }
            }
        }
    }

    private func portField(_ id: EngineID) -> some View {
        let focused = focusedField == .enginePort(id)
        return HStack(spacing: 4) {
            Text(":")
                .font(DS.Font.mono(11))
                .foregroundStyle(DS.text3)
            TextField(
                L10n.t("端口"),
                text: Binding(
                    get: { ports[id.rawValue] ?? "" },
                    set: { ports[id.rawValue] = $0.filter(\.isNumber) })
            )
            .textFieldStyle(.plain)
            .font(DS.Font.mono(11.5))
            .frame(width: 54)
            .focused($focusedField, equals: .enginePort(id))
            .onSubmit { applyPort(id) }
            VStack(spacing: 0) {
                Button {
                    stepPort(id, by: 1)
                } label: {
                    Image(systemName: "chevron.up").font(.system(size: 7, weight: .bold))
                }
                .buttonStyle(.plainHit)
                .accessibilityLabel(L10n.t("增加端口"))
                Button {
                    stepPort(id, by: -1)
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
                }
                .buttonStyle(.plainHit)
                .accessibilityLabel(L10n.t("减小端口"))
            }
            .foregroundStyle(DS.text3)
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .dsInputSurface(radius: DS.Radius.sm, focused: focused)
    }

    private func stepPort(_ id: EngineID, by delta: Int) {
        let range = id.portRange
        let current =
            Int(ports[id.rawValue] ?? "")
            ?? EngineStore.shared.configuration(for: id).port
            ?? id.defaultPort
        let next = min(max(current + delta, range.lowerBound), range.upperBound)
        ports[id.rawValue] = String(next)
        applyPort(id)
    }

    private func applyPort(_ id: EngineID) {
        let storedPort = EngineStore.shared.configuration(for: id).port ?? id.defaultPort
        guard let port = Int(ports[id.rawValue] ?? ""), id.portRange.contains(port) else {
            ports[id.rawValue] = String(storedPort)
            state.toast(
                L10n.format(
                    "端口需在 %lld–%lld 之间",
                    Int64(id.portRange.lowerBound),
                    Int64(id.portRange.upperBound)
                )
            )
            return
        }
        guard port != storedPort else { return }
        state.switchEnginePort(id, port: port)
        state.toast(L10n.format("%@ 端口已设为 %lld", id.displayName, Int64(port)))
    }

    /// 网关 / 控制端口的输入框。应用按钮放在输入框外面，和缓存行一样用「输入框 + 按钮」排布。
    private func portInput(
        _ text: Binding<String>,
        placeholder: String,
        focus: FocusField,
        onSubmit: @escaping () -> Void = {}
    ) -> some View {
        HStack(spacing: 4) {
            Text(":")
                .font(DS.Font.mono(11))
                .foregroundStyle(DS.text3)
            TextField(
                placeholder,
                text: Binding(
                    get: { text.wrappedValue },
                    set: { text.wrappedValue = $0.filter(\.isNumber) })
            )
            .textFieldStyle(.plain)
            .font(DS.Font.mono(11.5))
            .frame(width: 54)
            .focused($focusedField, equals: focus)
            .onSubmit(onSubmit)
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .dsInputSurface(radius: DS.Radius.sm, focused: focusedField == focus)
    }

    private var endpointDirty: Bool { endpoint != state.settings.hfEndpoint }
    private var tokenDirty: Bool { token != state.settings.hfToken }
    private var cachePathDirty: Bool { cachePath != state.settings.hfCache }
    private var gatewayPortDirty: Bool { gatewayPort != String(state.settings.gatewayPort) }
    private var controlPortDirty: Bool { controlPort != String(state.settings.controlPort) }

    private func applyCachePath() {
        let trimmed = cachePath.trimmingCharacters(in: .whitespaces)
        cachePath = trimmed
        state.settings.setHfCache(trimmed)
        state.toast(L10n.t("缓存目录已保存"))
    }

    private func pickCacheDirectory() {
        let panel = NSOpenPanel()
        panel.title = L10n.t("选择下载缓存目录")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        let trimmed = cachePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: trimmed, isDirectory: true)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        cachePath = url.path
        applyCachePath()
    }

    private func applyGatewayPort() {
        guard let port = Int(gatewayPort), (1024...65535).contains(port) else {
            gatewayPort = String(state.settings.gatewayPort)
            state.toast(L10n.t("端口需在 1024–65535 之间"))
            return
        }
        state.settings.setGatewayPort(port)
        state.applyGatewaySettings()
        state.toast(L10n.format("API 网关端口已设为 %lld", Int64(port)))
    }

    private func applyControlPort() {
        guard let port = Int(controlPort), (1024...65535).contains(port) else {
            controlPort = String(state.settings.controlPort)
            state.toast(L10n.t("端口需在 1024–65535 之间"))
            return
        }
        state.settings.setControlPort(port)
        state.applyControlSettings()
        state.toast(L10n.format("控制端口已设为 %lld", Int64(port)))
    }

    /// 模型广场的来源与网络设置。HF-Mirror 和 token 只影响 Hugging Face；
    /// ModelScope 走官方地址，但共用同一份下载缓存与公共目录。
    private func sourceCard(wide: Bool) -> some View {
        SettingsCard {
            SettingsRow(
                title: "模型来源",
                detail: "广场从哪个仓库搜索与下载；HF-Mirror 是 Hugging Face 的国内镜像"
            ) {
                NativeSegmented(
                    selection: Binding(
                        get: { hubSource },
                        set: { value in
                            storedHubSource = value.rawValue
                            state.toast(L10n.format("模型广场改用 %@", value.displayName))
                        }),
                    options: HubSource.allCases.map { ($0, $0.displayName) }
                )
                .fixedSizeWhen(wide)
            }

            DSDivider()

            SettingsRow(
                title: "镜像地址",
                detail: "Hugging Face 端点，留空用官方；选 HF-Mirror 时固定走 hf-mirror.com"
            ) {
                HStack(spacing: 8) {
                    TextField("https://huggingface.co", text: $endpoint)
                        .textFieldStyle(.plain)
                        .font(DS.Font.mono(11))
                        .frame(minWidth: 120, idealWidth: 190, maxWidth: 210)
                        .focused($focusedField, equals: .endpoint)
                        .padding(.horizontal, 9)
                        .frame(height: 28)
                        .dsInputSurface(radius: DS.Radius.sm, focused: focusedField == .endpoint)
                        .onSubmit { applyEndpoint() }
                    Button(L10n.t("应用")) { applyEndpoint() }
                        .buttonStyle(.ds(endpointDirty ? .primary : .secondary, size: .small))
                        .disabled(!endpointDirty)
                        .fixedSize()
                }
            }

            DSDivider()

            SettingsRow(title: "访问令牌", detail: "Hugging Face token，仅私有仓库需要") {
                HStack(spacing: 8) {
                    SecureField("hf_…", text: $token)
                        .textFieldStyle(.plain)
                        .font(DS.Font.mono(11))
                        .frame(minWidth: 120, idealWidth: 190, maxWidth: 210)
                        .focused($focusedField, equals: .token)
                        .padding(.horizontal, 9)
                        .frame(height: 28)
                        .dsInputSurface(radius: DS.Radius.sm, focused: focusedField == .token)
                        .onSubmit { applyToken() }
                    Button(L10n.t("应用")) { applyToken() }
                        .buttonStyle(.ds(tokenDirty ? .primary : .secondary, size: .small))
                        .disabled(!tokenDirty)
                        .fixedSize()
                }
            }
        }
    }

    private func applyEndpoint() {
        guard let value = HFEndpoint.normalized(endpoint) else {
            state.toast(L10n.t("镜像地址要写成 host 或 http(s)://host"))
            return
        }
        state.settings.setHfEndpoint(value)
        endpoint = value
        state.toast(value.isEmpty ? L10n.t("已改用 Hugging Face 官方端点") : L10n.format("浏览与下载将走 %@", value))
    }

    private func applyToken() {
        state.settings.setHfToken(token)
        token = state.settings.hfToken
        state.toast(token.isEmpty ? L10n.t("已清除 Hugging Face token") : L10n.t("Hugging Face token 已保存"))
    }

    private var cacheCard: some View {
        SettingsCard {
            SettingsRow(title: "下载缓存", detail: "Hugging Face 缓存目录，留空用默认") {
                HStack(spacing: 8) {
                    TextField(L10n.t("默认使用 HF_HUB_CACHE"), text: $cachePath)
                        .textFieldStyle(.plain)
                        .font(DS.Font.mono(11))
                        .frame(minWidth: 120, idealWidth: 170, maxWidth: 195)
                        .focused($focusedField, equals: .cachePath)
                        .padding(.horizontal, 9)
                        .frame(height: 28)
                        .dsInputSurface(radius: DS.Radius.sm, focused: focusedField == .cachePath)
                        .onSubmit { applyCachePath() }
                    DSIconButton(systemName: "folder", help: "选择目录", size: 28, style: .outlined) {
                        pickCacheDirectory()
                    }
                    Button(L10n.t("应用")) { applyCachePath() }
                        .buttonStyle(.ds(cachePathDirty ? .primary : .secondary, size: .small))
                        .disabled(!cachePathDirty)
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
                    Text(L10n.t("接口"))
                        .font(DS.Font.lg.weight(.semibold))
                        .foregroundStyle(DS.text)
                    Text(L10n.t("OpenAI 与 Claude 双协议"))
                        .font(DS.Font.xs)
                        .foregroundStyle(DS.text3)
                }
                Spacer(minLength: 0)
                Toggle(
                    "",
                    isOn: Binding(
                        get: { state.settings.gatewayEnabled },
                        set: { value in
                            state.settings.setGatewayEnabled(value)
                            state.applyGatewaySettings()
                        })
                )
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .tint(DS.accent)
                .accessibilityLabel(L10n.t("API 网关"))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            DSDivider()

            SettingsRow(title: "网关端口", detail: "固定入口，客户端不用改") {
                HStack(spacing: 8) {
                    portInput($gatewayPort, placeholder: "9000", focus: .gatewayPort, onSubmit: applyGatewayPort)
                    Button(L10n.t("应用")) { applyGatewayPort() }
                        .buttonStyle(.ds(gatewayPortDirty ? .primary : .secondary, size: .small))
                        .disabled(!gatewayPortDirty)
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
                        .font(DS.Font.lg.weight(.semibold))
                        .foregroundStyle(DS.text)
                    Text(L10n.t("本机 flashcat 命令的连接端口"))
                        .font(DS.Font.xs)
                        .foregroundStyle(DS.text3)
                }
                Spacer(minLength: 0)
                Toggle(
                    "",
                    isOn: Binding(
                        get: { state.settings.controlAPIEnabled },
                        set: { value in
                            state.settings.setControlAPIEnabled(value)
                            state.applyControlSettings()
                        })
                )
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .tint(DS.accent)
                .accessibilityLabel(L10n.t("命令行接口"))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            DSDivider()

            SettingsRow(title: "控制端口", detail: "被占用时会自动顺延，实际端口写在 control.json") {
                HStack(spacing: 8) {
                    portInput($controlPort, placeholder: "9100", focus: .controlPort, onSubmit: applyControlPort)
                    Button(L10n.t("应用")) { applyControlPort() }
                        .buttonStyle(.ds(controlPortDirty ? .primary : .secondary, size: .small))
                        .disabled(!controlPortDirty)
                        .fixedSize()
                }
            }

            DSDivider()

            SettingsRow(title: "命令行工具", detail: "在终端运行 flashcat --help 查看全部命令") {
                Button(L10n.t("复制")) {
                    state.copy("flashcat --help", label: L10n.t("命令行用法已复制"))
                }
                .buttonStyle(.ds(.secondary, size: .small))
            }
        }
    }

    /// The row names the startup default, which can belong to an engine that is
    /// not the one serving right now. Say so instead of showing a model id that
    /// looks like the live selection.
    private var defaultModelDetail: String {
        guard let selection = state.defaultSelection else { return L10n.t("未选择") }
        let name = state.shortModelName(selection.model)
        guard selection.engine != state.activeEngine else { return name }
        return L10n.format("%@ · %@（下次启动）", name, selection.engine.displayName)
    }

    private func thinkingCard(wide: Bool) -> some View {
        SettingsCard {
            SettingsRow(title: "思考模式", detail: "回答前是否输出推理过程") {
                NativeSegmented(
                    selection: Binding(
                        get: { thinkingMode },
                        set: {
                            storedThinkingMode = $0.rawValue
                            state.settings.setThinkingMode($0)
                        }),
                    options: ThinkingMode.allCases.map { ($0, $0.label) }
                )
                .fixedSizeWhen(wide)
            }
            DSDivider()
            SettingsRow(title: "默认模型", detail: defaultModelDetail) {
                DSMenu(size: .small) {
                    DSMenuTriggerLabel(
                        title: "更改",
                        systemImage: "line.3.horizontal",
                        trailingChevron: false,
                        size: .small)
                } content: {
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
                }
            }
            DSDivider()
            SettingsRow(title: "思考等级", detail: "等级由当前引擎提供") {
                NativeSegmented(
                    selection: Binding(
                        get: { reasoningEffort },
                        set: {
                            storedReasoningEffort = $0.rawValue
                            state.settings.setReasoningEffort($0)
                        }),
                    options: ReasoningEffort.allCases.map { ($0, $0.label) }
                )
                .fixedSizeWhen(wide)
                .disabled(thinkingMode != .on)
            }
        }
    }

    private var imageCard: some View {
        SettingsCard {
            SettingsRow(
                title: "图像模型常驻",
                detail: "画完图后图像模型留在显存里，下一轮生图不必重新加载；内存不够时引擎仍会自己换出"
            ) {
                Toggle(
                    "",
                    isOn: Binding(
                        get: { state.imageToolResident },
                        set: { state.imageToolResident = $0 })
                )
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .tint(DS.accent)
                .accessibilityLabel(L10n.t("图像模型常驻"))
            }
        }
    }

    /// 「关于」只回答版本与硬件；对话参数和维护动作各有自己的分区。
    private var infoCard: some View {
        SettingsCard {
            infoRow("flashCat", detail: L10n.format("本地推理控制台 · v%@", appVersion), trailing: device.chipName)
            DSDivider()
            infoRow(
                "这台 Mac", detail: L10n.format("%@ · %lld GB 统一内存", device.chipName, device.memoryGB),
                trailing: L10n.format("可用 %@", Format.size(Int(device.freeDiskBytes))))
            DSDivider()
            SettingsRow(title: "应用更新", detail: appUpdateDetail) {
                updateAction
            }
        }
    }

    private var appUpdateDetail: String {
        switch appUpdate {
        case .idle:
            return L10n.format("当前 v%@ · 从 GitHub Releases 检查", appVersion)
        case .checking:
            return L10n.t("正在检查…")
        case .upToDate:
            return L10n.t("已是最新版本")
        case .available(let release):
            if let date = release.publishedAt {
                return L10n.format("v%@ 可用 · %@", release.version, Format.relative(date))
            }
            return L10n.format("v%@ 可用", release.version)
        case .failed(let message):
            return L10n.format("检查失败：%@", message)
        }
    }

    @ViewBuilder
    private var updateAction: some View {
        switch appUpdate {
        case .checking:
            ProgressView()
                .controlSize(.small)
        case .available(let release):
            Button(L10n.t("打开发布页")) {
                NSWorkspace.shared.open(release.url)
            }
            .buttonStyle(.ds(.secondary, size: .small))
        case .failed:
            Button(L10n.t("重试")) { checkForAppUpdate() }
                .buttonStyle(.ds(.secondary, size: .small))
        case .idle, .upToDate:
            Button(L10n.t("检查更新")) { checkForAppUpdate() }
                .buttonStyle(.ds(.secondary, size: .small))
        }
    }

    private func checkForAppUpdate() {
        if case .checking = appUpdate { return }
        appUpdate = .checking
        Task { @MainActor in
            do {
                if let release = try await AppUpdateChecker.check(current: appVersion) {
                    appUpdate = .available(release)
                } else {
                    appUpdate = .upToDate
                }
            } catch {
                appUpdate = .failed(error.localizedDescription)
            }
        }
    }

    private var chatDefaultsCard: some View {
        SettingsCard {
            SettingsRow(
                title: "对话参数",
                detail: L10n.format(
                    "温度 %.1f · Top P %.2f · 最大输出 %lld",
                    storedTemperature,
                    storedTopP,
                    Int64(storedMaxTokens > 0 ? storedMaxTokens : state.effectiveMaxTokens))
            ) {
                Button(L10n.t("调整")) { showsChatParameters = true }
                    .buttonStyle(.ds(.secondary, size: .small))
            }
        }
    }

    private var maintenanceCard: some View {
        SettingsCard {
            SettingsRow(title: "首次启动引导", detail: "重新打开引擎安装页") {
                Button(L10n.t("打开")) { state.showsLaunchPage = true }
                    .buttonStyle(.ds(.secondary, size: .small))
            }
            DSDivider()
            SettingsRow(title: "恢复默认", detail: "外观、启动、网关、控制接口与默认对话参数") {
                Button(L10n.t("恢复")) {
                    confirmingResetDefaults = true
                }
                .buttonStyle(.ds(.secondary, size: .small))
            }
        }
    }

    private func resetAllDefaults() {
        state.theme.set(.system)
        state.settings.setAutoStart(false)
        state.settings.setGatewayEnabled(true)
        state.settings.setGatewayPort(9000)
        state.settings.setControlAPIEnabled(true)
        state.settings.setControlPort(9100)
        state.resetChatParameters()
        state.applyGatewaySettings()
        state.applyControlSettings()
        load()
        state.toast(L10n.t("已恢复默认设置"))
    }

    private func infoRow(_ title: String, detail: String, trailing: String) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.t(title))
                    .font(DS.Font.md.weight(.medium))
                    .foregroundStyle(DS.text)
                Text(L10n.t(detail))
                    .font(DS.Font.xs)
                    .foregroundStyle(DS.text3)
            }
            Spacer(minLength: 8)
            Text(L10n.t(trailing))
                .font(DS.Font.mono(11))
                .foregroundStyle(DS.text3)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    /// 芯片/内存/磁盘在会话内基本不变，不必每次重绘都跑一遍 sysctl + statfs。
    @State private var device = DeviceProfile.current()

    private var section: SettingsSection {
        get { state.settingsSection }
        nonmutating set { state.settingsSection = newValue }
    }

    private var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "—"
    }

    // MARK: Parts

}

// MARK: - Settings chrome

/// 设置页的分区。每一区只回答一类问题，不再把外观、端口、token 和关于
/// 排成同一张两列长表。
enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case engine
    case models
    case api
    case chat
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "通用"
        case .engine: return "引擎"
        case .models: return "模型来源"
        case .api: return "接口"
        case .chat: return "对话"
        case .about: return "关于"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .engine: return "cpu"
        case .models: return "square.stack.3d.up"
        case .api: return "network"
        case .chat: return "bubble.left.and.bubble.right"
        case .about: return "info.circle"
        }
    }
}

struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) { content() }
            .dsSurface(radius: DS.Radius.lg)
            .clipShape(DS.rect(DS.Radius.lg))
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
                    .font(DS.Font.md.weight(.medium))
                    .foregroundStyle(DS.text)
                if let detail {
                    Text(L10n.t(detail))
                        .font(DS.Font.xs)
                        .foregroundStyle(DS.text3)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .frame(minHeight: 50)
    }
}

extension View {
    /// 只在宽版式里把分段控件按标签宽度钉住；窄版式允许它压缩。
    @ViewBuilder
    fileprivate func fixedSizeWhen(_ condition: Bool) -> some View {
        if condition { fixedSize() } else { self }
    }
}
