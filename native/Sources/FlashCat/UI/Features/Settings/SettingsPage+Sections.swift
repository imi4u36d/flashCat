// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import FlashCatCore
import FlashCatKit
import SwiftUI

extension SettingsPage {
    // MARK: Left column

    func appearanceCard(wide: Bool) -> some View {
        SettingsCard {
            SettingsRow(
                title: "外观",
                detail: "跟随系统自动切换日间与夜间，或固定模式"
            ) {
                if wide {
                    AppearanceSegmentedControl(
                        options: AppAppearance.allCases,
                        selection: theme.mode,
                        label: \.label,
                        detail: \.detail,
                        onSelect: { theme.set($0) }
                    )
                } else {
                    DSMenu(size: .regular) {
                        DSMenuTriggerLabel(
                            title: theme.mode.label,
                            systemImage: theme.mode.symbol,
                            kind: .secondary,
                            size: .regular)
                    } content: {
                        ForEach(AppAppearance.allCases) { appearance in
                            Button {
                                theme.set(appearance)
                            } label: {
                                if theme.mode == appearance {
                                    Label(L10n.t(appearance.label), systemImage: "checkmark")
                                } else {
                                    Text(L10n.t(appearance.label))
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    var launchCard: some View {
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

    /// 网关 / 控制端口的输入框。应用按钮放在输入框外面，和缓存行一样用「输入框 + 按钮」排布。
    func portInput(
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

    var endpointDirty: Bool { endpoint != state.settings.hfEndpoint }
    var tokenDirty: Bool { token != state.settings.hfToken }
    var cachePathDirty: Bool { cachePath != state.settings.hfCache }
    var gatewayPortDirty: Bool { gatewayPort != String(state.settings.gatewayPort) }
    var controlPortDirty: Bool { controlPort != String(state.settings.controlPort) }

    func applyCachePath() {
        let trimmed = cachePath.trimmingCharacters(in: .whitespaces)
        cachePath = trimmed
        state.settings.setHfCache(trimmed)
        cacheFlash.succeed()
    }

    func pickCacheDirectory() {
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

    func applyGatewayPort() {
        guard let port = Int(gatewayPort), (1024...65535).contains(port) else {
            gatewayPort = String(state.settings.gatewayPort)
            gatewayPortNote = L10n.t("端口需在 1024–65535 之间")
            gatewayPortFlash.warn()
            return
        }
        gatewayPortNote = nil
        state.settings.setGatewayPort(port)
        state.applyGatewaySettings()
        gatewayPortFlash.succeed()
    }

    func applyControlPort() {
        guard let port = Int(controlPort), (1024...65535).contains(port) else {
            controlPort = String(state.settings.controlPort)
            controlPortNote = L10n.t("端口需在 1024–65535 之间")
            controlPortFlash.warn()
            return
        }
        controlPortNote = nil
        state.settings.setControlPort(port)
        state.applyControlSettings()
        controlPortFlash.succeed()
    }

    /// 模型广场的来源与网络设置。HF-Mirror 和 token 只影响 Hugging Face；
    /// ModelScope 走官方地址，但共用同一份下载缓存与公共目录。
    func sourceCard(wide: Bool) -> some View {
        SettingsCard {
            SettingsRow(
                title: "模型来源",
                detail: "广场从哪个仓库搜索与下载；HF-Mirror 是 Hugging Face 的国内镜像"
            ) {
                NativeSegmented(
                    selection: Binding(
                        get: { hubSource },
                        set: { value in
                            // 分段控件本身就是回执：选中态已经移到新来源。
                            storedHubSource = value.rawValue
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
                    Button {
                        applyEndpoint()
                    } label: {
                        ActionFlashLabel(title: "应用", flash: endpointFlash.value)
                    }
                    .buttonStyle(.ds(endpointDirty ? .primary : .secondary, size: .small))
                    .disabled(!endpointDirty)
                    .help(endpointNote ?? L10n.t("保存镜像地址"))
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
                    Button {
                        applyToken()
                    } label: {
                        ActionFlashLabel(title: "应用", flash: tokenFlash.value)
                    }
                    .buttonStyle(.ds(tokenDirty ? .primary : .secondary, size: .small))
                    .disabled(!tokenDirty)
                    .help(L10n.t("保存 Hugging Face token"))
                    .fixedSize()
                }
            }
        }
    }

    func applyEndpoint() {
        guard let value = HFEndpoint.normalized(endpoint) else {
            endpointNote = L10n.t("镜像地址要写成 host 或 http(s)://host")
            endpointFlash.warn()
            return
        }
        endpointNote = nil
        state.settings.setHfEndpoint(value)
        endpoint = value
        endpointFlash.succeed()
    }

    func applyToken() {
        state.settings.setHfToken(token)
        token = state.settings.hfToken
        tokenFlash.succeed()
    }

    var cacheCard: some View {
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
                    Button {
                        applyCachePath()
                    } label: {
                        ActionFlashLabel(title: "应用", flash: cacheFlash.value)
                    }
                    .buttonStyle(.ds(cachePathDirty ? .primary : .secondary, size: .small))
                    .disabled(!cachePathDirty)
                    .help(L10n.t("保存缓存目录"))
                    .fixedSize()
                }
            }
        }
    }

    // MARK: Right column

    var gatewayCard: some View {
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
                Tag(text: "始终启用", tone: .success)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            DSDivider()

            SettingsRow(title: "网关端口", detail: "固定入口，客户端不用改") {
                HStack(spacing: 8) {
                    portInput($gatewayPort, placeholder: "9000", focus: .gatewayPort, onSubmit: applyGatewayPort)
                    Button {
                        applyGatewayPort()
                    } label: {
                        ActionFlashLabel(title: "应用", flash: gatewayPortFlash.value)
                    }
                    .buttonStyle(.ds(gatewayPortDirty ? .primary : .secondary, size: .small))
                    .disabled(!gatewayPortDirty)
                    .help(gatewayPortNote ?? L10n.t("保存网关端口"))
                    .fixedSize()
                }
            }
        }
    }

    var cliCard: some View {
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
                Tag(text: "始终启用", tone: .success)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            DSDivider()

            SettingsRow(title: "控制端口", detail: "被占用时会自动顺延，实际端口写在 control.json") {
                HStack(spacing: 8) {
                    portInput($controlPort, placeholder: "9100", focus: .controlPort, onSubmit: applyControlPort)
                    Button {
                        applyControlPort()
                    } label: {
                        ActionFlashLabel(title: "应用", flash: controlPortFlash.value)
                    }
                    .buttonStyle(.ds(controlPortDirty ? .primary : .secondary, size: .small))
                    .disabled(!controlPortDirty)
                    .help(controlPortNote ?? L10n.t("保存控制端口"))
                    .fixedSize()
                }
            }

            DSDivider()

            SettingsRow(title: "命令行工具", detail: "在终端运行 flashcat --help 查看全部命令") {
                Button {
                    state.copy("flashcat --help")
                    cliCopyFlash.succeed()
                } label: {
                    ActionFlashLabel(title: "复制", flash: cliCopyFlash.value)
                }
                .buttonStyle(.ds(.secondary, size: .small))
            }
        }
    }

    /// The row names the startup default, which can belong to an engine that is
    /// not the one serving right now. Say so instead of showing a model id that
    /// looks like the live selection.
    var defaultModelDetail: String {
        guard let selection = state.defaultSelection else { return L10n.t("未选择") }
        let name = state.shortModelName(selection.model)
        guard selection.engine != state.activeEngine else { return name }
        return L10n.format("%@ · %@（下次启动）", name, selection.engine.displayName)
    }

    func thinkingCard(wide: Bool) -> some View {
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
                                    .disabled(state.generating)
                                    .help(
                                        state.generating
                                            ? L10n.t("正在生成，先停止再切换模型")
                                            : L10n.t("设为默认模型"))
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

    var imageCard: some View {
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
    var infoCard: some View {
        SettingsCard {
            infoRow("flashCat", detail: L10n.format("本地推理控制台 · v%@", appVersion), trailing: "")
            DSDivider()
            infoRow(
                "这台 Mac", detail: L10n.format("%@ · %lld GB 统一内存", device.chipName, device.memoryGB),
                trailing: L10n.format("可用 %@", Format.size(Int(device.freeDiskBytes))))
        }
    }

    func checkForAppUpdate() {
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

    var chatDefaultsCard: some View {
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

    var maintenanceCard: some View {
        SettingsCard {
            SettingsRow(title: "首次启动引导", detail: "重新打开引擎安装页") {
                Button(L10n.t("打开")) { state.showsLaunchPage = true }
                    .buttonStyle(.ds(.secondary, size: .small))
            }
            DSDivider()
            SettingsRow(title: "恢复默认", detail: "外观、启动、接口端口与默认对话参数") {
                Button {
                    confirmingResetDefaults = true
                } label: {
                    ActionFlashLabel(title: "恢复", flash: resetFlash.value)
                }
                .buttonStyle(.ds(.secondary, size: .small))
            }
        }
    }

    func resetAllDefaults() {
        state.theme.set(.system)
        state.theme.resetThemeColor()
        state.settings.setAutoStart(false)
        state.settings.setGatewayPort(9000)
        state.settings.setControlPort(9100)
        state.resetChatParameters()
        state.applyGatewaySettings()
        state.applyControlSettings()
        load()
        resetFlash.succeed()
    }

    func infoRow(_ title: String, detail: String, trailing: String) -> some View {
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

    var section: SettingsSection {
        get { state.settingsSection }
        nonmutating set { state.settingsSection = newValue }
    }

    var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "—"
    }

    // MARK: Parts
}
