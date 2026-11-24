// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import FlashCatCore
import FlashCatKit
import SwiftUI

/// 设置页：按 WebUI 版式——左右两列卡片，行内即改即生效。
struct SettingsPage: View {
    enum FocusField: Hashable {
        case enginePort(EngineID)
        case gatewayPort
        case controlPort
        case endpoint
        case token
        case cachePath
    }

    @ObservedObject var state: AppState
    @State var ports: [String: String] = [:]
    @State var gatewayPort = ""
    @State var controlPort = ""
    @State var cachePath = ""
    @State var endpoint = ""
    @State var token = ""
    @State var showsChatParameters = false
    @State var confirmingResetDefaults = false
    @FocusState var focusedField: FocusField?
    @State var device = DeviceProfile.current()
    /// 思考设置走 `@AppStorage` 而不是本地镜像：`AppSettings` 不是
    /// ObservableObject，只写 UserDefaults 不会触发 SwiftUI 重新求值。
    /// 观察这两个键之后，聊天浮层滑杆与这里的分段控件才能互相同步。
    @AppStorage("thinkingMode") var storedThinkingMode = ThinkingMode.automatic.rawValue
    @AppStorage("reasoningEffort") var storedReasoningEffort = ReasoningEffort.medium.rawValue
    @AppStorage("hubSource") var storedHubSource = HubSource.huggingFace.rawValue
    @AppStorage("chat.temperature") var storedTemperature = 0.7
    @AppStorage("chat.topP") var storedTopP = 0.95
    @AppStorage("chat.maxTokens") var storedMaxTokens = 0

    enum AppUpdateState {
        case idle
        case checking
        case upToDate
        case available(AppUpdateChecker.Release)
        case failed(String)
    }

    @State var appUpdate: AppUpdateState = .idle

    var hubSource: HubSource {
        HubSource(rawValue: storedHubSource) ?? .huggingFace
    }

    var thinkingMode: ThinkingMode {
        ThinkingMode(rawValue: storedThinkingMode) ?? .automatic
    }

    var reasoningEffort: ReasoningEffort {
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
    var settingsNav: some View {
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
    var settingsMenu: some View {
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
    func sectionContent(wide: Bool) -> some View {
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

    func settingsHint(_ text: String) -> some View {
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

    func load() {
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
}
