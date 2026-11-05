import SwiftUI
import AppKit
import FlashCatKit

/// 设置页：外观、服务、网关、生成默认值与存储位置。
///
/// 每项改动立即落盘，没有「保存」按钮——需要重启或重新加载的动作会就地说明。
struct SettingsPage: View {
    @ObservedObject var state: AppState
    @State private var portText = ""
    @State private var gatewayPortText = ""
    @State private var cacheText = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(title: "设置",
                           subtitle: "外观、服务、网关与默认参数",
                           eyebrow: "偏好设置")
                    .padding(.top, 30)

                appearanceCard
                serviceCard
                gatewayCard
                chatDefaultsCard
                storageCard
                aboutCard
            }
            .padding(.horizontal, Native.pagePadding)
            .padding(.bottom, 30)
            .pageColumn()
        }
        .scrollIndicators(.never)
        .onAppear(perform: reloadFields)
        .onChange(of: state.activeEngine) { _, _ in reloadFields() }
    }

    private func reloadFields() {
        portText = String(EngineStore.shared.configuration(for: state.activeEngine).port
                          ?? state.activeEngine.defaultPort)
        gatewayPortText = String(state.settings.gatewayPort)
        cacheText = state.settings.hfCache
    }

    // MARK: Appearance

    private var appearanceCard: some View {
        Card("外观", subtitle: "跟随系统 / 浅色 / 深色，选择后立即生效") {
            HStack(spacing: 12) {
                Picker("", selection: Binding(
                    get: { state.theme.mode },
                    set: { state.theme.set($0) })) {
                    ForEach(AppAppearance.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 320)

                Text(state.theme.mode.detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Native.tertiary)
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: Service

    private var serviceCard: some View {
        Card("服务",
             subtitle: "\(state.activeEngine.displayName) 的本地 OpenAI 兼容接口") {
            VStack(spacing: 2) {
                settingRow("端口", detail: "当前引擎监听的本地端口，改完立即切换") {
                    TextField("端口", text: $portText)
                        .textFieldStyle(.roundedBorder)
                        .font(Native.monoFont)
                        .frame(width: 100)
                    Button("应用") {
                        if let port = Int(portText.trimmingCharacters(in: .whitespaces)),
                           (1024...65535).contains(port) {
                            state.switchEnginePort(state.activeEngine, port: port)
                            state.toast("端口已改为 \(port)")
                        } else {
                            state.toast("端口需在 1024–65535 之间")
                        }
                    }
                    .buttonStyle(ArcadePillStyle(tone: .glass, compact: true))
                }
                Hairline()
                settingRow("随 flashCat 启动", detail: "打开应用时自动拉起推理服务") {
                    Toggle("", isOn: Binding(
                        get: { state.settings.autoStart },
                        set: { state.settings.setAutoStart($0) }))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                }
                Hairline()
                settingRow("登录时启动", detail: "把 flashCat 加入 macOS 登录项") {
                    Toggle("", isOn: Binding(
                        get: { state.settings.launchAtLogin },
                        set: { value in
                            state.settings.setLaunchAtLogin(value)
                            LoginItem.set(enabled: value)
                        }))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                }
                Hairline()
                settingRow("接口地址", detail: "客户端直接连这个地址；换引擎不用改") {
                    Text(state.endpointURL)
                        .font(Native.monoFont)
                        .foregroundStyle(Native.secondary)
                        .textSelection(.enabled)
                    Button("复制") { state.copy(state.endpointURL, label: "接口地址已复制") }
                        .buttonStyle(ArcadePillStyle(tone: .glass, compact: true))
                }
            }
        }
    }

    // MARK: Gateway

    private var gatewayCard: some View {
        Card("API 网关",
             subtitle: "OpenAI 与 Claude 双格式的统一本地接口，固定端口") {
            VStack(spacing: 2) {
                settingRow("启用网关", detail: "关闭后只保留引擎直连端口") {
                    Toggle("", isOn: Binding(
                        get: { state.settings.gatewayEnabled },
                        set: { value in
                            state.settings.setGatewayEnabled(value)
                            state.applyGatewaySettings()
                        }))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                }
                Hairline()
                settingRow("网关端口", detail: "独立于引擎端口；改完点「应用」立即重启网关") {
                    TextField("端口", text: $gatewayPortText)
                        .textFieldStyle(.roundedBorder)
                        .font(Native.monoFont)
                        .frame(width: 100)
                    Button("应用") {
                        if let port = Int(gatewayPortText.trimmingCharacters(in: .whitespaces)),
                           (1024...65535).contains(port) {
                            state.settings.setGatewayPort(port)
                            state.applyGatewaySettings()
                            state.toast("网关端口已改为 \(port)")
                        } else {
                            state.toast("端口需在 1024–65535 之间")
                        }
                    }
                    .buttonStyle(ArcadePillStyle(tone: .glass, compact: true))
                }
                Hairline()
                settingRow("OpenAI 地址", detail: "POST /v1/chat/completions · GET /v1/models") {
                    Text(state.gatewayURL)
                        .font(Native.monoFont)
                        .foregroundStyle(Native.secondary)
                        .textSelection(.enabled)
                    Button("复制") { state.copy(state.gatewayURL, label: "OpenAI 接口地址已复制") }
                        .buttonStyle(ArcadePillStyle(tone: .glass, compact: true))
                }
                Hairline()
                settingRow("Claude 地址", detail: "POST /v1/messages · /v1/messages/count_tokens") {
                    Text(state.gatewayClaudeURL)
                        .font(Native.monoFont)
                        .foregroundStyle(Native.secondary)
                        .textSelection(.enabled)
                    Button("复制") { state.copy(state.gatewayClaudeURL, label: "Claude 接口地址已复制") }
                        .buttonStyle(ArcadePillStyle(tone: .glass, compact: true))
                }
            }
        }
    }

    // MARK: Chat defaults

    private var chatDefaultsCard: some View {
        Card("生成默认值", subtitle: "新对话从这里取默认参数；单次对话可在对话页调整") {
            VStack(spacing: 2) {
                settingRow("思考模式", detail: "自动跟随模型模板，或强制开/关") {
                    Picker("", selection: Binding(
                        get: { state.settings.thinkingMode },
                        set: { state.settings.setThinkingMode($0) })) {
                        ForEach(ThinkingMode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 220)
                }
                Hairline()
                settingRow("推理等级", detail: "只在思考模式为「开启」时生效") {
                    Picker("", selection: Binding(
                        get: { state.settings.reasoningEffort },
                        set: { state.settings.setReasoningEffort($0) })) {
                        ForEach(ReasoningEffort.allCases, id: \.self) { effort in
                            Text(effort.label).tag(effort)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 120)
                    .disabled(state.settings.thinkingMode != .on)
                }
                Hairline()
                settingRow("默认模型", detail: "新对话启动时选中的权重") {
                    Text(state.selectedModel.isEmpty ? "未选择" : state.shortModelName(state.selectedModel))
                        .font(Native.monoFont)
                        .foregroundStyle(Native.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("去模型页") { state.section = .models }
                        .buttonStyle(ArcadePillStyle(tone: .glass, compact: true))
                }
            }
        }
    }

    // MARK: Storage

    private var storageCard: some View {
        Card("存储", subtitle: "模型、运行时与日志的位置；可清理、可迁移") {
            VStack(spacing: 2) {
                settingRow("模型目录", detail: (EnginePaths.modelsRoot as NSString).abbreviatingWithTildeInPath) {
                    Button("打开") {
                        Paths.ensureDirectory(EnginePaths.modelsRoot)
                        NSWorkspace.shared.open(URL(fileURLWithPath: EnginePaths.modelsRoot))
                    }
                    .buttonStyle(ArcadePillStyle(tone: .glass, compact: true))
                }
                Hairline()
                settingRow("Hugging Face 缓存", detail: "留空则用引擎默认缓存目录") {
                    TextField("~/Library/Caches/huggingface", text: $cacheText)
                        .textFieldStyle(.roundedBorder)
                        .font(Native.monoSmall)
                        .frame(width: 240)
                    Button("应用") {
                        state.settings.setHfCache(cacheText.trimmingCharacters(in: .whitespaces))
                        state.toast("缓存目录已保存")
                    }
                    .buttonStyle(ArcadePillStyle(tone: .glass, compact: true))
                }
            }
        }
    }

    private var aboutCard: some View {
        Card("关于", subtitle: "本地推理控制台") {
            VStack(spacing: 2) {
                KeyValueRow(label: "版本", value: appVersion, mono: true)
                Hairline()
                KeyValueRow(label: "最低系统", value: "macOS 26.4", mono: true)
                Hairline()
                KeyValueRow(label: "引擎运行时", value: (EnginePaths.enginesDirectory as NSString).abbreviatingWithTildeInPath,
                            mono: true)
                Hairline()
                KeyValueRow(label: "已安装引擎", value: state.installedEngineIDs.map(\.displayName).joined(separator: " · "))
            }
        }
    }

    private var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "—"
    }

    private func settingRow<Content: View>(_ title: String, detail: String,
                                           @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Native.bodyFont)
                    .foregroundStyle(Native.label)
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(Native.tertiary)
                    .lineLimit(2)
            }
            Spacer(minLength: 12)
            content()
        }
        .padding(.vertical, 8)
    }
}
