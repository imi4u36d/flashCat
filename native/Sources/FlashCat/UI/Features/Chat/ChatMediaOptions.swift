// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AVKit
import AppKit
import FlashCatCore
import FlashCatKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Video bubble

/// 视频结果直接内嵌播放：mp4 已经落在本地作品目录，AVPlayer 按需读文件。
/// 播放器只在行出现时创建，滚出屏幕就暂停，避免十几条历史视频同时解码。
struct VideoBubble: View {
    let path: String
    @State private var player: AVPlayer?
    @State private var aspect: CGFloat = 16.0 / 9.0
    @State private var missing = false

    private var displaySize: CGSize {
        if aspect >= 1 {
            return CGSize(width: 440, height: 440 / max(aspect, 0.1))
        }
        return CGSize(width: 440 * max(aspect, 0.1), height: 440)
    }

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
                    .frame(width: displaySize.width, height: displaySize.height)
                    .clipShape(DS.rect(DS.Radius.lg))
                    .overlay {
                        DS.rect(DS.Radius.lg)
                            .strokeBorder(DS.line, lineWidth: 1)
                    }
                    .contextMenu {
                        Button("在访达中显示") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                        }
                        Button("用 QuickTime 打开") {
                            VideoPlayback.openInQuickTime(path)
                        }
                    }
                    .help("视频已保存在本地，可直接播放")
            } else if missing {
                Text("视频已被移除：\(path)")
                    .font(DS.Font.xs)
                    .foregroundStyle(DS.text3)
                    .textSelection(.enabled)
            } else {
                DS.rect(DS.Radius.lg)
                    .fill(DS.bg)
                    .overlay {
                        DS.rect(DS.Radius.lg)
                            .strokeBorder(DS.line, lineWidth: 1)
                    }
                    .frame(width: displaySize.width, height: displaySize.height)
                    .overlay(ProgressView().controlSize(.small))
            }
        }
        .task(id: path) {
            guard VideoStore.exists(atPath: path) else {
                missing = true
                return
            }
            let asset = AVURLAsset(url: URL(fileURLWithPath: path))
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
                let size = try? await track.load(.naturalSize),
                size.width > 0, size.height > 0
            {
                aspect = size.width / size.height
            }
            player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        }
        .onDisappear { player?.pause() }
    }
}

// MARK: - Video options

/// 视频模型专用面板。分辨率和帧数都直接换算成显存，所以把常用档位做成
/// 一键选项，并在底部写清楚 24fps 下的时长。
struct VideoOptionsPopover: View {
    @Binding var options: VideoOptions
    let hasSource: Bool
    var supportsReferences = false
    var referenceCount = 0
    @State private var seedText = ""
    @FocusState private var seedFocused: Bool

    private let sizes = ["512x384", "768x512", "1024x576", "1280x704"]
    private let framePresets: [(frames: Int, label: String)] = [
        (49, "2 秒"), (97, "4 秒"), (121, "5 秒"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.t("视频参数"))
                    .font(DS.Font.md.weight(.semibold))
                    .foregroundStyle(DS.text)
                Text(headerSubtitle)
                    .font(DS.Font.xs)
                    .foregroundStyle(DS.text3)
            }

            section("尺寸") {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 8),
                        GridItem(.flexible(), spacing: 8),
                    ],
                    spacing: 8
                ) {
                    ForEach(sizes, id: \.self) { size in
                        sizeChip(size)
                    }
                }
            }

            if supportsReferences {
                section("参考细节") {
                    NativeSegmented(
                        selection: detailBinding,
                        options: VideoReferenceDetail.allCases.map { ($0, $0.title) },
                        size: .small)
                    Text(
                        L10n.t(
                            options.referenceDetail == .max
                                ? "参考帧长边按 1280 发送：细节更多，上传与预处理更慢。"
                                : "参考帧按生成画布缩放：上传更快，适合先试效果。"
                        )
                    )
                    .font(.system(size: 9.5))
                    .foregroundStyle(DS.text3)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            section("时长（24fps）") {
                HStack(spacing: 8) {
                    ForEach(framePresets, id: \.frames) { preset in
                        frameChip(preset.frames, label: preset.label)
                    }
                }
                HStack(spacing: 10) {
                    Text(L10n.format("%lld 帧", Int64(options.frames)))
                        .font(DS.Font.mono(12, weight: .medium))
                        .foregroundStyle(DS.text)
                        .monospacedDigit()
                        .frame(minWidth: 54, alignment: .leading)
                    Stepper("", value: $options.frames, in: 9...249, step: 4)
                        .labelsHidden()
                    Spacer(minLength: 0)
                    Text(L10n.format("%.1f 秒", Double(options.frames) / 24.0))
                        .font(DS.Font.mono(10.5))
                        .foregroundStyle(DS.text3)
                        .monospacedDigit()
                }
            }

            section("步数") {
                StepsControl(steps: $options.steps, range: 4...50)
                Text(L10n.t("蒸馏 LTX 8 步够用；H3 一般给到 20 步。"))
                    .font(.system(size: 9.5))
                    .foregroundStyle(DS.text3)
            }

            section("seed") {
                HStack(spacing: 8) {
                    TextField(L10n.t("留空则每次随机"), text: $seedText)
                        .textFieldStyle(.plain)
                        .font(DS.Font.mono(11))
                        .focused($seedFocused)
                        .padding(.horizontal, 8)
                        .frame(width: 126, height: 26)
                        .dsInputSurface(radius: DS.Radius.sm, focused: seedFocused)
                    Button(L10n.t("随机")) { seedText = "" }
                        .buttonStyle(.link)
                        .font(DS.Font.xs)
                    Spacer(minLength: 0)
                }
                Text(
                    L10n.t(
                        options.seed == nil
                            ? "留空时每段视频随机一个 seed；生成后视频下方会显示实际值。"
                            : "固定 seed：提示词与参数相同时，结果基本可复现。"
                    )
                )
                .font(.system(size: 9.5))
                .foregroundStyle(DS.text3)
                .fixedSize(horizontal: false, vertical: true)
            }

            Text(L10n.t("分辨率与帧数越大越吃显存；显存不足时先降尺寸，再减帧数。"))
                .font(.system(size: 9.5))
                .foregroundStyle(DS.text3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(width: 344)
        .dsPopoverSurface()
        .onChange(of: seedText) { _, text in
            let digits = text.filter(\.isNumber)
            if digits != text { seedText = digits }
            options.seed = digits.isEmpty ? nil : Int(digits)
        }
        .onAppear { seedText = options.seed.map(String.init) ?? "" }
    }

    private var headerSubtitle: String {
        if supportsReferences {
            return referenceCount > 0
                ? L10n.format("已附 %lld 个参考素材：REF2VA 会从素材生成新视频", Int64(referenceCount))
                : L10n.t("REF2VA 需要至少一个参考素材；首帧/尾帧不适用于这个包")
        }
        return L10n.t(
            hasSource
                ? "已附参考帧：首帧定开头、尾帧定结尾，只给一边也可以"
                : "不附帧直接按提示词生成；附首帧/尾帧可约束开头和结尾"
        )
    }

    private var detailBinding: Binding<VideoReferenceDetail> {
        Binding(
            get: { options.referenceDetail ?? .match },
            set: { options.referenceDetail = $0 == .match ? nil : $0 })
    }

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(L10n.t(title))
                .font(DS.Font.xs.weight(.medium))
                .foregroundStyle(DS.text3)
            content()
        }
    }

    private func sizeChip(_ size: String) -> some View {
        let selected = options.size == size
        let label = size.replacingOccurrences(of: "x", with: " × ")
        return Button {
            options.size = size
        } label: {
            HStack(spacing: 5) {
                Text(label)
                    .font(DS.Font.mono(10.5, weight: selected ? .semibold : .regular))
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                }
            }
            .foregroundStyle(selected ? DS.text : DS.text2)
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background {
                DS.rect(DS.Radius.md)
                    .fill(selected ? DS.accentSoft : DS.bg)
            }
            .overlay {
                DS.rect(DS.Radius.md)
                    .strokeBorder(
                        selected ? DS.accent.opacity(0.55) : DS.line,
                        lineWidth: 1)
            }
            .contentShape(DS.rect(DS.Radius.md))
        }
        .buttonStyle(.plainHit)
    }

    private func frameChip(_ frames: Int, label: String) -> some View {
        let selected = options.frames == frames
        return Button {
            options.frames = frames
        } label: {
            VStack(spacing: 1) {
                Text(L10n.format("%lld 帧", Int64(frames)))
                    .font(DS.Font.mono(10, weight: selected ? .semibold : .regular))
                Text(L10n.t(label))
                    .font(.system(size: 9))
            }
            .foregroundStyle(selected ? DS.text : DS.text2)
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background {
                DS.rect(DS.Radius.md)
                    .fill(selected ? DS.accentSoft : DS.bg)
            }
            .overlay {
                DS.rect(DS.Radius.md)
                    .strokeBorder(
                        selected ? DS.accent.opacity(0.55) : DS.line,
                        lineWidth: 1)
            }
            .contentShape(DS.rect(DS.Radius.md))
        }
        .buttonStyle(.plainHit)
    }
}

// MARK: - Image options

/// 图像模型专用的小面板。只影响下一次发送，不做持久化：尺寸/步数这类
/// 参数每次出图都可能想换，记住上次的值反而容易在没注意时多等几十秒。
struct ImageOptionsPopover: View {
    private enum FocusField {
        case seed, width, height
    }

    @Binding var options: ImageOptions
    let model: EngineModel?
    let hasSource: Bool
    let lastSeed: Int?
    @State private var seedText = ""
    @State private var widthText = ""
    @State private var heightText = ""
    @FocusState private var focusedField: FocusField?

    private var profile: ImageModelProfile { ImageModelProfile(model: model) }
    private var presets: [ImageSizePreset] { profile.presets }
    private var isCustomSize: Bool { !presets.contains { $0.id == options.size } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.t("图像参数"))
                    .font(DS.Font.md.weight(.semibold))
                    .foregroundStyle(DS.text)
                Text(L10n.t(hasSource ? "以附件为底图重绘，强度决定离原图多远" : "不附底图，直接按提示词出图"))
                    .font(DS.Font.xs)
                    .foregroundStyle(DS.text3)
            }

            section("尺寸") {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 8),
                        GridItem(.flexible(), spacing: 8),
                    ],
                    spacing: 8
                ) {
                    ForEach(presets) { preset in
                        sizeChip(preset)
                    }
                }
                if profile.allowsCustomCanvas {
                    customSizeRow
                    Text(
                        L10n.format(
                            "也可以直接填宽高（256–%lld）；引擎会按 %lld 对齐，非预设画布也能出图。",
                            Int64(profile.maximumSide),
                            Int64(profile.alignment)
                        )
                    )
                    .font(.system(size: 9.5))
                    .foregroundStyle(DS.text3)
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(L10n.t("Mage 的采样器只认上面的固定画布，不能自定宽高。"))
                        .font(.system(size: 9.5))
                        .foregroundStyle(DS.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            section("步数") {
                if let fixed = profile.fixedSteps {
                    HStack(spacing: 6) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(DS.text3)
                        Text(L10n.format("固定 %lld 步", Int64(fixed)))
                            .font(DS.Font.mono(11, weight: .medium))
                            .foregroundStyle(DS.text)
                    }
                    Text(L10n.format("这个模型是蒸馏加速版，采样表由权重写死；拖步数不会改变结果，出图就按 %lld 步算。", Int64(fixed)))
                        .font(.system(size: 9.5))
                        .foregroundStyle(DS.text3)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    StepsControl(steps: $options.steps)
                    Text(L10n.t("8 步能出草稿，20 步细节更稳；越高越慢。"))
                        .font(.system(size: 9.5))
                        .foregroundStyle(DS.text3)
                }
            }

            section("seed") {
                HStack(spacing: 8) {
                    TextField(L10n.t("留空则每次随机"), text: $seedText)
                        .textFieldStyle(.plain)
                        .font(DS.Font.mono(11))
                        .focused($focusedField, equals: .seed)
                        .padding(.horizontal, 8)
                        .frame(width: 126, height: 26)
                        .dsInputSurface(radius: DS.Radius.sm, focused: focusedField == .seed)
                    Button(L10n.t("随机")) { seedText = "" }
                        .buttonStyle(.link)
                        .font(DS.Font.xs)
                    if let lastSeed {
                        Button(L10n.format("用上次 #%lld", Int64(lastSeed))) { seedText = String(lastSeed) }
                            .buttonStyle(.link)
                            .font(DS.Font.xs)
                    }
                    Spacer(minLength: 0)
                }
                Text(
                    L10n.t(
                        options.seed == nil
                            ? "留空时每张图随机一个 seed；生成后点图下方的 seed 复制，贴回这里即可复现。"
                            : "固定 seed：提示词与参数相同时，结果基本可复现。"
                    )
                )
                .font(.system(size: 9.5))
                .foregroundStyle(DS.text3)
                .fixedSize(horizontal: false, vertical: true)
            }

            if hasSource {
                section("重绘强度") {
                    HStack(spacing: 10) {
                        Slider(value: $options.strength, in: 0.1...0.95)
                            .tint(DS.accent)
                        Text("\(Int((options.strength * 100).rounded()))%")
                            .font(DS.Font.mono(10.5))
                            .foregroundStyle(DS.text2)
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                    Text(L10n.t("越低越贴近原图，越高越放飞；0.55–0.65 适合换风格。"))
                        .font(.system(size: 9.5))
                        .foregroundStyle(DS.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(18)
        .frame(width: 330)
        .dsPopoverSurface()
        .onChange(of: seedText) { _, text in
            let digits = text.filter(\.isNumber)
            if digits != text { seedText = digits }
            options.seed = digits.isEmpty ? nil : Int(digits)
        }
        .onAppear {
            seedText = options.seed.map(String.init) ?? ""
            syncSizeText()
        }
    }

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(L10n.t(title))
                .font(DS.Font.xs.weight(.medium))
                .foregroundStyle(DS.text3)
            content()
        }
    }

    /// 自定宽高和预设放在同一栏：预设是常用比例，字段留给 1328×1328 这类
    /// 引擎能算、但没进预设表的画布。
    private var customSizeRow: some View {
        HStack(spacing: 6) {
            TextField(L10n.t("宽"), text: $widthText)
                .textFieldStyle(.plain)
                .font(DS.Font.mono(10.5))
                .multilineTextAlignment(.center)
                .focused($focusedField, equals: .width)
                .padding(.horizontal, 6)
                .frame(width: 58, height: 26)
                .dsInputSurface(radius: DS.Radius.sm, focused: focusedField == .width)
            Text("×")
                .font(DS.Font.xs)
                .foregroundStyle(DS.text3)
            TextField(L10n.t("高"), text: $heightText)
                .textFieldStyle(.plain)
                .font(DS.Font.mono(10.5))
                .multilineTextAlignment(.center)
                .focused($focusedField, equals: .height)
                .padding(.horizontal, 6)
                .frame(width: 58, height: 26)
                .dsInputSurface(radius: DS.Radius.sm, focused: focusedField == .height)
            Text("px")
                .font(.system(size: 9.5))
                .foregroundStyle(DS.text3)
            Spacer(minLength: 0)
            if isCustomSize {
                Text(L10n.t("自定义"))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(DS.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(DS.rect(DS.Radius.sm).fill(DS.accentSoft))
                    .overlay(DS.rect(DS.Radius.sm).strokeBorder(DS.accent.opacity(0.25), lineWidth: 1))
            }
            Button(L10n.t("应用")) { commitCustomCanvas() }
                .buttonStyle(.plain)
                .font(DS.Font.xs.weight(.medium))
                .foregroundStyle(DS.accent)
                .help(L10n.t("把宽高限制在引擎支持的范围内并应用"))
        }
        .onChange(of: widthText) { _, text in
            let digits = text.filter(\.isNumber)
            if digits != text { widthText = digits }
            applyCustomCanvas()
        }
        .onChange(of: heightText) { _, text in
            let digits = text.filter(\.isNumber)
            if digits != text { heightText = digits }
            applyCustomCanvas()
        }
    }

    private func chooseSize(_ preset: ImageSizePreset) {
        options.size = preset.id
        widthText = String(preset.width)
        heightText = String(preset.height)
    }

    private func applyCustomCanvas() {
        guard let width = Int(widthText), let height = Int(heightText),
            profile.isValidCanvas(width: width, height: height)
        else { return }
        let size = "\(width)x\(height)"
        if options.size != size { options.size = size }
    }

    private func commitCustomCanvas() {
        guard let width = Int(widthText), let height = Int(heightText) else { return }
        let clamped = profile.clampedCanvas(width: width, height: height)
        options.size = "\(clamped.width)x\(clamped.height)"
        widthText = String(clamped.width)
        heightText = String(clamped.height)
    }

    private func syncSizeText() {
        let normalized = options.size.lowercased().replacingOccurrences(of: "×", with: "x")
        let parts = normalized.split(separator: "x")
        guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]) else {
            widthText = ""
            heightText = ""
            return
        }
        widthText = String(width)
        heightText = String(height)
    }

    private func sizeChip(_ preset: ImageSizePreset) -> some View {
        let selected = options.size == preset.id
        return Button {
            chooseSize(preset)
        } label: {
            VStack(spacing: 1) {
                HStack(spacing: 4) {
                    Text(preset.title)
                        .font(DS.Font.mono(10.5, weight: selected ? .semibold : .regular))
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .bold))
                    }
                }
                Text(preset.orientation)
                    .font(.system(size: 8.5))
                    .foregroundStyle(DS.text3)
            }
            .foregroundStyle(selected ? DS.text : DS.text2)
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background {
                DS.rect(DS.Radius.md)
                    .fill(selected ? DS.accentSoft : DS.bg)
            }
            .overlay {
                DS.rect(DS.Radius.md)
                    .strokeBorder(
                        selected ? DS.accent.opacity(0.55) : DS.line,
                        lineWidth: 1)
            }
            .contentShape(DS.rect(DS.Radius.md))
        }
        .buttonStyle(.plainHit)
    }
}

/// 步数一条滑块加一个可编辑数字：拖动快，手动输入能精确落到想要的数字。
/// 视频和图像的参数面板共用，所以范围由调用方给。
struct StepsControl: View {
    @Binding var steps: Int
    var range: ClosedRange<Int> = 1...50

    @State private var text = ""
    @FocusState private var editing: Bool

    var body: some View {
        HStack(spacing: 10) {
            Slider(
                value: Binding(
                    get: { Double(steps) },
                    set: { steps = clamp(Int($0.rounded())) }),
                in: Double(range.lowerBound)...Double(range.upperBound),
                step: 1
            )
            .tint(DS.accent)

            HStack(spacing: 4) {
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .font(DS.Font.mono(11, weight: .medium))
                    .multilineTextAlignment(.trailing)
                    .focused($editing)
                Text(L10n.t("步"))
                    .font(.system(size: 9.5))
                    .foregroundStyle(DS.text3)
            }
            .padding(.horizontal, 7)
            .frame(width: 58, height: 24)
            .dsInputSurface(radius: DS.Radius.sm, focused: editing)
        }
        .onAppear { text = String(steps) }
        .onDisappear { commit() }
        .onChange(of: steps) { _, value in
            // 非编辑状态下以 model 为准，比如预设按钮改了步数。
            if !editing { text = String(value) }
        }
        .onChange(of: editing) { _, focused in
            if !focused { commit() }
        }
        .onChange(of: text) { _, value in
            let digits = value.filter(\.isNumber)
            if digits != value { text = digits }
            // 输入过程中只要已经是范围内的数字就即时同步，滑块跟着一起走。
            if let number = Int(digits), range.contains(number) {
                steps = number
            }
        }
    }

    private func commit() {
        if let number = Int(text.trimmingCharacters(in: .whitespaces)) {
            steps = clamp(number)
        }
        text = String(steps)
    }

    private func clamp(_ value: Int) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
