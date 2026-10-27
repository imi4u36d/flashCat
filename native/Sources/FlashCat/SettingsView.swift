import SwiftUI
import AppKit

// MARK: - Draft

private enum SettingsField: Hashable {
    case port
    case model
    case cache
}

/// Editable copy of the persisted settings. Equality of two normalized drafts is
/// what drives the save bar, so it can never claim changes that are not there.
/// Engine-specific knobs (memory, context, draft model…) live on each engine's
/// own configuration page — this page only owns app-wide preferences.
private struct SettingsDraft: Equatable {
    var port = "8000"
    var model = ""
    var hfCache = ""
    var autoStart = false
    var launchAtLogin = false
    var thinking: ThinkingMode = .automatic
    var effort: ReasoningEffort = .medium

    init() {}

    init(settings: AppSettings, port: Int) {
        self.port = String(port)
        model = settings.model
        hfCache = settings.hfCache
        autoStart = settings.autoStart
        launchAtLogin = settings.launchAtLogin
        thinking = settings.thinkingMode
        effort = settings.reasoningEffort
    }

    var normalized: SettingsDraft {
        var value = self
        value.port = port.trimmingCharacters(in: .whitespacesAndNewlines)
        value.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        value.hfCache = SettingsDraft.expanded(hfCache)
        return value
    }

    var portValue: Int? {
        Int(port.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// `~/x` is convenient to type but the engine needs a real path in its env.
    static func expanded(_ path: String) -> String {
        let value = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if value == "~" { return Paths.home }
        if value.hasPrefix("~/") { return Paths.home + "/" + String(value.dropFirst(2)) }
        return value
    }
}

/// Everything the running engine was started with. A save restarts it only when
/// this changes and the service is live.
private struct EngineSignature: Equatable {
    var port: Int
    var model: String
    var thinking: ThinkingMode
    var effort: ReasoningEffort
    var hfCache: String
}

/// Keeps unsaved edits alive while the sidebar switches pages, and follows
/// settings written elsewhere as long as there is nothing unsaved.
private final class SettingsDraftStore: ObservableObject {
    static let shared = SettingsDraftStore()

    @Published var draft = SettingsDraft()
    @Published var touched: Set<SettingsField> = []
    @Published var submitted = false

    private var baseline: SettingsDraft?
    private(set) var loaded = false

    func prepare(_ settings: AppSettings, port: Int) {
        guard loaded, let baseline else {
            reload(settings, port: port)
            return
        }
        if draft.normalized == baseline.normalized {
            reload(settings, port: port)
        }
    }

    func reload(_ settings: AppSettings, port: Int) {
        draft = SettingsDraft(settings: settings, port: port)
        baseline = draft
        touched = []
        submitted = false
        loaded = true
    }

    func markTouched(_ field: SettingsField) {
        touched.insert(field)
    }
}

// MARK: - Page

struct SettingsView: View {
    private static let loginItemFailure =
        "登录项设置失败：无法写入 ~/Library/LaunchAgents/\(LoginItem.label).plist，应用仍可正常使用。"

    @ObservedObject var state: AppState
    /// Observed separately: the skin lives in its own object, and a nested
    /// `ObservableObject` would not republish through `AppState`.
    @ObservedObject private var theme: ThemeController
    @StateObject private var store: SettingsDraftStore
    @State private var confirmReset = false
    @Environment(\.colorScheme) private var colorScheme

    /// Port the active engine is configured to use: the same value the engine
    /// page edits, so the two views can never disagree.
    private var storedPort: Int {
        EngineStore.shared.configuration(for: state.activeEngine).port ?? state.activeEngine.defaultPort
    }

    @MainActor
    init(state: AppState) {
        _state = ObservedObject(wrappedValue: state)
        _theme = ObservedObject(wrappedValue: state.theme)
        let shared = SettingsDraftStore.shared
        let port = EngineStore.shared.configuration(for: state.activeEngine).port
            ?? state.activeEngine.defaultPort
        if !shared.loaded { shared.reload(state.settings, port: port) }
        _store = StateObject(wrappedValue: shared)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Native.gap) {
                PageHeader(title: "设置", subtitle: "服务、模型与默认行为", eyebrow: "偏好设置")
                appearanceCard
                serviceCard
                thinkingCard
                modelCard
                advancedCard
            }
            .padding(.horizontal, Native.pagePadding)
            .padding(.top, 30)
            .padding(.bottom, Native.pagePadding)
            .pageColumn()
        }
        .scrollIndicators(.never)
        .safeAreaInset(edge: .bottom, spacing: 0) { saveBar }
        .onAppear { store.prepare(state.settings, port: storedPort) }
        .onChange(of: state.selectedModel) { _, _ in
            // Follow model switches made from the toolbar, unless the page has
            // its own unsaved edits.
            store.prepare(state.settings, port: storedPort)
        }
        .onChange(of: state.activeEngine) { _, _ in
            store.prepare(state.settings, port: storedPort)
        }
    }

    // MARK: draft access

    private var draft: SettingsDraft { store.draft }

    private func textBinding(_ keyPath: WritableKeyPath<SettingsDraft, String>,
                             _ field: SettingsField) -> Binding<String> {
        Binding(
            get: { store.draft[keyPath: keyPath] },
            set: { value in
                store.draft[keyPath: keyPath] = value
                store.markTouched(field)
            }
        )
    }

    private var portBinding: Binding<String> {
        Binding(
            get: { store.draft.port },
            set: { value in
                store.draft.port = String(value.filter { $0.isNumber }.prefix(5))
                store.markTouched(.port)
            }
        )
    }

    private func switchToggle(_ binding: Binding<Bool>, label: String) -> some View {
        Toggle("", isOn: binding)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .accessibilityLabel(label)
    }

    private func shownIssue(_ field: SettingsField, _ message: String?) -> String? {
        guard let message else { return nil }
        return store.submitted || store.touched.contains(field) ? message : nil
    }

    // MARK: validation

    private var portIssue: String? {
        let text = draft.port.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "请填写端口号" }
        guard let value = Int(text) else { return "端口需要是数字" }
        if !(1024...65535).contains(value) {
            return "端口需要是 1024 到 65535 之间的数字"
        }
        return nil
    }

    private var modelIssue: String? {
        let text = draft.normalized.model
        if text.isEmpty { return nil }
        let pattern = "^[\\w.-]+/[\\w.-]+(:\\w[\\w.-]*)?$"
        return SettingsPattern.test(pattern, text) ? nil : "格式应为 owner/repo 或 owner/repo:VARIANT"
    }

    private var cacheIssue: String? {
        let text = draft.normalized.hfCache
        if text.isEmpty { return nil }
        return text.hasPrefix("/") ? nil : "需要绝对路径，例如 /Users/name/hf-cache"
    }

    private var hasIssues: Bool {
        portIssue != nil || modelIssue != nil || cacheIssue != nil
    }

    // MARK: cards

    /// Skin switch. Applied the moment it is picked — a pure presentation
    /// preference has nothing to validate, so it never waits for the save bar.
    private var appearanceCard: some View {
        SettingsCard(title: "外观",
                     detail: "日间 / 夜间皮肤，选择后立即生效",
                     icon: "circle.lefthalf.filled",
                     tint: Native.indigo,
                     trailing: AnyView(appearanceTag)) {
            SettingsRow(title: "外观模式",
                        detail: theme.mode.detail,
                        divider: false) {
                Picker("", selection: appearanceBinding) {
                    ForEach(AppAppearance.allCases) { mode in
                        Label(mode.label, systemImage: mode.symbol).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 286)
                .accessibilityLabel("外观模式")
                .help("跟随系统时随 macOS 的浅色 / 深色设置自动切换")
            }
        }
    }

    private var appearanceBinding: Binding<AppAppearance> {
        Binding(get: { theme.mode }, set: { theme.set($0) })
    }

    /// Shows what is on screen right now, which matters most in “跟随系统”.
    private var appearanceTag: some View {
        let dark = colorScheme == .dark
        return Tag(text: dark ? "夜间模式" : "日间模式",
                   tone: theme.mode == .system ? .neutral : .accent)
            .help(theme.mode == .system ? "当前由 macOS 外观决定" : "已手动指定皮肤")
    }

    private var serviceCard: some View {
        SettingsCard(title: "服务", detail: "本地 OpenAI 兼容接口",
                     icon: "network", tint: Native.cyan,
                     trailing: AnyView(endpointTag)) {
            SettingsRow(title: "端口",
                        detail: "当前引擎监听的本地端口，可填 `1024`–`65535`；单个引擎的端口也可在引擎页修改",
                        error: shownIssue(.port, portIssue),
                        divider: false) {
                TextField("8000", text: portBinding)
                    .textFieldStyle(.roundedBorder)
                    .font(Native.monoFont)
                    .frame(width: 92)
                    .invalidRing(shownIssue(.port, portIssue) != nil)
                    .accessibilityLabel("端口")
                    .help("本地接口端口")
            }
            SettingsRow(title: "随 flashCat 启动",
                        detail: "打开应用时自动拉起推理服务") {
                switchToggle($store.draft.autoStart, label: "随 flashCat 启动")
            }
            SettingsRow(title: "登录时启动",
                        detail: "把 flashCat 加入 macOS 登录项") {
                switchToggle($store.draft.launchAtLogin, label: "登录时启动")
            }
        }
    }

    private var thinkingCard: some View {
        SettingsCard(title: "思考", detail: "默认推理行为与推理等级",
                     icon: "brain.head.profile", tint: Native.violet) {
            SettingsRow(title: "思考模式",
                        detail: draft.thinking.detail,
                        divider: false) {
                Picker("", selection: $store.draft.thinking) {
                    ForEach(ThinkingMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 188)
                .accessibilityLabel("思考模式")
            }
            SettingsRow(title: "推理等级",
                        detail: "仅在思考模式为“开启”时生效") {
                Picker("", selection: $store.draft.effort) {
                    ForEach(ReasoningEffort.allCases, id: \.self) { effort in
                        Text(effort.label).tag(effort)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 104)
                .accessibilityLabel("推理等级")
                .disabled(draft.thinking != .on)
                .opacity(draft.thinking == .on ? 1 : 0.45)
                .help(draft.thinking == .on ? "默认推理等级" : "思考模式设为“开启”后生效")
            }
        }
    }

    private var modelCard: some View {
        SettingsCard(title: "模型", detail: "启动服务时默认加载的权重",
                     icon: "shippingbox.fill", tint: Native.amber) {
            SettingsRow(title: "默认模型",
                        detail: "从本地模型目录中选择，或填写下方自定义 ID",
                        divider: false) {
                Picker("", selection: modelSelection) {
                    ForEach(state.catalog.machine, id: \.id) { model in
                        Text(model.id).tag(model.id)
                    }
                    Text("自定义模型 ID…").tag("")
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 252)
                .accessibilityLabel("默认模型")
                .help("默认模型")
            }
            SettingsRow(title: "自定义模型 ID",
                        detail: "Hub 上的 `owner/repo`，可带 `:VARIANT`；留空沿用当前模型",
                        error: shownIssue(.model, modelIssue)) {
                HStack(spacing: 8) {
                    TextField("owner/repo", text: textBinding(\.model, .model))
                        .textFieldStyle(.roundedBorder)
                        .font(Native.monoSmall)
                        .frame(width: 222)
                        .invalidRing(shownIssue(.model, modelIssue) != nil)
                        .accessibilityLabel("自定义模型 ID")
                    if !draft.normalized.model.isEmpty {
                        Tag(text: modelKnown ? "已安装" : "Hub",
                            tone: modelKnown ? .success : .neutral)
                    }
                }
            }
        }
    }

    private var advancedCard: some View {
        SettingsCard(title: "高级", detail: "下载位置",
                     icon: "slider.horizontal.3", tint: Native.gray) {
            SettingsRow(title: "下载缓存目录",
                        detail: "设置 `HF_HUB_CACHE`，留空使用默认位置",
                        error: shownIssue(.cache, cacheIssue),
                        divider: false) {
                HStack(spacing: 6) {
                    TextField("留空使用默认目录", text: textBinding(\.hfCache, .cache))
                        .textFieldStyle(.roundedBorder)
                        .font(Native.monoSmall)
                        .frame(width: 248)
                        .invalidRing(shownIssue(.cache, cacheIssue) != nil)
                        .accessibilityLabel("下载缓存目录")
                    Button {
                        chooseCacheDirectory()
                    } label: {
                        Image(systemName: "folder")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("选择缓存目录")
                    .help("选择 Hugging Face 缓存目录")
                }
            }
            resetRow
        }
        .alert("恢复默认设置？", isPresented: $confirmReset) {
            Button("取消", role: .cancel) {}
            Button("恢复默认", role: .destructive) { applyDefaults() }
        } message: {
            Text("端口、缓存目录和全部开关都会恢复默认值；默认模型与各引擎的配置保持不变。")
        }
    }

    // MARK: service helpers

    private var effectivePortText: String {
        if state.isRunning { return String(state.port) }
        if portIssue == nil, let value = draft.portValue { return String(value) }
        return String(state.port)
    }

    private var endpointHelp: String {
        guard state.isRunning else { return "服务未运行" }
        if portIssue == nil, let value = draft.portValue, value != state.port {
            return "服务运行中；保存并重启后切换到端口 \(value)"
        }
        return "服务运行中"
    }

    private var endpointTag: some View {
        HStack(spacing: 5) {
            StatusDot(color: state.isRunning ? Native.green : Native.secondary, diameter: 6)
            Text("127.0.0.1:\(effectivePortText)")
                .font(Native.monoSmall)
                .foregroundStyle(Native.secondary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.3),
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(Native.hairline.opacity(0.7), lineWidth: 1)
        )
        .help(endpointHelp)
    }

    // MARK: model helpers

    private var modelSelection: Binding<String> {
        Binding(
            get: {
                let value = store.draft.normalized.model
                return state.catalog.machine.contains { $0.id == value } ? value : ""
            },
            set: { value in
                store.draft.model = value
                store.markTouched(.model)
            }
        )
    }

    private var modelKnown: Bool {
        let value = store.draft.normalized.model
        return state.catalog.machine.contains { $0.id == value }
    }

    // MARK: advanced helpers

    private var resetRow: some View {
        VStack(spacing: 0) {
            Hairline().opacity(0.65)
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("恢复默认设置")
                        .font(.system(size: 12.5, weight: .medium))
                    Text("端口、缓存目录与全部开关恢复默认值")
                        .font(.system(size: 11))
                        .foregroundStyle(Native.tertiary)
                }
                Spacer(minLength: 12)
                Button("恢复默认…") { confirmReset = true }
                    .buttonStyle(.bordered)
                    .tint(Native.red)
            }
            .padding(.horizontal, Native.cardPadding)
            .padding(.vertical, 11)
            .background(Native.red.opacity(0.05))
        }
    }

    private func chooseCacheDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.message = "选择 Hugging Face 下载缓存目录"
        let current = draft.normalized.hfCache
        panel.directoryURL = URL(fileURLWithPath: Paths.fileExists(current) ? current : Paths.home)
        if panel.runModal() == .OK, let url = panel.url {
            store.draft.hfCache = url.path
            store.markTouched(.cache)
        }
    }

    // MARK: save bar

    private var isDirty: Bool {
        guard store.loaded else { return false }
        return draft.normalized != SettingsDraft(settings: state.settings, port: storedPort).normalized
    }

    private func signature(_ value: SettingsDraft, fallbackModel: String) -> EngineSignature {
        let normalized = value.normalized
        return EngineSignature(
            port: normalized.portValue ?? 0,
            model: normalized.model.isEmpty ? fallbackModel : normalized.model,
            thinking: normalized.thinking,
            effort: normalized.effort,
            hfCache: normalized.hfCache
        )
    }

    private var engineAffected: Bool {
        guard store.loaded else { return false }
        let fallback = state.selectedModel.isEmpty ? state.settings.model : state.selectedModel
        let stored = SettingsDraft(settings: state.settings, port: storedPort)
        return signature(draft, fallbackModel: fallback) != signature(stored, fallbackModel: fallback)
    }

    private var changedLabels: [String] {
        let now = draft.normalized
        let old = SettingsDraft(settings: state.settings, port: storedPort).normalized
        var labels: [String] = []
        if now.port != old.port { labels.append("端口") }
        if now.thinking != old.thinking { labels.append("思考模式") }
        if now.effort != old.effort { labels.append("推理等级") }
        if now.model != old.model { labels.append("默认模型") }
        if now.autoStart != old.autoStart { labels.append("随应用启动") }
        if now.launchAtLogin != old.launchAtLogin { labels.append("登录时启动") }
        if now.hfCache != old.hfCache { labels.append("缓存目录") }
        return labels
    }

    private var changedSummary: String {
        let labels = changedLabels
        guard !labels.isEmpty else { return "有未保存的更改" }
        let head = labels.prefix(3).joined(separator: "、")
        return labels.count > 3 ? "\(head) 等 \(labels.count) 项已修改" : "\(head) 已修改"
    }

    private var saveBar: some View {
        HStack(spacing: 10) {
            StatusDot(color: isDirty ? Native.orange : Native.green, diameter: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(isDirty ? "设置已修改，尚未保存" : "没有未保存的更改")
                    .font(.system(size: 12, weight: .medium))
                Text(isDirty ? changedSummary : "改动会写入本地配置")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Native.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)

            // Only offer actions while there is something to save. Saving with a
            // live engine already restarts it, so a third "save and restart"
            // button would duplicate the primary action.
            if isDirty {
                if engineAffected {
                    if state.isRunning {
                        Tag(text: "保存后自动重启", tone: .warning)
                    } else {
                        Button("保存并启动服务") { save(restart: true) }
                            .buttonStyle(ArcadePillStyle(tone: .accent, compact: true))
                            .help("保存后启动推理服务")
                    }
                }
                Button("放弃更改") { discard() }
                    .buttonStyle(ArcadePillStyle(tone: .glass, compact: true))
                Button("保存") { save(restart: false) }
                    .buttonStyle(ArcadePillStyle(tone: .light, compact: true))
                    .keyboardShortcut("s", modifiers: .command)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Hairline() }
    }

    // MARK: actions

    private func save(restart: Bool) {
        store.submitted = true
        guard !hasIssues else {
            state.toast("请先修正标红的设置")
            return
        }
        let settings = state.settings
        guard let port = draft.portValue, (1024...65535).contains(port) else {
            state.toast("端口需要是 1024 到 65535 之间的数字")
            return
        }

        let running = state.isRunning
        let engine = state.activeEngine
        let fallback = state.selectedModel.isEmpty ? settings.model : state.selectedModel
        let before = signature(SettingsDraft(settings: settings, port: storedPort), fallbackModel: fallback)

        let value = draft.normalized
        // The engine's own port lives in EngineStore — the single source the
        // engines page edits too.
        state.switchEnginePort(engine, port: port)
        settings.setHfCache(value.hfCache)
        settings.setThinkingMode(draft.thinking)
        settings.setReasoningEffort(draft.effort)
        settings.setAutoStart(draft.autoStart)

        var loginIssue = false
        let desiredLogin = draft.launchAtLogin
        if desiredLogin != settings.launchAtLogin || desiredLogin != LoginItem.enabled {
            LoginItem.set(enabled: desiredLogin)
            if LoginItem.enabled == desiredLogin {
                settings.setLaunchAtLogin(desiredLogin)
            } else {
                loginIssue = true
                state.notice = Self.loginItemFailure
            }
        }
        if !loginIssue, state.notice == Self.loginItemFailure {
            state.notice = nil
        }

        if !value.model.isEmpty, value.model != settings.model {
            state.selectModel(value.model)
            state.engines?.setModel(value.model, for: engine)
        }
        state.reloadModels()

        let updatedModel = state.selectedModel.isEmpty ? settings.model : state.selectedModel
        let after = signature(SettingsDraft(settings: settings, port: port), fallbackModel: updatedModel)
        let engineAffectedNow = after != before
        let runtimeReady = state.runtimeMissing == nil
        let shouldRestart = runtimeReady && (restart || (running && engineAffectedNow))

        store.reload(settings, port: port)
        if shouldRestart {
            state.restartService()
        }

        if shouldRestart {
            state.toast(running ? "设置已保存，正在重启服务" : "设置已保存，正在启动服务")
        } else if restart, !runtimeReady {
            state.toast("设置已保存，但运行时缺失，无法重启服务")
        } else if loginIssue {
            state.toast("设置已保存，登录项设置失败")
        } else {
            state.toast("设置已保存")
        }
    }

    private func discard() {
        store.reload(state.settings, port: storedPort)
        state.toast("已放弃更改")
    }

    private func applyDefaults() {
        store.draft.port = String(state.activeEngine.defaultPort)
        store.draft.hfCache = ""
        store.draft.autoStart = false
        store.draft.launchAtLogin = false
        store.draft.thinking = .automatic
        store.draft.effort = .medium
        store.touched = []
        store.submitted = false
    }
}

// MARK: - Validation helper

/// Only asks whether the pattern matches. `NSTextCheckingResult` raises when a
/// capture-group index is past the pattern's group count, so nothing is indexed.
private enum SettingsPattern {
    static func test(_ pattern: String, _ text: String) -> Bool {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return false
        }
        let range = NSRange(location: 0, length: text.utf16.count)
        return expression.firstMatch(in: text, options: [], range: range) != nil
    }
}

// MARK: - Layout primitives

private struct SettingsCard<Content: View>: View {
    let title: String
    let detail: String
    var icon: String = "gearshape.fill"
    var tint: Color = Native.violet
    let trailing: AnyView?
    private let content: () -> Content

    init(title: String,
         detail: String,
         icon: String = "gearshape.fill",
         tint: Color = Native.violet,
         trailing: AnyView? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.detail = detail
        self.icon = icon
        self.tint = tint
        self.trailing = trailing
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 11) {
                ArcadeIcon(symbol: icon,
                           colors: [tint, tint.opacity(0.55)],
                           size: 32,
                           glyphScale: 0.44,
                           glow: false)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                    Text(detail)
                        .font(Native.calloutFont)
                        .foregroundStyle(Native.tertiary)
                }
                Spacer(minLength: 8)
                if let trailing { trailing }
            }
            .padding(.horizontal, Native.cardPadding)
            .padding(.top, 15)
            .padding(.bottom, 13)

            Hairline()
            VStack(alignment: .leading, spacing: 0) { content() }
        }
        .background { GlassSurface(radius: Native.radiusPanel) }
        .clipShape(RoundedRectangle(cornerRadius: Native.radiusPanel, style: .continuous))
    }
}

private struct SettingsRow<Control: View>: View {
    let title: String
    let detail: String
    let error: String?
    let divider: Bool
    private let control: () -> Control

    init(title: String,
         detail: String,
         error: String? = nil,
         divider: Bool = true,
         @ViewBuilder control: @escaping () -> Control) {
        self.title = title
        self.detail = detail
        self.error = error
        self.divider = divider
        self.control = control
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if divider {
                Hairline().opacity(0.65)
            }
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 12.5, weight: .medium))
                    SettingDetail(text: detail)
                }
                Spacer(minLength: 12)
                control()
            }
            .padding(.horizontal, Native.cardPadding)
            .padding(.vertical, 11)

            if let error {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 10))
                    Text(error).font(.system(size: 11))
                }
                .foregroundStyle(Native.red)
                .padding(.horizontal, Native.cardPadding)
                .padding(.bottom, 9)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Description with `--flags` and env names in a small monospaced face.
private struct SettingDetail: View {
    let text: String

    private var composed: Text {
        let pattern = "`[^`]+`|--[A-Za-z0-9_-]+|HF_HUB_CACHE"
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return Text(verbatim: text)
        }
        let ns = text as NSString
        var output = Text(verbatim: "")
        var cursor = 0
        for match in expression.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if match.range.location > cursor {
                output = output + Text(verbatim: ns.substring(
                    with: NSRange(location: cursor, length: match.range.location - cursor)))
            }
            var token = ns.substring(with: match.range)
            if token.count >= 2, token.hasPrefix("`"), token.hasSuffix("`") {
                token = String(token.dropFirst().dropLast())
            }
            output = output + Text(verbatim: token)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Native.secondary)
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length {
            output = output + Text(verbatim: ns.substring(from: cursor))
        }
        return output
    }

    var body: some View {
        composed
            .font(.system(size: 11))
            .foregroundColor(Native.tertiary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private extension View {
    @ViewBuilder
    func invalidRing(_ active: Bool) -> some View {
        if active {
            overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(Native.red.opacity(0.75), lineWidth: 1)
            )
        } else {
            self
        }
    }
}
