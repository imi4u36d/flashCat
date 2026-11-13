import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import FlashCatKit

/// 参考素材的清晰度。`match` 让参考帧缩到这次生成的画布大小，上传最省；
/// `max` 保留更多纹理，但请求体和显存占用都更高。服务端默认就是 `match`。
enum VideoReferenceDetail: String, CaseIterable, Codable {
    case match
    case max

    var title: String { self == .match ? "匹配画布" : "最大细节" }
}

/// 用户挑的一段参考视频。发送时才抽帧，这里只记路径和用于展示的信息。
struct VideoReferenceClip: Identifiable, Equatable {
    let id = UUID()
    let path: String
    let name: String
    var duration: Double?
    var pixelSize: CGSize?
    /// 第一帧的 JPEG，用来在输入卡里显示缩略图；读不出来时为 nil。
    var posterJPEG: Data?
}

/// 请求体里一段参考视频：帧是 base64 JPEG/PNG，音轨可选。当前客户端只抽帧，
/// 不带音轨——REF2VA 的音频参考走单独的 `ref_audios`，这一版先不做。
struct VideoReferencePayload: Equatable {
    var framesBase64: [String]
    var audioBase64: String?
}

/// 视频参数面板的值。默认 768×512、49 帧（24fps 下约两秒）、20 步：
/// 蒸馏 LTX 8 步就够，H3 这类非蒸馏模型要 20 步上下，默认给足更省得反复调。
struct VideoOptions: Equatable, Codable {
    var size: String = "768x512"
    var frames: Int = 49
    var steps: Int = 20
    var seed: Int?
    /// REF2VA 参考素材的清晰度；老配置没有这个键时按 match 处理。
    var referenceDetail: VideoReferenceDetail?

    /// 请求体要的是分开的宽高；面板里仍用和图像一致的 `宽x高` 字符串。
    var dimensions: (width: Int, height: Int) {
        let parts = size.split(separator: "x").compactMap { Int($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else {
            return (768, 512)
        }
        return (parts[0], parts[1])
    }
}

/// 视频参数跟用户走：换会话、重启后还是上次那套尺寸与帧数。
enum VideoOptionsStore {
    private static let key = "flashCat.videoOptions"
    /// 旧版本默认 8 步。默认值提到 20 之后，把没动过步数的存量配置也带过去；
    /// 只迁移一次，用户之后自己选回 8 步不会被再抬上去。
    private static let stepsMigrationKey = "flashCat.videoOptions.steps20"

    static func load() -> VideoOptions {
        var value: VideoOptions
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode(VideoOptions.self, from: data) {
            value = decoded
        } else {
            value = VideoOptions()
        }
        if !UserDefaults.standard.bool(forKey: stepsMigrationKey) {
            if value.steps == 8 { value.steps = VideoOptions().steps }
            UserDefaults.standard.set(true, forKey: stepsMigrationKey)
            save(value)
        }
        return value
    }

    static func save(_ options: VideoOptions) {
        guard let data = try? JSONEncoder().encode(options) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

/// 一次 `/v1/video/generations` 请求。mlx-serve 返回的是 rgb8 原始帧，
/// 不是 mp4，所以客户端负责把帧（和可选音轨）封装成能播放的文件。
struct VideoGenerationRequest {
    var model: String
    var prompt: String
    var size: String
    var frames: Int
    var steps: Int
    var seed: Int?
    /// 首帧 PNG/JPEG 的 base64。带上它就是从这张图开始生成视频。
    var firstFrameBase64: String?
    /// 尾帧 PNG/JPEG 的 base64。首尾帧同时给，引擎就会朝这张图收束；
    /// 只给尾帧也可以（部分模型要求至少 9 帧）。
    var lastFrameBase64: String? = nil
    /// REF2VA 的参考图，base64 PNG/JPEG，最多 9 张。
    var referenceImagesBase64: [String] = []
    /// REF2VA 的参考视频，最多 3 段，每段至少 5 帧。
    var referenceVideos: [VideoReferencePayload] = []
    /// 只在 `max` 时发送；`match` 用服务端默认值。
    var referenceDetail: VideoReferenceDetail? = nil

    /// 请求体要分开的宽高；`size` 沿用面板里的 `宽x高` 写法。
    var dimensions: (width: Int, height: Int) {
        let parts = size.split(separator: "x").compactMap { Int($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else {
            return (768, 512)
        }
        return (parts[0], parts[1])
    }
}

struct VideoGenerationResult {
    let mp4: Data
    let seconds: Double
    let width: Int
    let height: Int
    let frames: Int
    let fps: Int

    var duration: Double { Double(frames) / Double(max(1, fps)) }
}

struct VideoClientError: Error {
    let message: String
}

/// 解码后的视频载荷。`rgb` 是紧密排列的 RGB888 帧，长度严格等于
/// `frames * width * height * 3`；音频是可选的 16-bit PCM。
struct VideoFrames: Sendable {
    struct Audio: Sendable {
        let pcm: Data
        let sampleRate: Int
        let channels: Int
    }

    let rgb: Data
    let frames: Int
    let width: Int
    let height: Int
    let fps: Int
    let audio: Audio?
}

/// 视频端点的流式客户端。和 ImageClient 同一套协议：`stream: true` 时先收
/// progress 事件，最后一条 complete 事件里带完整帧数据。区别在于帧数据可能
/// 有几十 MB，必须先在后台线程编码成 mp4，不能卡住主线程。
///
/// 唯一的状态是 `URLSession`（自身可发送），每个请求各用各的 task，
/// 所以整个对象可以安全地跨隔离域共享。
final class VideoClient: Sendable {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3600
        configuration.timeoutIntervalForResource = 7200
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    /// 测试注入用：SSE 解析不应该为了跑一条假响应就真起一个推理服务。
    init(session: URLSession) {
        self.session = session
    }

    /// 请求体单独构造，测试可以直接钉住字段契约，不必真的发一次网络请求。
    static func requestBody(for request: VideoGenerationRequest) -> [String: Any] {
        let dimensions = request.dimensions
        var body: [String: Any] = [
            "model": request.model,
            "prompt": request.prompt,
            "width": dimensions.width,
            "height": dimensions.height,
            "num_frames": request.frames,
            "steps": request.steps,
            "stream": true,
        ]
        if let seed = request.seed { body["seed"] = seed }
        if let first = request.firstFrameBase64 { body["first_frame_image"] = first }
        if let last = request.lastFrameBase64 { body["last_frame_image"] = last }
        if !request.referenceImagesBase64.isEmpty {
            body["ref_images"] = request.referenceImagesBase64
        }
        if !request.referenceVideos.isEmpty {
            body["ref_videos"] = request.referenceVideos.map { clip -> [String: Any] in
                var entry: [String: Any] = ["frames": clip.framesBase64]
                if let audio = clip.audioBase64 { entry["audio"] = audio }
                return entry
            }
        }
        // 服务端默认 match；只有 max 需要显式发，免得把默认行为写死成客户端决定。
        if request.referenceDetail == .max { body["ref_image_size"] = "max" }
        return body
    }

    func generate(port: Int,
                  request: VideoGenerationRequest,
                  onProgress: @escaping @Sendable (String) -> Void)
        async -> Result<VideoGenerationResult, VideoClientError> {
        // 发出去之前先按 RGB 原始体积算一遍：一个 1280×704、249 帧的请求要跑
        // 几十分钟，不能等生成完了才发现载荷超过客户端上限。
        let dimensions = request.dimensions
        guard request.frames > 0, dimensions.width > 0, dimensions.height > 0 else {
            return .failure(VideoClientError(message: "视频参数无效：尺寸和帧数必须大于 0"))
        }
        guard let estimated = Self.estimatedFrameBytes(width: dimensions.width,
                                                       height: dimensions.height,
                                                       frames: request.frames) else {
            return .failure(VideoClientError(message: "视频参数过大，请调小尺寸或帧数"))
        }
        guard estimated <= VideoPayloadScanner.maxFrameBytes else {
            return .failure(VideoClientError(message: Self.tooLargeMessage(requiredBytes: estimated)))
        }

        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/video/generations") else {
            return .failure(VideoClientError(message: "视频端点地址无效"))
        }
        let body = Self.requestBody(for: request)

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.timeoutInterval = 3600
        do {
            let encoded = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            // 服务端按 JSON 字符串长度卡 60 MiB，超了会在解析前直接拒绝。
            // 客户端先算一遍，省得把几十 MB 传上去再等一个必然的失败。
            guard encoded.count <= Self.maximumUploadBytes else {
                let size = ByteCountFormatter.string(fromByteCount: Int64(encoded.count),
                                                     countStyle: .memory)
                return .failure(VideoClientError(
                    message: "参考素材太大：请求约 \(size)，超过 60 MB 上限。请减少参考图/参考视频，或把参考细节改为「匹配画布」。"))
            }
            urlRequest.httpBody = encoded
        } catch {
            return .failure(VideoClientError(message: "请求体编码失败：\(error.localizedDescription)"))
        }

        let started = Date()
        do {
            let (bytes, response) = try await session.bytes(for: urlRequest)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                var raw = Data()
                for try await byte in bytes {
                    raw.append(byte)
                    if raw.count > 64 * 1024 { break }
                }
                let message = Self.errorMessage(in: raw) ?? "服务返回 HTTP \(http.statusCode)"
                return .failure(VideoClientError(message: message))
            }

            // 旧版本或中间代理可能忽略 stream，直接回整段 JSON；把没有
            // `data:` 前缀的行攒起来，流结束后按普通响应兜底解析一次。
            var rawLines: [String] = []
            var sawEvent = false
            for try await line in bytes.lines {
                try Task.checkCancellation()
                // 生成完成的那一行是几亿字节的 base64（1280×704×175 帧 ≈ 632 MB）。
                // 常规路径会把这一行复制好几遍，这里直接在字节上扫字段、把 base64
                // 解进预分配的帧缓冲；只有形状不对时才退回下面的通用路径。
                if line.utf8.count >= VideoPayloadScanner.threshold {
                    switch VideoPayloadScanner.parse(inLine: line) {
                    case .frames(let frames):
                        return await mux(frames, started: started, onProgress: onProgress)
                    case .tooLarge(let requiredBytes):
                        return .failure(VideoClientError(
                            message: Self.tooLargeMessage(requiredBytes: requiredBytes)))
                    case .invalid:
                        break
                    }
                }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                guard trimmed.hasPrefix("data:") else {
                    rawLines.append(trimmed)
                    continue
                }
                sawEvent = true
                let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
                guard payload != "[DONE]", !payload.isEmpty,
                      let data = payload.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }

                switch (json["type"] as? String)?.lowercased() {
                case "progress":
                    onProgress(VideoPayload.progressText(json))
                case "error":
                    let message = (json["message"] as? String) ?? "视频生成失败"
                    return .failure(VideoClientError(message: message))
                default:
                    switch VideoPayload.parse(json) {
                    case .frames(let frames):
                        return await mux(frames, started: started, onProgress: onProgress)
                    case .tooLarge(let requiredBytes):
                        return .failure(VideoClientError(
                            message: Self.tooLargeMessage(requiredBytes: requiredBytes)))
                    case .invalid:
                        continue
                    }
                }
            }

            if !sawEvent, !rawLines.isEmpty,
               let data = rawLines.joined(separator: "\n").data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let message = Self.errorMessage(in: data) {
                    return .failure(VideoClientError(message: message))
                }
                switch VideoPayload.parse(json) {
                case .frames(let frames):
                    return await mux(frames, started: started, onProgress: onProgress)
                case .tooLarge(let requiredBytes):
                    return .failure(VideoClientError(
                        message: Self.tooLargeMessage(requiredBytes: requiredBytes)))
                case .invalid:
                    break
                }
            }
            return .failure(VideoClientError(message: "引擎没有返回视频数据"))
        } catch is CancellationError {
            return .failure(VideoClientError(message: "已取消"))
        } catch {
            let ns = error as NSError
            if ns.code == NSURLErrorCancelled {
                return .failure(VideoClientError(message: "已取消"))
            }
            return .failure(VideoClientError(message: error.localizedDescription))
        }
    }

    private func mux(_ frames: VideoFrames,
                     started: Date,
                     onProgress: @escaping @Sendable (String) -> Void)
        async -> Result<VideoGenerationResult, VideoClientError> {
        onProgress("正在封装 MP4")
        // 编码是同步的 CPU 活，跑在 detached task 里；取消动不了它，
        // 只能靠一个开关让它在帧之间自己停下，否则用户点了停止，
        // 后台还要继续编码一分钟。
        let cancellation = MuxCancellation()
        let task = Task.detached(priority: .userInitiated) {
            try VideoMuxer.makeMP4(frames) { cancellation.isCancelled }
        }
        do {
            let mp4 = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                cancellation.cancel()
                task.cancel()
            }
            return .success(VideoGenerationResult(mp4: mp4,
                                                  seconds: Date().timeIntervalSince(started),
                                                  width: frames.width,
                                                  height: frames.height,
                                                  frames: frames.frames,
                                                  fps: frames.fps))
        } catch is CancellationError {
            return .failure(VideoClientError(message: "已取消"))
        } catch {
            return .failure(VideoClientError(message: error.localizedDescription))
        }
    }

    /// 服务端对视频请求体（含参考素材 base64）的上限：60 MiB。
    static let maximumUploadBytes = 62_914_560

    /// 请求帧数据的理论体积；溢出时返回 nil（尺寸/帧数是用户可改的参数，
    /// 不能让一个离谱的组合把乘法撑爆）。
    static func estimatedFrameBytes(width: Int, height: Int, frames: Int) -> Int? {
        let (pixels, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        guard !pixelOverflow else { return nil }
        let (bytesPerFrame, frameOverflow) = pixels.multipliedReportingOverflow(by: 3)
        guard !frameOverflow else { return nil }
        let (total, totalOverflow) = bytesPerFrame.multipliedReportingOverflow(by: frames)
        guard !totalOverflow else { return nil }
        return total
    }

    static func tooLargeMessage(requiredBytes: Int,
                                limit: Int = VideoPayloadScanner.maxFrameBytes) -> String {
        let required = ByteCountFormatter.string(fromByteCount: Int64(requiredBytes),
                                                 countStyle: .memory)
        let cap = ByteCountFormatter.string(fromByteCount: Int64(limit),
                                            countStyle: .memory)
        return "视频数据太大：解码后约 \(required)，超过 \(cap) 上限。请调小尺寸或帧数后重试。"
    }

    private static func errorMessage(in data: Data) -> String? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        return json["message"] as? String
    }
}

/// SSE 载荷解析单独拆出来，方便用纯 JSON 做单元测试。字段契约来自
/// mlx-serve `tests/test_video_gen.sh`：
/// `frames/height/width/fps/format:"rgb8"/data`，音频可选。
enum VideoPayload {
    static func frames(in json: [String: Any]) -> VideoFrames? {
        if case .frames(let frames) = parse(json) { return frames }
        return nil
    }

    static func parse(_ json: [String: Any],
                      limit: Int = VideoPayloadScanner.maxFrameBytes) -> VideoPayloadParseResult {
        guard (json["format"] as? String)?.lowercased() == "rgb8",
              let frames = int(json["frames"]), frames > 0, frames <= 10_000,
              let width = int(json["width"]), width > 0, width <= 4_096,
              let height = int(json["height"]), height > 0, height <= 4_096,
              let base64 = json["data"] as? String
        else { return .invalid }

        let expected = frames * height * width * 3
        guard expected > 0 else { return .invalid }
        guard expected <= limit else { return .tooLarge(requiredBytes: expected) }
        guard let rgb = VideoPayloadScanner.base64(base64, expecting: expected) else {
            return .invalid
        }
        let fps = max(1, min(120, int(json["fps"]) ?? 24))

        var audio: VideoFrames.Audio?
        if let raw = json["audio_data"] as? String,
           let pcm = Data(base64Encoded: raw) {
            audio = makeAudio(pcm: pcm,
                              format: json["audio_format"] as? String,
                          sampleRate: int(json["audio_sample_rate"]),
                          channels: int(json["audio_channels"]))
        }

        return .frames(VideoFrames(rgb: rgb, frames: frames, width: width, height: height,
                                   fps: fps, audio: audio))
    }

    /// 音轨的取舍门槛。坏音轨不该拖垮整段视频：H3 的音频是附赠的，静音也能播。
    /// 两条解析路径（JSON 与字节级）共用这一份契约。
    static func makeAudio(pcm: Data,
                          format: String?,
                          sampleRate: Int?,
                          channels: Int?) -> VideoFrames.Audio? {
        guard !pcm.isEmpty,
              pcm.count <= 64 * 1024 * 1024,
              (format ?? "pcm_s16le").lowercased() == "pcm_s16le",
              let rate = sampleRate, rate > 0, rate <= 192_000,
              let channelCount = channels, channelCount > 0, channelCount <= 2,
              pcm.count % (channelCount * 2) == 0
        else { return nil }
        return VideoFrames.Audio(pcm: pcm, sampleRate: rate, channels: channelCount)
    }

    static func progressText(_ json: [String: Any]) -> String {
        let stage = (json["stage"] as? String) ?? "采样"
        if let step = int(json["step"]), let total = int(json["total"]), total > 0 {
            return "\(stageName(stage)) \(step)/\(total)"
        }
        return stageName(stage)
    }

    private static func stageName(_ raw: String) -> String {
        switch raw.lowercased() {
        case "denoise", "sample", "sampling": return "去噪"
        case "encode", "text_encoder": return "读提示词"
        case "decode", "vae", "vae_decode": return "解码视频"
        case "audio": return "生成音轨"
        case "load": return "加载模型"
        default: return raw
        }
    }

    private static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? Double { return Int(value) }
        if let value = value as? String { return Int(value) }
        return nil
    }
}

/// 生成结果落盘。视频和图片分开目录，历史仍只记路径。
enum VideoStore {
    static var directory: String { Paths.supportDirectory + "/videos" }

    static func save(_ data: Data) -> String? {
        let directory = Self.directory
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let path = directory + "/" + UUID().uuidString + ".mp4"
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            return path
        } catch {
            return nil
        }
    }

    static func exists(atPath path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }
}

/// 取消开关：`mux` 在等待编码时置位，编码线程在帧之间读。
/// 只是一个 Bool 加锁，不需要 actor 的调度开销。
private final class MuxCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/// 把 mlx-serve 的 RGB 帧和 PCM 音轨封装成 H.264/AAC 的 MP4。
///
/// 两个容易踩的坑：
/// 1. 音频必须整段 append 完并 markAsFinished，再去循环视频帧。两个输入同时
///    等对方向 writer 让出背压，会直接死锁。
/// 2. 帧的 presentationTime 用 600 的 timescale，24/25/30fps 都能整除，
///    避免浮点累积出音画不同步。
enum VideoMuxer {
    /// `isCancelled` 在每帧之间查询；编码一帧最多几十毫秒，停止按钮的
    /// 反馈延迟可以接受。取消时抛 `CancellationError`，上层显示「已取消」。
    static func makeMP4(_ frames: VideoFrames,
                        isCancelled: @Sendable () -> Bool = { false }) throws -> Data {
        guard frames.width % 2 == 0, frames.height % 2 == 0 else {
            throw VideoMuxError("视频尺寸需要是偶数：\(frames.width)×\(frames.height)")
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flashcat-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        try write(frames, to: url, isCancelled: isCancelled)
        guard !isCancelled() else { throw CancellationError() }
        return try Data(contentsOf: url)
    }

    private static func write(_ frames: VideoFrames,
                              to url: URL,
                              isCancelled: @Sendable () -> Bool) throws {
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        } catch {
            throw VideoMuxError("无法创建 MP4：\(error.localizedDescription)")
        }
        defer {
            if writer.status == .writing { writer.cancelWriting() }
        }

        let width = frames.width
        let height = frames.height
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        let sourceAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput,
                                                           sourcePixelBufferAttributes: sourceAttributes)
        guard writer.canAdd(videoInput) else {
            throw VideoMuxError("当前编码器不接受这个视频尺寸")
        }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if let audio = frames.audio {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: audio.sampleRate,
                AVNumberOfChannelsKey: audio.channels,
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }

        guard writer.startWriting() else {
            throw VideoMuxError(writer.error?.localizedDescription ?? "视频编码器启动失败")
        }
        writer.startSession(atSourceTime: .zero)

        // 先音轨、后视频：顺序反过来会在多输入 writer 上死锁。
        try checkCancellation(isCancelled)
        if let audioInput, let audio = frames.audio {
            try appendAudio(audio, to: audioInput, writer: writer, isCancelled: isCancelled)
        }

        try frames.rgb.withUnsafeBytes { raw in
            guard let source = raw.bindMemory(to: UInt8.self).baseAddress else {
                throw VideoMuxError("视频帧数据为空")
            }
            for index in 0..<frames.frames {
                try autoreleasepool {
                    try checkCancellation(isCancelled)
                    try waitUntilReady(videoInput, writer: writer, isCancelled: isCancelled)
                    let pixelBuffer = try makePixelBuffer(index: index,
                                                          source: source,
                                                          frames: frames,
                                                          adaptor: adaptor)
                    let time = CMTime(value: CMTimeValue(index) * 600 / CMTimeValue(frames.fps),
                                      timescale: 600)
                    guard adaptor.append(pixelBuffer, withPresentationTime: time) else {
                        throw VideoMuxError(writer.error?.localizedDescription ?? "写入视频帧失败")
                    }
                }
            }
        }

        videoInput.markAsFinished()
        audioInput?.markAsFinished()

        // 等编码器收尾时也别死等：每 50 ms 看一次取消开关和总超时，
        // 取消时直接把 writer 停掉。
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        let deadline = Date().addingTimeInterval(180)
        while done.wait(timeout: .now() + 0.05) == .timedOut {
            if isCancelled() {
                writer.cancelWriting()
                throw CancellationError()
            }
            if Date() >= deadline {
                writer.cancelWriting()
                throw VideoMuxError("MP4 封装超时")
            }
        }
        guard writer.status == .completed else {
            throw VideoMuxError(writer.error?.localizedDescription ?? "MP4 封装失败")
        }
    }

    private static func checkCancellation(_ isCancelled: @Sendable () -> Bool) throws {
        if isCancelled() { throw CancellationError() }
    }

    private static func makePixelBuffer(index: Int,
                                        source: UnsafePointer<UInt8>,
                                        frames: VideoFrames,
                                        adaptor: AVAssetWriterInputPixelBufferAdaptor) throws -> CVPixelBuffer {
        guard let pool = adaptor.pixelBufferPool else {
            throw VideoMuxError("视频编码器没有可用的像素缓冲池")
        }
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        guard status == kCVReturnSuccess, let pixelBuffer = buffer else {
            throw VideoMuxError("分配视频帧缓冲失败（\(status)）")
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw VideoMuxError("视频帧缓冲不可写")
        }

        let width = frames.width
        let height = frames.height
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let destination = base.assumingMemoryBound(to: UInt8.self)
        let frameSource = source.advanced(by: index * width * height * 3)
        for y in 0..<height {
            var src = frameSource.advanced(by: y * width * 3)
            var dst = destination.advanced(by: y * stride)
            for _ in 0..<width {
                dst[0] = src[2]
                dst[1] = src[1]
                dst[2] = src[0]
                dst[3] = 255
                src += 3
                dst += 4
            }
        }
        return pixelBuffer
    }

    private static func appendAudio(_ audio: VideoFrames.Audio,
                                    to input: AVAssetWriterInput,
                                    writer: AVAssetWriter,
                                    isCancelled: @Sendable () -> Bool) throws {
        defer { input.markAsFinished() }
        let channels = audio.channels
        let bytesPerFrame = channels * 2
        let frames = audio.pcm.count / bytesPerFrame
        guard frames > 0 else { return }

        var asbd = AudioStreamBasicDescription(mSampleRate: Float64(audio.sampleRate),
                                               mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kLinearPCMFormatFlagIsSignedInteger
                                                   | kLinearPCMFormatFlagIsPacked,
                                               mBytesPerPacket: UInt32(bytesPerFrame),
                                               mFramesPerPacket: 1,
                                               mBytesPerFrame: UInt32(bytesPerFrame),
                                               mChannelsPerFrame: UInt32(channels),
                                               mBitsPerChannel: 16,
                                               mReserved: 0)
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = channels == 1 ? kAudioChannelLayoutTag_Mono
                                                 : kAudioChannelLayoutTag_Stereo
        var formatDescription: CMAudioFormatDescription?
        let formatStatus = withUnsafePointer(to: &layout) { pointer in
            CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                           asbd: &asbd,
                                           layoutSize: MemoryLayout<AudioChannelLayout>.size,
                                           layout: pointer,
                                           magicCookieSize: 0,
                                           magicCookie: nil,
                                           extensions: nil,
                                           formatDescriptionOut: &formatDescription)
        }
        guard formatStatus == noErr, let formatDescription else {
            throw VideoMuxError("音轨格式无效（\(formatStatus)）")
        }

        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                                                             memoryBlock: nil,
                                                             blockLength: audio.pcm.count,
                                                             blockAllocator: kCFAllocatorDefault,
                                                             customBlockSource: nil,
                                                             offsetToData: 0,
                                                             dataLength: audio.pcm.count,
                                                             flags: 0,
                                                             blockBufferOut: &blockBuffer)
        guard blockStatus == kCMBlockBufferNoErr, let blockBuffer else {
            throw VideoMuxError("音轨缓冲创建失败（\(blockStatus)）")
        }
        let copyStatus = audio.pcm.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: base,
                                                 blockBuffer: blockBuffer,
                                                 offsetIntoDestination: 0,
                                                 dataLength: audio.pcm.count)
        }
        guard copyStatus == noErr else {
            throw VideoMuxError("写入音轨数据失败（\(copyStatus)）")
        }

        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: frames,
            presentationTimeStamp: .zero,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer)
        guard sampleStatus == noErr, let sampleBuffer else {
            throw VideoMuxError("音轨采样创建失败（\(sampleStatus)）")
        }
        try waitUntilReady(input, writer: writer, isCancelled: isCancelled)
        guard input.append(sampleBuffer) else {
            throw VideoMuxError(writer.error?.localizedDescription ?? "写入音轨失败")
        }
    }

    private static func waitUntilReady(_ input: AVAssetWriterInput,
                                       writer: AVAssetWriter,
                                       isCancelled: @Sendable () -> Bool) throws {
        var spins = 0
        while !input.isReadyForMoreMediaData {
            if isCancelled() { throw CancellationError() }
            if writer.status == .failed {
                throw VideoMuxError(writer.error?.localizedDescription ?? "视频编码器写入失败")
            }
            if writer.status == .cancelled {
                throw VideoMuxError("视频编码已取消")
            }
            Thread.sleep(forTimeInterval: 0.002)
            spins += 1
            if spins > 30_000 {
                throw VideoMuxError("等待视频编码器超时")
            }
        }
    }
}

struct VideoMuxError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
