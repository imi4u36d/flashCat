import SwiftUI
import AppKit
import FlashCatKit

/// 设置页：按 WebUI 版式——左右两列卡片，行内即改即生效。
struct SettingsPage: View {
    @ObservedObject var state: AppState
    @State private var ports: [String: String] = [:]
    @State private var gatewayPort = ""
    @State private var cachePath = ""

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 18) {
                VStack(spacing: 18) {
                    appearanceCard
                    launchCard
                    portsCard
                    cacheCard
                }
                VStack(spacing: 18) {
                    gatewayCard
                    thinkingCard
                    infoCard
                }
            }
            .padding(.horizontal, Console.contentPadding)
            .padding(.top, 78)
            .padding(.bottom, 26)
        }
        .scrollIndicators(.never)
        .onAppear(perform: load)
        .onChange(of: state.activeEngine) { _, _ in load() }
    }

    private func load() {
        var values: [String: String] = [:]
        for id in EngineCatalog.allIDs {
            values[id.rawValue] = String(EngineStore.shared.configuration(for: id).port ?? id.defaultPort)
        }
        ports = values
        gatewayPort = String(state.settings.gatewayPort)
        cachePath = state.settings.hfCache
    }

    // MARK: Left column

    private var appearanceCard: some View {
        SettingsCard {
            SettingsRow(title: "外观", detail: "跟随系统或固定外观") {
                segControl(options: AppAppearance.allCases.map { ($0.label, $0 == state.theme.mode) }) { index in
                    state.theme.set(AppAppearance.allCases[index])
                }
            }
        }
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
                .onSubmit { applyPort(id) }
            VStack(spacing: 0) {
                Button { stepPort(id, by: 1) } label: {
                    Image(systemName: "chevron.up").font(.system(size: 7, weight: .bold))
                }
                .buttonStyle(.plain)
                Button { stepPort(id, by: -1) } label: {
                    Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(Console.tertiary)
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

    private var cacheCard: some View {
        SettingsCard {
            SettingsRow(title: "下载缓存", detail: "Hugging Face 缓存目录，留空用默认") {
                HStack(spacing: 8) {
                    TextField("默认使用 HF_HUB_CACHE", text: $cachePath)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 220)
                        .padding(.horizontal, 9)
                        .frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Console.inset))
                    Button("应用") {
                        state.settings.setHfCache(cachePath.trimmingCharacters(in: .whitespaces))
                        state.toast("缓存目录已保存")
                    }
                    .buttonStyle(.consoleSoft)
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
                HStack(spacing: 4) {
                    Text(":")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Console.tertiary)
                    TextField("9000", text: $gatewayPort)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11.5, design: .monospaced))
                        .frame(width: 54)
                    Button("应用") {
                        if let port = Int(gatewayPort), (1024...65535).contains(port) {
                            state.settings.setGatewayPort(port)
                            state.applyGatewaySettings()
                        }
                    }
                    .buttonStyle(.consoleSoft)
                }
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 8).fill(Console.inset))
            }
        }
    }

    private var thinkingCard: some View {
        SettingsCard {
            SettingsRow(title: "思考模式", detail: "回答前是否输出推理过程") {
                segControl(options: ThinkingMode.allCases.map { ($0.label, $0 == state.settings.thinkingMode) }) { index in
                    state.settings.setThinkingMode(ThinkingMode.allCases[index])
                }
            }
            Divider().overlay(Console.insetStroke)
            SettingsRow(title: "默认模型", detail: state.selectedModel.isEmpty ? "未选择" : state.selectedModel) {
                Menu {
                    ForEach(EngineCatalog.allIDs.filter { state.engineIsInstalled($0) }, id: \.self) { id in
                        let models = state.engineModels(for: id)
                            .filter { !$0.hidden && !$0.helper && !ModelLibraryEntry.isDraftModel($0.id) }
                        if !models.isEmpty {
                            Section(id.displayName) {
                                ForEach(models) { model in
                                    Button {
                                        state.applyModelFromAnyEngine(model.id, engine: id)
                                    } label: {
                                        if model.id == state.selectedModel, id == state.activeEngine {
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
                segControl(options: ReasoningEffort.allCases.map { ($0.label, $0 == state.settings.reasoningEffort) }) { index in
                    state.settings.setReasoningEffort(ReasoningEffort.allCases[index])
                }
                .disabled(state.settings.thinkingMode != .on)
            }
        }
    }

    private var infoCard: some View {
        SettingsCard {
            infoRow("flashCat", detail: "本地推理控制台 · v\(appVersion)", trailing: device.chipName)
            Divider().overlay(Console.insetStroke)
            infoRow("这台 Mac", detail: "\(device.chipName) · \(device.memoryGB) GB 统一内存",
                    trailing: "可用 \(Format.size(Int(device.freeDiskBytes)))")
            Divider().overlay(Console.insetStroke)
            SettingsRow(title: "对话参数", detail: "温度 \(String(format: "%.1f", state.settings.temperature)) · Top P \(String(format: "%.2f", state.settings.topP)) · 最大输出 \(state.effectiveMaxTokens)") {
                Button("调整") { state.section = .chat }
                    .buttonStyle(.consoleSecondary)
            }
            Divider().overlay(Console.insetStroke)
            SettingsRow(title: "首次启动引导", detail: "重新打开引擎安装页") {
                Button("打开") { state.showsLaunchPage = true }
                    .buttonStyle(.consoleSecondary)
            }
            Divider().overlay(Console.insetStroke)
            SettingsRow(title: "恢复默认", detail: "外观、启动与网关设置") {
                Button("恢复") {
                    state.theme.set(.system)
                    state.settings.setAutoStart(false)
                    state.settings.setGatewayEnabled(true)
                    state.resetChatParameters()
                    state.applyGatewaySettings()
                    state.toast("已恢复默认设置")
                }
                .buttonStyle(.consoleSoft)
            }
        }
    }

    private func infoRow(_ title: String, detail: String, trailing: String) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Console.text)
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Console.tertiary)
            }
            Spacer(minLength: 8)
            Text(trailing)
                .font(.system(size: 10.5))
                .foregroundStyle(Console.tertiary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
    }

    private var device: DeviceProfile { DeviceProfile.current() }

    private var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "—"
    }

    // MARK: Parts

    private func segControl(options: [(String, Bool)], onSelect: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                Button {
                    withAnimation(Motion.quick) { onSelect(index) }
                } label: {
                    Text(option.0)
                        .font(.system(size: 11.5, weight: option.1 ? .semibold : .regular))
                        .foregroundStyle(option.1 ? Console.text : Console.secondary)
                        .padding(.horizontal, 11)
                        .frame(height: 26)
                        .background {
                            if option.1 {
                                RoundedRectangle(cornerRadius: 7).fill(Console.cardStrong)
                                    .shadow(color: Console.shadow.opacity(0.5), radius: 6, y: 1)
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(Console.inset))
        .clipShape(Capsule())
    }
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
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Console.text)
                if let detail {
                    Text(detail)
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
