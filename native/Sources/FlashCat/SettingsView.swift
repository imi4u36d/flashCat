import SwiftUI
import AppKit

// MARK: - Draft

private enum SettingsField: Hashable {
    case port
    case memory
    case context
    case model
    case extra
    case cache
}

/// Editable copy of the persisted settings. Equality of two normalized drafts is
/// what drives the save bar, so it can never claim changes that are not there.
private struct SettingsDraft: Equatable {
    var port = "8000"
    var maxMemory = ""
    var maxContext = ""
    var model = ""
    var extraArgs = ""
    var hfCache = ""
    var autoStart = false
    var launchAtLogin = false
    var idleReleaseOff = false
    var languageOnly = false
    var thinking: ThinkingMode = .automatic
    var effort: ReasoningEffort = .medium

    init() {}

    init(settings: AppSettings) {
        port = String(settings.port)
        maxMemory = settings.maxMemory
        maxContext = settings.maxContext
        model = settings.model
        extraArgs = settings.extraArgs
        hfCache = settings.hfCache
        autoStart = settings.autoStart
        launchAtLogin = settings.launchAtLogin
        idleReleaseOff = settings.idleReleaseOff
        languageOnly = settings.languageOnly
        thinking = settings.thinkingMode
        effort = settings.reasoningEffort
    }

    var normalized: SettingsDraft {
        var value = self
        value.port = port.trimmingCharacters(in: .whitespacesAndNewlines)
        value.maxMemory = maxMemory.trimmingCharacters(in: .whitespacesAndNewlines)
        value.maxContext = maxContext.trimmingCharacters(in: .whitespacesAndNewlines)
        value.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        value.extraArgs = extraArgs.trimmingCharacters(in: .whitespacesAndNewlines)
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

/// Everything the running splash process was started with. A save restarts the
/// engine only when this changes and the service is live.
private struct EngineSignature: Equatable {
    var port: Int
    var model: String
    var maxMemory: String
    var maxContext: String
    var idleReleaseOff: Bool
    var languageOnly: Bool
    var thinking: ThinkingMode
    var effort: ReasoningEffort
    var extraArgs: [String]
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

    func prepare(_ settings: AppSettings) {
        guard loaded, let baseline else {
            reload(settings)
            return
        }
        if draft.normalized == baseline.normalized {
            reload(settings)
        }
    }

    func reload(_ settings: AppSettings) {
        draft = SettingsDraft(settings: settings)
        baseline = draft
        touched = []
        submitted = false
        loaded = true
    }

    func markTouched(_ field: SettingsField) {
        touched.insert(field)
    }
}

private enum RuntimeTarget: Equatable {
    case bundled
    case managed(String)

    var version: String? {
        if case .managed(let version) = self { return version }
        return nil
    }
}

// MARK: - Page

struct SettingsView: View {
    private static let loginItemFailure =
        "登录项设置失败：无法写入 ~/Library/LaunchAgents/\(LoginItem.label).plist，应用仍可正常使用。"

    @ObservedObject var state: AppState
    @StateObject private var store: SettingsDraftStore
    @State private var confirmReset = false
    @State private var confirmRuntimeSwitch = false
    @State private var pendingRuntime: RuntimeTarget?

    @MainActor
    init(state: AppState) {
        _state = ObservedObject(wrappedValue: state)
        let shared = SettingsDraftStore.shared
        if !shared.loaded { shared.reload(state.settings) }
        _store = StateObject(wrappedValue: shared)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Native.gap) {
                PageHeader(title: "设置", subtitle: "服务、模型与运行时的默认行为", eyebrow: "偏好设置")
                serviceCard
                performanceCard
                thinkingCard
                modelCard
                runtimeCard
                advancedCard
            }
            .padding(.horizontal, Native.pagePadding)
            .padding(.top, 30)
            .padding(.bottom, Native.pagePadding)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .safeAreaInset(edge: .bottom, spacing: 0) { saveBar }
        .onAppear { store.prepare(state.settings) }
        .onChange(of: state.selectedModel) { _, _ in
            // Follow model switches made from the toolbar, unless the page has
            // its own unsaved edits.
            store.prepare(state.settings)
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

    private var memoryIssue: String? {
        quantityIssue(draft.maxMemory, message: "格式例如 24G，留空表示自动")
    }

    private var contextIssue: String? {
        quantityIssue(draft.maxContext, message: "格式例如 256K，留空使用模型默认")
    }

    private func quantityIssue(_ raw: String, message: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        let pattern = "^[0-9]+(?:\\.[0-9]+)?\\s?[KMGTkmgt]?[Bb]?$"
        return SettingsPattern.test(pattern, text) ? nil : message
    }

    private var modelIssue: String? {
        let text = draft.normalized.model
        if text.isEmpty { return nil }
        let pattern = "^[\\w.-]+/[\\w.-]+(:\\w[\\w.-]*)?$"
        return SettingsPattern.test(pattern, text) ? nil : "格式应为 owner/repo 或 owner/repo:VARIANT"
    }

    private var extraIssue: String? {
        var quote: Character?
        for character in draft.extraArgs {
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            }
        }
        return quote == nil ? nil : "引号没有闭合"
    }

    private var cacheIssue: String? {
        let text = draft.normalized.hfCache
        if text.isEmpty { return nil }
        return text.hasPrefix("/") ? nil : "需要绝对路径，例如 /Users/name/hf-cache"
    }

    private var hasIssues: Bool {
        portIssue != nil || memoryIssue != nil || contextIssue != nil
            || modelIssue != nil || extraIssue != nil || cacheIssue != nil
    }

    // MARK: cards

    private var serviceCard: some View {
        SettingsCard(title: "服务", detail: "本地 OpenAI 兼容接口",
                     icon: "network", tint: Native.cyan,
                     trailing: AnyView(endpointTag)) {
            SettingsRow(title: "端口",
                        detail: "OpenAI 兼容接口监听的本地端口，可填 `1024`–`65535`",
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

    private var performanceCard: some View {
        SettingsCard(title: "性能", detail: "引擎资源上限与内存策略",
                     icon: "speedometer", tint: Native.mint) {
            SettingsRow(title: "内存上限",
                        detail: "传给引擎的 `--max-memory`，留空表示自动",
                        error: shownIssue(.memory, memoryIssue),
                        divider: false) {
                TextField("例如 24G", text: textBinding(\.maxMemory, .memory))
                    .textFieldStyle(.roundedBorder)
                    .font(Native.monoFont)
                    .frame(width: 112)
                    .invalidRing(shownIssue(.memory, memoryIssue) != nil)
                    .accessibilityLabel("内存上限")
            }
            SettingsRow(title: "上下文长度",
                        detail: "传给引擎的 `--max-context`，留空使用模型默认",
                        error: shownIssue(.context, contextIssue)) {
                TextField("例如 256K", text: textBinding(\.maxContext, .context))
                    .textFieldStyle(.roundedBorder)
                    .font(Native.monoFont)
                    .frame(width: 112)
                    .invalidRing(shownIssue(.context, contextIssue) != nil)
                    .accessibilityLabel("上下文长度")
            }
            SettingsRow(title: "空闲时保留权重",
                        detail: "关闭空闲释放，响应更快但常驻内存") {
                switchToggle($store.draft.idleReleaseOff, label: "空闲时保留权重")
            }
            SettingsRow(title: "仅语言模型",
                        detail: "跳过视觉与多模态部分，加载更快") {
                switchToggle($store.draft.languageOnly, label: "仅语言模型")
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

    private var runtimeCard: some View {
        SettingsCard(title: "运行时", detail: "应用内更新 splash 引擎",
                     icon: "bolt.fill", tint: Native.accent,
                     trailing: AnyView(runtimeTag)) {
            RuntimePanel(state: state) { target in
                requestSwitch(target)
            }
        }
        .alert("切换运行时？", isPresented: $confirmRuntimeSwitch, presenting: pendingRuntime) { target in
            Button("取消", role: .cancel) { pendingRuntime = nil }
            Button("切换并重启") {
                performSwitch(target)
                pendingRuntime = nil
            }
        } message: { target in
            Text(switchMessage(target))
        }
    }

    private var advancedCard: some View {
        SettingsCard(title: "高级", detail: "附加参数与下载位置",
                     icon: "slider.horizontal.3", tint: Native.gray) {
            SettingsRow(title: "额外参数",
                        detail: "原样追加到命令行，支持引号分组",
                        error: shownIssue(.extra, extraIssue),
                        divider: false) {
                TextField("例如 --draft-window 8", text: textBinding(\.extraArgs, .extra))
                    .textFieldStyle(.roundedBorder)
                    .font(Native.monoSmall)
                    .frame(width: 286)
                    .invalidRing(shownIssue(.extra, extraIssue) != nil)
                    .accessibilityLabel("额外参数")
            }
            SettingsRow(title: "下载缓存目录",
                        detail: "设置 `HF_HUB_CACHE`，留空使用默认位置",
                        error: shownIssue(.cache, cacheIssue)) {
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
            commandPreview
            resetRow
        }
        .alert("恢复默认设置？", isPresented: $confirmReset) {
            Button("取消", role: .cancel) {}
            Button("恢复默认", role: .destructive) { applyDefaults() }
        } message: {
            Text("端口、内存与上下文上限、额外参数、缓存目录和全部开关都会恢复默认值；默认模型保持不变。")
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

    // MARK: runtime state

    /// The updater is replaced when the runtime changes; ignore state that still
    /// belongs to the previous runtime until the new updater reports in.
    private var updateState: UpdateState {
        let value = state.update
        guard !value.version.isEmpty, value.version != state.runtimeVersion else { return value }
        return UpdateState(version: state.runtimeVersion)
    }

    private var runtimeTag: some View {
        switch updateState.phase {
        case .upToDate, .installed:
            return Tag(text: "已是最新", tone: .success)
        case .available:
            return Tag(text: "可更新", tone: .warning)
        case .failed:
            return Tag(text: "检查失败", tone: .danger)
        case .checking, .preparing, .downloading, .verifying, .installing:
            return Tag(text: "处理中", tone: .warning)
        case .idle:
            return Tag(text: EngineRuntime.managedVersion == nil ? "内置" : "应用内",
                       tone: .neutral)
        }
    }

    private func requestSwitch(_ target: RuntimeTarget) {
        if state.isRunning {
            pendingRuntime = target
            confirmRuntimeSwitch = true
        } else {
            performSwitch(target)
        }
    }

    private func performSwitch(_ target: RuntimeTarget) {
        switch target {
        case .bundled: state.switchRuntime(nil)
        case .managed(let version): state.switchRuntime(version)
        }
    }

    private func switchMessage(_ target: RuntimeTarget) -> String {
        let name = target.version.map { "splash \($0)" } ?? "内置运行时"
        return "推理服务会停止并切换到 \(name)，正在进行的生成会中断。"
    }

    // MARK: advanced helpers

    private var previewCommand: String {
        let value = draft.normalized
        var parts = ["splash", "serve", "--model", value.model.isEmpty ? "<模型>" : value.model]
        if let port = value.portValue { parts += ["--port", String(port)] }
        if !value.maxMemory.isEmpty { parts += ["--max-memory", value.maxMemory] }
        if !value.maxContext.isEmpty { parts += ["--max-context", value.maxContext] }
        if value.idleReleaseOff { parts += ["--idle-release", "off"] }
        if value.languageOnly { parts.append("--language-only") }
        switch value.thinking {
        case .automatic:
            break
        case .off:
            parts += ["--default-reasoning-effort", "none"]
        case .on:
            parts += ["--default-reasoning-effort", value.effort.token]
        }
        if !value.extraArgs.isEmpty { parts.append(value.extraArgs) }
        return parts.joined(separator: " ")
    }

    private var commandPreview: some View {
        VStack(alignment: .leading, spacing: 7) {
            Hairline().opacity(0.65)
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                    .font(.system(size: 10))
                    .foregroundStyle(Native.tertiary)
                Text("将执行的命令")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Native.secondary)
                Spacer(minLength: 8)
                IconAction(systemName: "doc.on.doc", help: "复制命令") {
                    state.copy(previewCommand, label: "命令已复制")
                }
                .accessibilityLabel("复制命令")
            }
            Text(previewCommand)
                .font(Native.monoSmall)
                .foregroundStyle(Native.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(9)
                .background(Native.surface.opacity(0.65),
                            in: RoundedRectangle(cornerRadius: Native.radiusSmall, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Native.radiusSmall, style: .continuous)
                        .stroke(Native.hairline.opacity(0.7), lineWidth: 1)
                )
        }
        .padding(.horizontal, Native.cardPadding)
        .padding(.top, 11)
        .padding(.bottom, 12)
    }

    private var resetRow: some View {
        VStack(spacing: 0) {
            Hairline().opacity(0.65)
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("恢复默认设置")
                        .font(.system(size: 12.5, weight: .medium))
                    Text("端口、上限、附加参数与全部开关恢复默认值")
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
        return draft.normalized != SettingsDraft(settings: state.settings).normalized
    }

    private func signature(_ value: SettingsDraft, fallbackModel: String) -> EngineSignature {
        let normalized = value.normalized
        return EngineSignature(
            port: normalized.portValue ?? 0,
            model: normalized.model.isEmpty ? fallbackModel : normalized.model,
            maxMemory: normalized.maxMemory,
            maxContext: normalized.maxContext,
            idleReleaseOff: normalized.idleReleaseOff,
            languageOnly: normalized.languageOnly,
            thinking: normalized.thinking,
            effort: normalized.effort,
            extraArgs: AppSettings.splitArguments(normalized.extraArgs),
            hfCache: normalized.hfCache
        )
    }

    private var engineAffected: Bool {
        guard store.loaded else { return false }
        let fallback = state.selectedModel.isEmpty ? state.settings.model : state.selectedModel
        let stored = SettingsDraft(settings: state.settings)
        return signature(draft, fallbackModel: fallback) != signature(stored, fallbackModel: fallback)
    }

    private var changedLabels: [String] {
        let now = draft.normalized
        let old = SettingsDraft(settings: state.settings).normalized
        var labels: [String] = []
        if now.port != old.port { labels.append("端口") }
        if now.maxMemory != old.maxMemory { labels.append("内存上限") }
        if now.maxContext != old.maxContext { labels.append("上下文长度") }
        if now.idleReleaseOff != old.idleReleaseOff { labels.append("权重保留") }
        if now.languageOnly != old.languageOnly { labels.append("仅语言模型") }
        if now.thinking != old.thinking { labels.append("思考模式") }
        if now.effort != old.effort { labels.append("推理等级") }
        if now.model != old.model { labels.append("默认模型") }
        if now.autoStart != old.autoStart { labels.append("随应用启动") }
        if now.launchAtLogin != old.launchAtLogin { labels.append("登录时启动") }
        if now.extraArgs != old.extraArgs { labels.append("额外参数") }
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
        let fallback = state.selectedModel.isEmpty ? settings.model : state.selectedModel
        let before = signature(SettingsDraft(settings: settings), fallbackModel: fallback)

        let value = draft.normalized
        settings.setPort(port)
        settings.setMaxMemory(value.maxMemory)
        settings.setMaxContext(value.maxContext)
        settings.setExtraArgs(value.extraArgs)
        settings.setHfCache(value.hfCache)
        settings.setIdleReleaseOff(draft.idleReleaseOff)
        settings.setLanguageOnly(draft.languageOnly)
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
        }
        state.reloadModels()

        let updatedModel = state.selectedModel.isEmpty ? settings.model : state.selectedModel
        let after = signature(SettingsDraft(settings: settings), fallbackModel: updatedModel)
        let engineAffectedNow = after != before
        let runtimeReady = state.runtimeMissing == nil
        let shouldRestart = runtimeReady && (restart || (running && engineAffectedNow))

        store.reload(settings)
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
        store.reload(state.settings)
        state.toast("已放弃更改")
    }

    private func applyDefaults() {
        store.draft.port = "8000"
        store.draft.maxMemory = ""
        store.draft.maxContext = ""
        store.draft.extraArgs = ""
        store.draft.hfCache = ""
        store.draft.autoStart = false
        store.draft.launchAtLogin = false
        store.draft.idleReleaseOff = false
        store.draft.languageOnly = false
        store.draft.thinking = .automatic
        store.draft.effort = .medium
        store.touched = []
        store.submitted = false
    }
}

// MARK: - Runtime panel

private struct RuntimePanel: View {
    @ObservedObject var state: AppState
    let onSwitch: (RuntimeTarget) -> Void

    private var update: UpdateState {
        let value = state.update
        guard !value.version.isEmpty, value.version != state.runtimeVersion else { return value }
        return UpdateState(version: state.runtimeVersion)
    }
    private var managedVersion: String? { EngineRuntime.managedVersion }
    private var canInstall: Bool { update.phase == .available }

    private var currentVersion: String {
        update.version.isEmpty ? state.runtimeVersion : update.version
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusRow
            Hairline().opacity(0.65)
            installedList
            Hairline().opacity(0.65)
            bundledFooter
        }
    }

    private var statusRow: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Native.accent.opacity(0.12))
                Image(systemName: "bolt.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Native.accent)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("splash \(currentVersion)")
                        .font(.system(size: 12.5, weight: .semibold))
                    if update.phase == .available, let available = update.availableVersion {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Native.tertiary)
                        Text("splash \(available)")
                            .font(Native.monoSmall)
                            .foregroundStyle(Native.accent)
                    }
                }
                Text(statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(Native.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if update.phase == .failed, let message = update.message {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(Native.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let missing = state.runtimeMissing {
                    Text(missing)
                        .font(.system(size: 11))
                        .foregroundStyle(Native.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if update.busy, let progress = update.progress {
                    VStack(alignment: .leading, spacing: 4) {
                        Meter(fraction: progress)
                            .frame(width: 220)
                        Text("\(Int((progress * 100).rounded()))%")
                            .font(.system(size: 10))
                            .foregroundStyle(Native.tertiary)
                    }
                    .padding(.top, 3)
                }
            }

            Spacer(minLength: 12)
            actions
        }
        .padding(.horizontal, Native.cardPadding)
        .padding(.vertical, 13)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if update.busy, update.progress == nil {
                ProgressView().controlSize(.small)
            }
            if canInstall {
                IconAction(systemName: "arrow.clockwise", help: "重新检查更新") { check() }
                    .accessibilityLabel("重新检查更新")
                    .disabled(update.busy || state.updater == nil)
                Button("安装更新") { install() }
                    .buttonStyle(ArcadePillStyle(tone: .accent, compact: true))
                    .disabled(update.busy || state.updater == nil)
            } else {
                Button(checkLabel) { check() }
                    .buttonStyle(ArcadePillStyle(tone: .glass, compact: true))
                    .disabled(update.busy || state.updater == nil)
            }
        }
    }

    private var installedList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("应用内运行时")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Native.secondary)
                .padding(.horizontal, Native.cardPadding)
            .padding(.top, 10)
            .padding(.bottom, 4)

            if state.installedRuntimes.isEmpty {
                Text("还没有安装其他运行时，检查更新可获取新版本。")
                    .font(.system(size: 11))
                    .foregroundStyle(Native.tertiary)
                    .padding(.horizontal, Native.cardPadding)
                    .padding(.bottom, 9)
            } else {
                ForEach(state.installedRuntimes, id: \.self) { version in
                    HStack(spacing: 7) {
                        Image(systemName: "shippingbox")
                            .font(.system(size: 10))
                            .foregroundStyle(Native.tertiary)
                        Text("splash \(version)")
                            .font(Native.monoSmall)
                        if managedVersion == version {
                            Tag(text: "当前", tone: .success)
                        }
                        Spacer(minLength: 10)
                        Button("切换") { onSwitch(.managed(version)) }
                            .buttonStyle(ArcadePillStyle(tone: .glass, compact: true))
                            .disabled(managedVersion == version || update.busy)
                    }
                    .padding(.horizontal, Native.cardPadding)
                    .padding(.vertical, 5)
                    .help(Paths.runtimesDirectory + "/" + version)
                }
                .padding(.bottom, 6)
            }
        }
    }

    private var bundledFooter: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("内置运行时")
                    .font(.system(size: 12.5, weight: .medium))
                Text("随应用打包的 splash \(SPLASH_VERSION)，切换后不再使用应用内版本")
                    .font(.system(size: 11))
                    .foregroundStyle(Native.tertiary)
            }
            Spacer(minLength: 12)
            Button("恢复内置运行时") { onSwitch(.bundled) }
                .buttonStyle(ArcadePillStyle(tone: .glass, compact: true))
                .disabled(managedVersion == nil || update.busy)
        }
        .padding(.horizontal, Native.cardPadding)
        .padding(.vertical, 11)
    }

    private var statusText: String {
        switch update.phase {
        case .idle:
            return managedVersion == nil
                ? "使用随应用打包的运行时"
                : "使用应用内安装的运行时，可检查 GitHub Release 获取新版本"
        case .checking:
            return "正在检查 GitHub Release…"
        case .upToDate:
            return "已是最新版本 · splash \(update.version)"
        case .available:
            return "可更新到 splash \(update.availableVersion ?? "新版本") · 当前 \(update.version)"
        case .preparing:
            return "正在获取更新校验值…"
        case .downloading:
            var text = "正在下载 splash \(update.availableVersion ?? "")"
            if let progress = update.progress {
                text += " · \(Int((progress * 100).rounded()))%"
            }
            return text
        case .verifying:
            return "正在校验 SHA-256…"
        case .installing:
            return "正在解包并切换运行时…"
        case .installed:
            return "splash \(update.version) 已启用"
        case .failed:
            return "检查更新失败，可重试"
        }
    }

    private var checkLabel: String {
        switch update.phase {
        case .installed: return "再检查"
        case .failed: return "重试"
        default: return "检查更新"
        }
    }

    private func check() {
        Task { await state.updater?.check() }
    }

    private func install() {
        Task { await state.updater?.install() }
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
