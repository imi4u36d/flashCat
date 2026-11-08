import SwiftUI
import AppKit
import FlashCatKit

/// 单台引擎的配置面板：端口 + 该引擎真正认识的调优开关。
struct EngineConfigSheet: View {
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
        VStack(spacing: 0) {
            header
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: Native.gap) {
                    portCard
                    switchesCard
                    advancedCard
                }
                .padding(Native.pagePadding)
            }
            .scrollIndicators(.never)
            Hairline()
            footer
        }
        .frame(width: 580, height: 640)
        .sheetCanvas()
        .onAppear(perform: load)
    }

    private var header: some View {
        HStack(spacing: 10) {
            ArcadeIcon(symbol: engineSymbol(engine),
                       colors: [engineAccent(engine), engineAccent(engine).opacity(0.62)],
                       size: 30,
                       glyphScale: 0.44,
                       glow: false)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(engine.displayName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Native.label)
                    if isActive { Tag(text: "当前引擎", tone: .success) }
                }
                Text("\(installedVersion ?? L10n.t("未安装")) · 端口 \(portText.isEmpty ? "—" : portText)")
                    .font(.system(size: 11))
                    .foregroundStyle(Native.tertiary)
            }
            Spacer(minLength: 8)
            IconAction(systemName: "xmark", help: "关闭") { dismiss() }
        }
        .padding(.horizontal, Native.pagePadding)
        .padding(.vertical, 14)
    }

    private var portCard: some View {
        Card("端口", subtitle: "只监听 127.0.0.1；同一段内会跳过被占领的端口") {
            HStack(spacing: 10) {
                TextField("端口", text: $portText)
                    .textFieldStyle(.roundedBorder)
                    .font(Native.monoFont)
                    .frame(width: 110)
                Text("默认 \(engine.defaultPort) · 允许 \(engine.portRange.lowerBound)–\(engine.portRange.upperBound)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Native.tertiary)
                Spacer(minLength: 0)
            }
        }
    }

    private var switchesCard: some View {
        Card("调优", subtitle: "留空表示交给引擎自己的默认值") {
            VStack(alignment: .leading, spacing: 2) {
                switch engine.adapter {
                case .splash:
                    toggle("DFlash2 投机解码", binding: $tuning.dflash, default: EngineTuning.defaults(for: engine).dflash)
                    textField("最大内存", text: optionalText(\.maxMemory), placeholder: "24G")
                    textField("最大上下文", text: optionalText(\.maxContext), placeholder: "256K")
                    textField("PLE 内存", text: optionalText(\.pleMemory), placeholder: "2G / off")
                    toggle("关闭视觉预处理", binding: $tuning.languageOnly, default: false,
                           detail: "language-only：跳过视觉侧准备，纯文本更快")
                    toggle("常驻权重", binding: $tuning.idleReleaseOff, default: false,
                           detail: "idle-release off：空闲时不卸下权重")
                    toggle("PLE 表常驻 SSD", binding: $tuning.pleSSDOffload, default: true)
                case .omlx:
                    toggle("MTP 预测", binding: $tuning.mtp, default: true)
                    toggle("DFlash 草稿", binding: $tuning.dflash, default: false)
                    toggle("PLE 表常驻 SSD", binding: $tuning.pleSSDOffload, default: true)
                case .mtplx:
                    toggle("预加载 MTP 头", binding: $tuning.loadMtp, default: true)
                    intField("MTP 深度", value: $tuning.mtpDepth, placeholder: "自适应")
                    intField("MTP 头量化位宽", value: $tuning.mtpQuantBits, placeholder: "引擎默认")
                default:
                    toggle("MTP 预测", binding: $tuning.mtp, default: true)
                }
            }
        }
    }

    private var advancedCard: some View {
        Card("高级", subtitle: "思考预算与额外命令行参数") {
            VStack(alignment: .leading, spacing: 8) {
                intField("思考 token 预算", value: $tuning.thinkingBudget, placeholder: "不限制")
                HStack(alignment: .top, spacing: 8) {
                    Text("额外参数")
                        .font(Native.bodyFont)
                        .foregroundStyle(Native.secondary)
                        .frame(width: 96, alignment: .leading)
                    TextField("--flag value", text: optionalText(\.extraArguments))
                        .textFieldStyle(.roundedBorder)
                        .font(Native.monoFont)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("恢复默认") {
                tuning = EngineTuning.defaults(for: engine)
            }
            .buttonStyle(.arcadeGlass)
            Spacer(minLength: 0)
            Button("取消") { dismiss() }
                .buttonStyle(.arcadeGlass)
            Button("保存") { save() }
                .buttonStyle(.arcadePill)
        }
        .padding(.horizontal, Native.pagePadding)
        .padding(.vertical, 12)
    }

    // MARK: Helpers

    private func toggle(_ title: String, binding: Binding<Bool?>, default fallback: Bool? = nil,
                        detail: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.t(title))
                    .font(Native.bodyFont)
                    .foregroundStyle(Native.label)
                if let detail {
                    Text(L10n.t(detail))
                        .font(.system(size: 10))
                        .foregroundStyle(Native.tertiary)
                }
            }
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(
                get: { binding.wrappedValue ?? fallback ?? false },
                set: { binding.wrappedValue = $0 }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
        .padding(.vertical, 5)
    }

    private func textField(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        HStack(spacing: 10) {
            Text(L10n.t(title))
                .font(Native.bodyFont)
                .foregroundStyle(Native.label)
                .frame(width: 110, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(Native.monoFont)
        }
        .padding(.vertical, 3)
    }

    private func intField(_ title: String, value: Binding<Int?>, placeholder: String) -> some View {
        HStack(spacing: 10) {
            Text(L10n.t(title))
                .font(Native.bodyFont)
                .foregroundStyle(Native.label)
                .frame(width: 110, alignment: .leading)
            TextField(placeholder, text: Binding(
                get: { value.wrappedValue.map(String.init) ?? "" },
                set: { value.wrappedValue = Int($0.trimmingCharacters(in: .whitespaces)) }))
                .textFieldStyle(.roundedBorder)
                .font(Native.monoFont)
                .frame(width: 140)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }

    private func optionalText(_ keyPath: WritableKeyPath<EngineTuning, String?>) -> Binding<String> {
        Binding(get: { tuning[keyPath: keyPath] ?? "" },
                set: { tuning[keyPath: keyPath] = $0.isEmpty ? nil : $0 })
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        let configuration = EngineStore.shared.configuration(for: engine)
        tuning = configuration.tuning ?? EngineTuning()
        portText = String(configuration.port ?? engine.defaultPort)
    }

    private func save() {
        EngineStore.shared.setTuning(tuning.sanitized(), for: engine)
        if let port = Int(portText.trimmingCharacters(in: .whitespaces)),
           (1024...65535).contains(port),
           port != (EngineStore.shared.configuration(for: engine).port ?? engine.defaultPort) {
            state.switchEnginePort(engine, port: port)
        }
        Task { await state.engines?.controller(engine)?.reapplyTuning() }
        state.toast(L10n.format("%@ 的配置已保存", engine.displayName))
        dismiss()
    }
}
