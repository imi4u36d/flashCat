// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import FlashCatCore
import FlashCatKit
import SwiftUI

/// 设置页：按 WebUI 版式——左右两列卡片，行内即改即生效。
struct SettingsPage: View {
    enum FocusField: Hashable {
        case gatewayPort
        case controlPort
        case endpoint
        case token
        case cachePath
    }

    @ObservedObject var state: AppState
    /// 主题控制器单独观察：外观模式 / accent 家族变化时，设置页的分段与色板
    /// 要立刻跟上，但不把 mode 桥回 AppState（那会把窗口外观重置成系统浅色）。
    @ObservedObject var theme: ThemeController
    /// 壳层在布局这一拍量到的详情区尺寸；宽 / 窄版式直接由它决定。
    let pageSize: CGSize

    init(state: AppState, pageSize: CGSize) {
        _state = ObservedObject(wrappedValue: state)
        _theme = ObservedObject(wrappedValue: state.theme)
        self.pageSize = pageSize
    }
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

    private var isWide: Bool {
        pageSize.width >= Console.compactContentWidth
    }

    // 设置行的原位回执：保存落到字段上，不再弹「已保存」浮层。
    @StateObject var cacheFlash = ActionFlashState()
    @StateObject var gatewayPortFlash = ActionFlashState()
    @StateObject var controlPortFlash = ActionFlashState()
    @StateObject var endpointFlash = ActionFlashState()
    @StateObject var tokenFlash = ActionFlashState()
    @StateObject var cliCopyFlash = ActionFlashState()
    @StateObject var resetFlash = ActionFlashState()
    /// 输入不合法时的原因，挂在「应用」按钮的悬停提示上。
    @State var gatewayPortNote: String?
    @State var controlPortNote: String?
    @State var endpointNote: String?

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
        let horizontal = Console.pageHorizontalPadding(compact: !isWide)
        ScrollView {
            if isWide {
                HStack(alignment: .top, spacing: Console.pageSectionGap) {
                    settingsNav
                        .padding(8)
                        .frame(width: 164)
                        .dsSurface(radius: DS.Radius.card)

                    sectionContent(wide: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, horizontal)
                .padding(.top, Console.scrollTopInset(sidebarShown: state.showsSidebar))
                .padding(.bottom, Console.contentBottomInset)
            } else {
                VStack(alignment: .leading, spacing: Console.pageSectionGap) {
                    settingsMenu
                    sectionContent(wide: false)
                }
                .padding(.horizontal, horizontal)
                .padding(.top, Console.scrollTopInset(sidebarShown: state.showsSidebar))
                .padding(.bottom, Console.contentBottomInset)
            }
        }
        .scrollIndicators(.never)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .toolbar {
            ToolbarItem(id: DSToolbarSlot.title, placement: .navigation) {
                DSToolbarPageTitle(
                    title: "设置")
                    .padding(.leading, 15)
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(id: DSToolbarSlot.anchor, placement: .principal) {
                DSToolbarAnchor()
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(id: DSToolbarSlot.actions, placement: .primaryAction) {
                DSToolbarActionRow(state: state, compact: !isWide) {
                    settingsUpdateAction
                }
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .dsPageColumn()
        .onAppear(perform: load)
        .sheet(isPresented: $showsChatParameters) {
            ChatParametersSheet(state: state)
        }
        .alert(L10n.t("确认恢复默认设置？"), isPresented: $confirmingResetDefaults) {
            Button(L10n.t("恢复默认"), role: .destructive) {
                resetAllDefaults()
            }
            Button(L10n.t("取消"), role: .cancel) {}
        } message: {
            Text(L10n.t("将恢复外观、随应用启动、端口及默认对话参数，自定义系统提示也会清空。"))
        }
    }

    @ViewBuilder
    private var settingsUpdateAction: some View {
        if isWide {
            Button {
                checkForAppUpdate()
            } label: {
                HStack(spacing: 5) {
                    if appUpdateIsChecking {
                        ProgressView().controlSize(.small)
                    } else if appUpdateIsAvailable {
                        Circle().fill(DS.accent).frame(width: 5, height: 5)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(DS.text2)
                    }
                    Text(L10n.t(appUpdateLabel))
                }
            }
            .buttonStyle(.ds(.secondary, size: .regular))
            .disabled(appUpdateIsChecking)
            .help(L10n.t(appUpdateLabel))
        } else {
            Button {
                checkForAppUpdate()
            } label: {
                Group {
                    if appUpdateIsChecking {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(appUpdateIsAvailable ? DS.accent : DS.text2)
                    }
                }
                .frame(width: 28, height: 28)
                .background(DS.rect(DS.Radius.md).fill(DS.surface))
                .overlay(DS.rect(DS.Radius.md).strokeBorder(DS.line2, lineWidth: 1))
                .contentShape(DS.rect(DS.Radius.md))
            }
            .buttonStyle(.plain)
            .disabled(appUpdateIsChecking)
            .help(L10n.t(appUpdateLabel))
        }
    }

    private var appUpdateIsChecking: Bool {
        if case .checking = appUpdate { return true }
        return false
    }

    private var appUpdateIsAvailable: Bool {
        if case .available = appUpdate { return true }
        return false
    }

    private var appUpdateLabel: String {
        switch appUpdate {
        case .idle: return "检查更新"
        case .checking: return "检查中…"
        case .upToDate: return "已是最新"
        case .available: return "有新版"
        case .failed: return "重试"
        }
    }

    /// 设置不再是一页两列的长表：左侧分区，右侧只显示当前分区。
    /// 引擎端口自动分配、token 留在模型来源，设置页只保留真正全局的东西。
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
                ThemeColorCard(theme: state.theme)
                launchCard
                maintenanceCard
            case .models:
                sourceCard(wide: wide)
                cacheCard
            case .api:
                settingsHint("接口始终启用；改端口会重启对应的本机服务。")
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
        gatewayPort = String(state.settings.gatewayPort)
        controlPort = String(state.settings.controlPort)
        cachePath = state.settings.hfCache
        endpoint = state.settings.hfEndpoint
        token = state.settings.hfToken
    }
}
