// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import FlashCatCore
import FlashCatKit
import SwiftUI

/// 单台引擎的配置面板：该引擎真正认识的调优开关。
struct EngineConfigSheet: View {
    @ObservedObject var state: AppState
    let engine: EngineID

    private enum ConfigField: Hashable {
        case maxMemory
        case maxContext
        case pleMemory
        case mtpDepth
        case mtpQuantBits
        case prefixCacheDiskGB
        case thinkingBudget
        case extraArguments
    }

    @Environment(\.dismiss) private var dismiss
    @State private var tuning = EngineTuning()
    @State private var loaded = false
    @FocusState private var focusedField: ConfigField?

    private var controller: EngineController? { state.engines?.controller(engine) }
    private var installedVersion: String? { controller?.installation.version }
    private var isActive: Bool { state.activeEngine == engine }

    private var hasSwitchesCard: Bool {
        switch engine.adapter {
        case .splash, .omlx, .mtplx: return true
        default: return false
        }
    }

    private var supportsThinkingBudget: Bool {
        switch engine.adapter {
        case .splash, .omlx, .mtplx: return true
        default: return false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            DSDivider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if hasSwitchesCard {
                        switchesCard
                    }
                    prefixCacheCard
                    advancedCard
                }
                .padding(18)
            }
            .scrollIndicators(.never)
            DSDivider()
            footer
        }
        .frame(width: 560, height: 540)
        .sheetCanvas()
        .onAppear(perform: load)
    }

    private var header: some View {
        HStack(spacing: 10) {
            IconTile(symbol: engineSymbol(engine), color: engineAccent(engine), size: 30)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(engine.displayName)
                        .font(DS.Font.lg.weight(.semibold))
                        .foregroundStyle(DS.text)
                    if isActive { Tag(text: "当前引擎", tone: .success) }
                }
                Text(
                    L10n.format(
                        "%@ · 端口 %@",
                        installedVersion ?? L10n.t("未安装"),
                        controller.map { String($0.port) }
                            ?? L10n.t("自动"))
                )
                .font(DS.Font.xs)
                .foregroundStyle(DS.text3)
            }
            Spacer(minLength: 8)
            DSIconButton(systemName: "xmark", help: "关闭") { dismiss() }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var switchesCard: some View {
        Card("调优", subtitle: "留空表示交给引擎自己的默认值") {
            VStack(alignment: .leading, spacing: 2) {
                switch engine.adapter {
                case .splash:
                    let explicitPLE = !(tuning.pleMemory ?? "").trimmingCharacters(in: .whitespaces).isEmpty
                    toggle("DFlash2 投机解码", binding: $tuning.dflash, default: EngineTuning.defaults(for: engine).dflash)
                    textField("最大内存", text: optionalText(\.maxMemory), placeholder: "24G", field: .maxMemory)
                    textField("最大上下文", text: optionalText(\.maxContext), placeholder: "256K", field: .maxContext)
                    textField("PLE 内存", text: optionalText(\.pleMemory), placeholder: "2G / off", field: .pleMemory)
                    toggle(
                        "关闭视觉预处理", binding: $tuning.languageOnly, default: false,
                        detail: "language-only：跳过视觉侧准备，纯文本更快")
                    toggle(
                        "常驻权重", binding: $tuning.idleReleaseOff, default: false,
                        detail: "idle-release off：空闲时不卸下权重")
                    toggle(
                        "PLE 表常驻 SSD",
                        binding: $tuning.pleSSDOffload,
                        default: EngineTuning.defaults(for: engine).pleSSDOffload ?? true,
                        detail: "留空「PLE 内存」时生效"
                    )
                    .disabled(explicitPLE)
                    .opacity(explicitPLE ? 0.5 : 1)
                case .omlx:
                    let defaults = EngineTuning.defaults(for: engine)
                    let mtpEnabled = tuning.mtp ?? defaults.mtp ?? true
                    let dflashEnabled = tuning.dflash ?? defaults.dflash ?? false
                    toggleRow(
                        "MTP 预测",
                        isOn: Binding(
                            get: { mtpEnabled },
                            set: { on in
                                tuning.mtp = on
                                if on { tuning.dflash = false }
                            }),
                        detail: nil
                    )
                    toggleRow(
                        "DFlash 草稿",
                        isOn: Binding(
                            get: { dflashEnabled },
                            set: { on in
                                tuning.dflash = on
                                if on { tuning.mtp = false }
                            }),
                        detail: nil
                    )
                    if !dflashEnabled && mtpEnabled {
                        intField("MTP 深度", value: $tuning.mtpDepth, placeholder: "自适应", field: .mtpDepth)
                    }
                    toggle(
                        "PLE 表常驻 SSD",
                        binding: $tuning.pleSSDOffload,
                        default: defaults.pleSSDOffload ?? true)
                case .mtplx:
                    let defaults = EngineTuning.defaults(for: engine)
                    toggle("MTP 预测", binding: $tuning.mtp, default: defaults.mtp ?? true)
                    toggle("预加载 MTP 头", binding: $tuning.loadMtp, default: defaults.loadMtp ?? true)
                    intField("MTP 头量化位宽", value: $tuning.mtpQuantBits, placeholder: "引擎默认", field: .mtpQuantBits)
                default:
                    EmptyView()
                }
            }
        }
    }

    /// The disk tier is what turns "the app restarted, so the whole session is
    /// re-prefilled from zero" into a restore.
    @ViewBuilder
    private var prefixCacheCard: some View {
        Card("前缀缓存", subtitle: "把见过的前缀写到 SSD；App 重启后恢复而不是重算") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.t("落盘"))
                            .font(DS.Font.md)
                            .foregroundStyle(DS.text)
                        Text(L10n.t("关闭后每次重启都要从零重算整段历史"))
                            .font(DS.Font.xs)
                            .foregroundStyle(DS.text3)
                    }
                    Spacer(minLength: 8)
                    Toggle("", isOn: prefixCacheEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                        .tint(DS.accent)
                        .accessibilityLabel(L10n.t("落盘"))
                }

                if prefixCacheEnabled.wrappedValue {
                    intField(
                        "磁盘预算 (GB)",
                        value: $tuning.prefixCacheDiskGB,
                        placeholder: "20",
                        field: .prefixCacheDiskGB)
                    Text(FlashCatPaths.prefixCacheDirectory(engine))
                        .font(DS.Font.mono(10))
                        .foregroundStyle(DS.text3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    /// `nil` follows the engine default, so the switch reads that default rather
    /// than showing "off" for an engine that ships with the tier on.
    private var prefixCacheEnabled: Binding<Bool> {
        Binding(
            get: { tuning.effectivePrefixCacheDiskGB(for: engine) != nil },
            set: { on in
                guard !on else {
                    let fallback = EngineTuning.defaults(for: engine).prefixCacheDiskGB ?? 20
                    let current = tuning.prefixCacheDiskGB ?? 0
                    tuning.prefixCacheDiskGB = current > 0 ? current : fallback
                    return
                }
                tuning.prefixCacheDiskGB = 0
            })
    }

    private var advancedCard: some View {
        Card("高级", subtitle: supportsThinkingBudget ? "思考预算与额外命令行参数" : "额外命令行参数") {
            VStack(alignment: .leading, spacing: 8) {
                if supportsThinkingBudget {
                    intField(
                        "思考 token 预算",
                        value: $tuning.thinkingBudget,
                        placeholder: "不限制",
                        field: .thinkingBudget)
                }
                HStack(alignment: .center, spacing: 10) {
                    Text("额外参数")
                        .font(DS.Font.md)
                        .foregroundStyle(DS.text)
                        .frame(width: 110, alignment: .leading)
                    TextField("--flag value", text: optionalText(\.extraArguments))
                        .textFieldStyle(.plain)
                        .font(DS.Font.mono(11.5))
                        .padding(.horizontal, 8)
                        .frame(height: 28)
                        .dsInputSurface(radius: DS.Radius.sm, focused: focusedField == .extraArguments)
                        .focused($focusedField, equals: .extraArguments)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("恢复默认") {
                tuning = EngineTuning.defaults(for: engine)
            }
            .buttonStyle(.ds(.secondary, size: .regular))
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Button("取消") { dismiss() }
                    .buttonStyle(.ds(.secondary, size: .regular))
                Button("保存") { save() }
                    .buttonStyle(.ds(.primary, size: .regular))
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    // MARK: Helpers

    private func toggle(
        _ title: String, binding: Binding<Bool?>, default fallback: Bool? = nil,
        detail: String? = nil
    ) -> some View {
        toggleRow(
            title,
            isOn: Binding(
                get: { binding.wrappedValue ?? fallback ?? false },
                set: { binding.wrappedValue = $0 }),
            detail: detail)
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>, detail: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.t(title))
                    .font(DS.Font.md)
                    .foregroundStyle(DS.text)
                if let detail {
                    Text(L10n.t(detail))
                        .font(DS.Font.xs)
                        .foregroundStyle(DS.text3)
                }
            }
            Spacer(minLength: 8)
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .tint(DS.accent)
                .accessibilityLabel(L10n.t(title))
        }
        .padding(.vertical, 5)
    }

    private func textField(
        _ title: String,
        text: Binding<String>,
        placeholder: String,
        field: ConfigField
    ) -> some View {
        HStack(spacing: 10) {
            Text(L10n.t(title))
                .font(DS.Font.md)
                .foregroundStyle(DS.text)
                .frame(width: 110, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(DS.Font.mono(11.5))
                .padding(.horizontal, 8)
                .frame(height: 28)
                .dsInputSurface(radius: DS.Radius.sm, focused: focusedField == field)
                .focused($focusedField, equals: field)
        }
        .padding(.vertical, 3)
    }

    private func intField(
        _ title: String,
        value: Binding<Int?>,
        placeholder: String,
        field: ConfigField
    ) -> some View {
        HStack(spacing: 10) {
            Text(L10n.t(title))
                .font(DS.Font.md)
                .foregroundStyle(DS.text)
                .frame(width: 110, alignment: .leading)
            TextField(
                placeholder,
                text: Binding(
                    get: { value.wrappedValue.map(String.init) ?? "" },
                    set: { raw in
                        let trimmed = raw.trimmingCharacters(in: .whitespaces)
                        if trimmed.isEmpty {
                            value.wrappedValue = nil
                        } else if let parsed = Int(trimmed) {
                            value.wrappedValue = parsed
                        }
                    })
            )
            .textFieldStyle(.plain)
            .font(DS.Font.mono(11.5))
            .padding(.horizontal, 8)
            .frame(width: 140, height: 28)
            .dsInputSurface(radius: DS.Radius.sm, focused: focusedField == field)
            .focused($focusedField, equals: field)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }

    private func optionalText(_ keyPath: WritableKeyPath<EngineTuning, String?>) -> Binding<String> {
        Binding(
            get: { tuning[keyPath: keyPath] ?? "" },
            set: { tuning[keyPath: keyPath] = $0.isEmpty ? nil : $0 })
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        let configuration = EngineStore.shared.configuration(for: engine)
        tuning = configuration.tuning ?? EngineTuning()
    }

    private func save() {
        EngineStore.shared.setTuning(tuning.sanitized(), for: engine)
        Task { await state.engines?.controller(engine)?.reapplyTuning() }
        if isActive && state.isRunning && engine.adapter != .omlx {
            state.toast(L10n.format("%@ 的配置已保存，重启引擎后生效", engine.displayName))
        } else {
            state.toast(L10n.format("%@ 的配置已保存", engine.displayName))
        }
        dismiss()
    }
}
