import SwiftUI
import AppKit
import FlashCatKit

/// Per-engine configuration sheet. Every engine has the same shell — port,
/// model folder, log — and then the switches its own server actually understands:
/// oMLX takes MTP/DFlash through its settings API, MTPLX through CLI flags,
/// splash through `--draft`/`--language-only`/memory flags.
struct EngineConfigView: View {
    @ObservedObject var state: AppState
    let engine: EngineID

    @Environment(\.dismiss) private var dismiss
    @State private var tuning = EngineTuning()
    @State private var portText = ""
    @State private var loaded = false

    private var controller: EngineController? { state.engines?.controller(engine) }
    private var installedVersion: String? { controller?.installation.version }
    private var isActive: Bool { state.activeEngine == engine }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Native.hairline)
            ScrollView {
                VStack(alignment: .leading, spacing: Native.gap) {
                    generalCard
                    switch engine {
                    case .splash: splashCard
                    case .mtplx: mtplxCard
                    case .omlx: omlxCard
                    }
                    advancedCard
                }
                .padding(Native.pagePadding)
            }
            .scrollIndicators(.never)
            Divider().overlay(Native.hairline)
            footer
        }
        .frame(width: 560, height: 620)
        .background(Native.canvas)
        .onAppear(perform: load)
    }

    // MARK: chrome

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(engine.displayName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Native.label)
                    if isActive {
                        Tag(text: "当前引擎", tone: .success)
                    }
                }
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Native.tertiary)
            }
            Spacer(minLength: 8)
            Button("完成") { save() }
                .buttonStyle(ArcadePillStyle(tone: .accent, compact: true))
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, Native.pagePadding)
        .padding(.vertical, 14)
    }

    private var subtitle: String {
        let version = installedVersion ?? "未安装"
        let running = controller?.isRunning == true ? " · 运行中" : ""
        return "\(version)\(running) · 端口 \(portValue.map(String.init) ?? "—")"
    }

    private var footer: some View {
        HStack(spacing: 8) {
            StatusDot(color: state.isRunning && isActive ? Native.green : Native.secondary, diameter: 6)
            Text(hint)
                .font(.system(size: 10.5))
                .foregroundStyle(Native.tertiary)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button("取消") { dismiss() }
                .buttonStyle(ArcadePillStyle(tone: .glass, compact: true))
            Button("保存") { save() }
                .buttonStyle(ArcadePillStyle(tone: .light, compact: true))
        }
        .padding(.horizontal, Native.pagePadding)
        .padding(.vertical, 12)
    }

    /// CLI engines only read their switches at launch, so saying "restart to
    /// apply" up front is more honest than silently doing nothing.
    private var hint: String {
        if engine == .omlx {
            return "MTP / DFlash2 通过 oMLX 的设置接口按模型生效，保存后会重新加载当前模型。"
        }
        return "启动参数在下次启动时生效；保存后如需立即应用，请在引擎页重启。"
    }

    // MARK: cards

    private var generalCard: some View {
        EngineConfigCard(title: "基础", detail: "端口与模型目录", icon: "network") {
            row("端口", detail: "默认 \(engine.defaultPort)，可顺延 \(engine.portRange.count) 个") {
                TextField("\(engine.defaultPort)", text: $portText)
                    .textFieldStyle(.roundedBorder)
                    .font(Native.monoFont)
                    .frame(width: 92)
                    .disabled(isActive && state.isRunning)
            }
            row("模型目录", detail: EnginePaths.modelsDirectory(engine)) {
                Button("打开") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: EnginePaths.modelsDirectory(engine)))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            row("引擎日志", detail: "启动命令行与引擎输出") {
                Button("查看") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: EnginePaths.logFile(engine)))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var splashCard: some View {
        EngineConfigCard(title: "DFlash2", detail: "投机解码 draft 模型与资源上限", icon: "sparkles") {
            toggle("启用 DFlash2", detail: "用 draft 模型并行草稿，显著提升解码速度", isOn: dflashBinding)
            row("draft 目录", detail: "留空则自动选择与主模型匹配的 draft") {
                TextField("自动", text: optionalText(\.draftModel))
                    .textFieldStyle(.roundedBorder)
                    .font(Native.monoSmall)
                    .frame(width: 240)
                    .disabled(tuning.dflash == false)
            }
            row("内存上限", detail: "`--max-memory`，例如 24G；留空自动") {
                TextField("自动", text: optionalText(\.maxMemory))
                    .textFieldStyle(.roundedBorder)
                    .font(Native.monoFont)
                    .frame(width: 96)
            }
            row("上下文长度", detail: "`--max-context`，留空使用模型默认") {
                TextField("默认", text: optionalText(\.maxContext))
                    .textFieldStyle(.roundedBorder)
                    .font(Native.monoFont)
                    .frame(width: 96)
            }
            toggle("仅语言模型", detail: "跳过视觉与多模态部分，加载更快", isOn: boolBinding(\.languageOnly, default: false))
            toggle("空闲时保留权重", detail: "关闭空闲释放，响应更快但常驻内存", isOn: boolBinding(\.idleReleaseOff))
        }
    }

    private var mtplxCard: some View {
        EngineConfigCard(title: "MTP", detail: "多 token 预测", icon: "bolt.horizontal") {
            toggle("启用 MTP", detail: "`--mtp` / `--no-mtp`；关闭时不做投机解码", isOn: mtpBinding)
            toggle("启动即加载 MTP 权重", detail: "`--load-mtp`，避免首个请求才付出加载开销", isOn: boolBinding(\.loadMtp))
            row("量化位数", detail: "`--mtp-quant-bits`，留空使用引擎默认") {
                TextField("默认", text: numberText(\.mtpQuantBits, range: 2...16))
                    .textFieldStyle(.roundedBorder)
                    .font(Native.monoFont)
                    .frame(width: 72)
            }
        }
    }

    private var omlxCard: some View {
        EngineConfigCard(title: "MTP / DFlash2", detail: "按模型生效，两者互斥", icon: "bolt.horizontal") {
            toggle("启用 MTP", detail: "开启后关闭 DFlash2（oMLX 不允许同时开）", isOn: omlxMTPBinding)
            row("MTP 深度", detail: "留空为自适应；固定值优先", isOn: nil) {
                TextField("自适应", text: numberText(\.mtpDepth, range: 1...16))
                    .textFieldStyle(.roundedBorder)
                    .font(Native.monoFont)
                    .frame(width: 72)
                    .disabled(tuning.mtp != true)
            }
            toggle("启用 DFlash2", detail: "开启后关闭 MTP", isOn: dflashBinding)
            Text("这些开关由 oMLX 的 `/api/models/<id>/settings` 保存，因此对每个模型独立生效；保存后会重新加载当前模型，未加载的模型在下一次加载时应用。")
                .font(.system(size: 10.5))
                .foregroundStyle(Native.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var advancedCard: some View {
        EngineConfigCard(title: "高级", detail: "原样追加的启动参数", icon: "slider.horizontal.3") {
            TextField("例如 --no-webui --queue-size 8", text: optionalText(\.extraArguments))
                .textFieldStyle(.roundedBorder)
                .font(Native.monoSmall)
            Text("仅对该引擎生效，按空格切分并支持引号分组。")
                .font(.system(size: 10.5))
                .foregroundStyle(Native.tertiary)
        }
    }

    // MARK: rows

    private func row<Control: View>(_ title: String,
                                    detail: String,
                                    isOn: Bool? = nil,
                                    @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Native.label)
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Native.tertiary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            control()
        }
        .padding(.vertical, 6)
    }

    private func toggle(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Native.label)
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Native.tertiary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel(title)
        }
        .padding(.vertical, 6)
    }

    // MARK: bindings

    private func optionalText(_ keyPath: WritableKeyPath<EngineTuning, String?>) -> Binding<String> {
        Binding(
            get: { tuning[keyPath: keyPath] ?? "" },
            set: { tuning[keyPath: keyPath] = $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        )
    }

    private func numberText(_ keyPath: WritableKeyPath<EngineTuning, Int?>,
                            range: ClosedRange<Int>) -> Binding<String> {
        Binding(
            get: { tuning[keyPath: keyPath].map(String.init) ?? "" },
            set: { text in
                let digits = text.filter(\.isNumber)
                guard !digits.isEmpty, let value = Int(digits) else {
                    tuning[keyPath: keyPath] = nil
                    return
                }
                tuning[keyPath: keyPath] = min(max(value, range.lowerBound), range.upperBound)
            }
        )
    }

    /// `nil` means "engine default", so the toggle has to render and write it.
    private func boolBinding(_ keyPath: WritableKeyPath<EngineTuning, Bool?>,
                             default value: Bool = true) -> Binding<Bool> {
        Binding(
            get: { tuning[keyPath: keyPath] ?? value },
            set: { tuning[keyPath: keyPath] = $0 }
        )
    }

    private var dflashBinding: Binding<Bool> {
        Binding(
            get: { tuning.dflash ?? false },
            set: { value in
                tuning.dflash = value
                // oMLX rejects a model that has both heads on, so turning one
                // on turns the other off instead of surfacing a server error.
                if value { tuning.mtp = false }
            }
        )
    }

    private var mtpBinding: Binding<Bool> {
        Binding(
            get: { tuning.mtp ?? true },
            set: { tuning.mtp = $0 }
        )
    }

    /// oMLX rejects MTP together with DFlash, so turning one on turns the other
    /// off instead of saving a combination the engine would refuse.
    private var omlxMTPBinding: Binding<Bool> {
        Binding(
            get: { tuning.mtp == true },
            set: { value in
                tuning.mtp = value
                if value { tuning.dflash = false }
            }
        )
    }

    // MARK: actions

    private func load() {
        guard !loaded else { return }
        tuning = EngineStore.shared.tuning(for: engine)
        portText = String(EngineStore.shared.configuration(for: engine).port ?? engine.defaultPort)
        loaded = true
    }

    private var portValue: Int? {
        guard let value = Int(portText.trimmingCharacters(in: .whitespaces)), (1024...65535).contains(value) else {
            return nil
        }
        return value
    }

    private func save() {
        EngineStore.shared.setTuning(tuning.sanitized(), for: engine)
        if let port = portValue, port != EngineStore.shared.configuration(for: engine).port {
            state.switchEnginePort(engine, port: port)
        }
        if let tuning = EngineStore.shared.configuration(for: engine).tuning, tuning.omlxHeadsConflict {
            state.toast("oMLX 不允许 MTP 与 DFlash2 同时开启，已保留一个")
        }
        Task { await controller?.reapplyTuning() }
        state.toast("\(engine.displayName) 的配置已保存")
        dismiss()
    }
}

// MARK: - card

private struct EngineConfigCard<Content: View>: View {
    let title: String
    let detail: String
    let icon: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Native.accent)
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Native.label)
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Native.tertiary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Native.cardPadding)
            .padding(.top, 12)
            .padding(.bottom, 8)
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(.horizontal, Native.cardPadding)
            .padding(.bottom, 10)
        }
        .background {
            GlassSurface(radius: Native.radiusPanel, tint: .clear, elevated: false)
        }
    }
}
