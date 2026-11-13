import Foundation
import AppKit
import ImageIO
import FlashCatKit

/// 输入框里挂着的待发送图片。只存路径：图可能很大，历史里也不重复拷贝。
struct ChatImageAttachment: Identifiable, Equatable {
    let id = UUID()
    let path: String
    let name: String
    var pixelSize: CGSize?
}

/// 图像参数面板的值。步数默认 20：8 步能出草稿，20 步细节更稳。
struct ImageOptions: Equatable, Codable {
    var size: String = "1024x1024"
    var steps: Int = 20
    var seed: Int?
    var strength: Double = 0.6
}

/// 图像参数跟着用户走：换会话、重启 app 之后还是上次那套尺寸和步数。
enum ImageOptionsStore {
    private static let key = "flashCat.imageOptions"
    /// 旧版本默认 8 步。默认值提到 20 之后，把没动过步数的存量配置也带过去；
    /// 只迁移一次，用户之后自己选回 8 步不会被再抬上去。
    private static let stepsMigrationKey = "flashCat.imageOptions.steps20"

    static func load() -> ImageOptions {
        var value: ImageOptions
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode(ImageOptions.self, from: data) {
            value = decoded
        } else {
            value = ImageOptions()
        }
        if !UserDefaults.standard.bool(forKey: stepsMigrationKey) {
            if value.steps == 8 { value.steps = ImageOptions().steps }
            UserDefaults.standard.set(true, forKey: stepsMigrationKey)
            save(value)
        }
        return value
    }

    static func save(_ options: ImageOptions) {
        guard let data = try? JSONEncoder().encode(options) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

// MARK: - 模型画像

/// 引擎按架构族给图像模型准备的分辨率预设。数组顺序照引擎自己的面板来，
/// 客户端不另发明尺寸；选中哪个，请求里就原样发哪个。
struct ImageSizePreset: Identifiable, Equatable {
    let width: Int
    let height: Int

    var id: String { "\(width)x\(height)" }
    var title: String { "\(width) × \(height)" }
    var orientation: String {
        if width == height { return "方形" }
        return width > height ? "横幅" : "竖幅"
    }
}

enum ImageModelFamily: String, Equatable {
    case flux, krea, mage, qwen, moss, generic
}

/// 当前图像模型的参数能力：该给哪些分辨率、步数是不是被权重固定。
///
/// `/v1/models` 只报 `meta.architecture`，不报分辨率；预设表取自引擎自己的
/// 参数面板。蒸馏包的固定步数则直接读本地 `model_index.json` 里的
/// `sample_sigmas`：引擎就是按这张表锁死采样，请求里的 `steps` 会被忽略。
struct ImageModelProfile: Equatable {
    static let minimumSide = 256

    let family: ImageModelFamily
    let fixedSteps: Int?

    init(model: EngineModel?) {
        let family = Self.family(for: model)
        self.family = family
        self.fixedSteps = Self.fixedSteps(for: model, family: family)
    }

    var presets: [ImageSizePreset] {
        switch family {
        case .flux: return Self.fluxPresets
        case .krea, .generic: return Self.kreaPresets
        case .mage: return Self.magePresets
        case .qwen: return Self.qwenPresets
        case .moss: return Self.mossPresets
        }
    }

    /// 引擎把任意宽高对齐到该族要求的倍数（FLUX 32，其余 16）。
    var alignment: Int { family == .flux ? 32 : 16 }

    var maximumSide: Int { family == .flux ? 1536 : 2048 }

    /// Mage 的采样器吃固定画布，非预设尺寸会直接报错；其余族可以自由宽高。
    var allowsCustomCanvas: Bool { family != .mage }

    func isValidCanvas(width: Int, height: Int) -> Bool {
        width >= Self.minimumSide && height >= Self.minimumSide
            && width <= maximumSide && height <= maximumSide
    }

    func clampedCanvas(width: Int, height: Int) -> (width: Int, height: Int) {
        (min(max(width, Self.minimumSide), maximumSide),
         min(max(height, Self.minimumSide), maximumSide))
    }

    static func family(for model: EngineModel?) -> ImageModelFamily {
        guard let model else { return .generic }
        let architecture = (model.architecture ?? "").lowercased()
        let id = model.id.lowercased()
        // 架构最准，先按它分。注意不能拿 id.contains("mage") 兜底：
        // "qwen-image" 里也含 "mage"，会把 Qwen 误判成 Mage。
        if architecture.hasPrefix("flux") { return .flux }
        if architecture.hasPrefix("krea") { return .krea }
        if architecture.hasPrefix("mage_flow") || architecture.hasPrefix("mageflow") {
            return .mage
        }
        if architecture.hasPrefix("qwen_image") || architecture.hasPrefix("qwen") {
            return .qwen
        }
        if architecture.hasPrefix("moss_image") || architecture.hasPrefix("moss") {
            return .moss
        }

        if id.contains("flux") { return .flux }
        if id.contains("krea") { return .krea }
        if id.contains("mage-flow") || id.contains("mage_flow") || id.contains("mageflow")
            || id.contains("/mage-") || id.contains("/mage_") {
            return .mage
        }
        if id.contains("qwen") { return .qwen }
        if id.contains("moss") { return .moss }
        return .generic
    }

    // MARK: 预设

    static let fluxPresets = [
        ImageSizePreset(width: 1024, height: 1024),
        ImageSizePreset(width: 512, height: 512),
        ImageSizePreset(width: 1152, height: 896),
        ImageSizePreset(width: 896, height: 1152),
        ImageSizePreset(width: 1216, height: 832),
        ImageSizePreset(width: 832, height: 1216),
        ImageSizePreset(width: 1344, height: 768),
        ImageSizePreset(width: 768, height: 1344),
        ImageSizePreset(width: 1536, height: 640),
    ]

    static let kreaPresets = [
        ImageSizePreset(width: 1024, height: 1024),
        ImageSizePreset(width: 768, height: 768),
        ImageSizePreset(width: 512, height: 512),
        ImageSizePreset(width: 1024, height: 1536),
        ImageSizePreset(width: 1536, height: 1024),
        ImageSizePreset(width: 1344, height: 768),
        ImageSizePreset(width: 768, height: 1344),
    ]

    static let magePresets = [
        ImageSizePreset(width: 1024, height: 1024),
        ImageSizePreset(width: 768, height: 768),
        ImageSizePreset(width: 512, height: 512),
        ImageSizePreset(width: 1024, height: 1536),
        ImageSizePreset(width: 1536, height: 1024),
        ImageSizePreset(width: 1344, height: 768),
        ImageSizePreset(width: 768, height: 1344),
        ImageSizePreset(width: 2048, height: 1152),
        ImageSizePreset(width: 2048, height: 2048),
        ImageSizePreset(width: 2048, height: 512),
        ImageSizePreset(width: 512, height: 2048),
    ]

    static let qwenPresets = [
        ImageSizePreset(width: 1024, height: 1024),
        ImageSizePreset(width: 768, height: 768),
        ImageSizePreset(width: 512, height: 512),
        ImageSizePreset(width: 832, height: 1248),
        ImageSizePreset(width: 1248, height: 832),
        ImageSizePreset(width: 1344, height: 768),
        ImageSizePreset(width: 768, height: 1344),
    ]

    static let mossPresets = [
        ImageSizePreset(width: 1024, height: 1024),
        ImageSizePreset(width: 1248, height: 1248),
        ImageSizePreset(width: 1456, height: 1456),
        ImageSizePreset(width: 832, height: 1248),
        ImageSizePreset(width: 1248, height: 832),
        ImageSizePreset(width: 1360, height: 768),
        ImageSizePreset(width: 768, height: 1360),
        ImageSizePreset(width: 1936, height: 1088),
        ImageSizePreset(width: 1088, height: 1936),
        ImageSizePreset(width: 512, height: 512),
    ]

    // MARK: 固定步数

    /// 一次 `model_index.json` 查询的结果。
    private enum StepLookup {
        /// 还没查过。
        case unknown
        /// 查过，引擎按这张 sigma 表锁死步数。
        case steps(Int)
        /// 查过，没有可用的 sigma 表。
        case missing
    }

    /// `sample_sigmas` 的记忆化。结果是文件内容的纯函数，并发重复算同一个
    /// key 只会得出同一个答案；要防的只是两张表被多线程同时读写，所以拿
    /// 一把锁把命中表与未命中表一起护住。
    private final class SampledStepMemo: @unchecked Sendable {
        private let lock = NSLock()
        private var hits: [String: Int] = [:]
        private var misses: Set<String> = []

        func lookup(_ key: String) -> StepLookup {
            lock.lock()
            defer { lock.unlock() }
            if let steps = hits[key] { return .steps(steps) }
            if misses.contains(key) { return .missing }
            return .unknown
        }

        func store(_ steps: Int?, for key: String) {
            lock.lock()
            defer { lock.unlock() }
            if let steps {
                hits[key] = steps
            } else {
                misses.insert(key)
            }
        }
    }

    private static let sampledStepMemo = SampledStepMemo()

    private static func fixedSteps(for model: EngineModel?, family: ImageModelFamily) -> Int? {
        guard let model else { return nil }
        // 引擎自己的面板对 Mage 就是锁 4 步（quality 表 [4,4,4,4]）。
        if family == .mage { return 4 }
        return sampledSteps(for: model)
    }

    /// 蒸馏模型在转换包根目录的 `model_index.json` 里写死采样 sigma 表。
    /// 表里有几步，引擎就跑几步；请求里的 `steps` 不会改变它。
    private static func sampledSteps(for model: EngineModel) -> Int? {
        let path: String
        if let reported = model.path, !reported.isEmpty,
           FileManager.default.fileExists(atPath: reported + "/model_index.json") {
            path = reported
        } else {
            path = FlashCatPaths.modelPath(for: model.engine, model: model.id)
        }
        let key = path + "/model_index.json"
        switch sampledStepMemo.lookup(key) {
        case .steps(let steps): return steps
        case .missing: return nil
        case .unknown: break
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: key)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sigmas = json["sample_sigmas"] as? [Any],
              sigmas.count > 1
        else {
            sampledStepMemo.store(nil, for: key)
            return nil
        }
        sampledStepMemo.store(sigmas.count, for: key)
        return sigmas.count
    }
}

/// 一次图像生成/编辑请求。字段照抄引擎 `/v1/images/generations` 的 JSON 契约：
/// 有 `image` 时默认走 `mode: "variation"`（保留构图重绘），显式给 `mode`
/// 时按它来（`"edit"` 需要模型自带视觉塔）。
struct ImageGenerationRequest {
    var model: String
    var prompt: String
    var size: String
    var seed: Int?
    var steps: Int?
    /// PNG/JPEG 的 base64，图生图时才有。
    var sourceBase64: String?
    var strength: Double?
    var mode: String?

    var modeLabel: String {
        switch mode {
        case "edit": return "指令编辑"
        case "variation": return "重绘"
        default: return sourceBase64 == nil ? "生成" : "重绘"
        }
    }
}

struct ImageGenerationResult {
    let png: Data
    let seconds: Double
    /// 引擎 SSE 里实际跑的步数。蒸馏包会把请求的 `steps` 改写成固定的
    /// sigma 表长度，图注要用这个值而不是用户拖出来的数字。
    let steps: Int?
}

struct ImageClientError: Error {
    let message: String
}

/// 图像端点的流式客户端。走 `stream: true` 是为了把去噪步数实时放进气泡，
/// 否则一张 1024 的图要盯着一个转圈等十几秒。取消依赖 Task 取消：`bytes(for:)`
/// 在任务取消时会掐掉连接，引擎侧看到断流就停止采样。
///
/// 唯一的状态是 `URLSession`（自身可发送），每个请求各用各的 task，
/// 所以整个对象可以安全地跨隔离域共享。
final class ImageClient: Sendable {
    private let session: URLSession

    /// 采样比对话慢一个量级，超时放宽；连不上不重试，交给上层报错。
    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1800
        configuration.timeoutIntervalForResource = 3600
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    func generate(port: Int,
                  request: ImageGenerationRequest,
                  onProgress: @escaping @Sendable (String) -> Void)
        async -> Result<ImageGenerationResult, ImageClientError> {
        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/images/generations") else {
            return .failure(ImageClientError(message: "图像端点地址无效"))
        }
        var body: [String: Any] = [
            "model": request.model,
            "prompt": request.prompt,
            "size": request.size,
            "stream": true,
        ]
        if let seed = request.seed { body["seed"] = seed }
        if let steps = request.steps { body["steps"] = steps }
        if let source = request.sourceBase64 {
            body["image"] = source
            if let strength = request.strength, request.mode != "edit" {
                body["strength"] = strength
            }
        }
        if let mode = request.mode { body["mode"] = mode }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.timeoutInterval = 1800
        do {
            urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        } catch {
            return .failure(ImageClientError(message: "请求体编码失败：\(error.localizedDescription)"))
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
                let message = Self.errorMessage(in: raw)
                    ?? "服务返回 HTTP \(http.statusCode)"
                return .failure(ImageClientError(message: message))
            }

            // 引擎在 stream:true 时回 SSE，每行 `data: {...}`；万一回的是整段
            // JSON（旧版本/代理压掉了流），先把裸行攒起来再按普通响应解析。
            var rawLines: [String] = []
            var sawEvent = false
            var observedSteps: Int?
            for try await line in bytes.lines {
                try Task.checkCancellation()
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
                    if let total = json["total"] as? Int, total > 0 {
                        observedSteps = total
                    }
                    onProgress(Self.progressText(json))
                case "error":
                    let message = (json["message"] as? String) ?? "图像生成失败"
                    return .failure(ImageClientError(message: message))
                default:
                    if let png = Self.imageData(in: json) {
                        return .success(ImageGenerationResult(png: png,
                                                             seconds: Date().timeIntervalSince(started),
                                                             steps: observedSteps))
                    }
                }
            }

            if !sawEvent, !rawLines.isEmpty,
               let data = rawLines.joined(separator: "\n").data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let message = Self.errorMessage(in: data) {
                    return .failure(ImageClientError(message: message))
                }
                if let png = Self.imageData(in: json) {
                    return .success(ImageGenerationResult(png: png,
                                                         seconds: Date().timeIntervalSince(started),
                                                         steps: observedSteps))
                }
            }
            return .failure(ImageClientError(message: "引擎没有返回图像数据"))
        } catch is CancellationError {
            return .failure(ImageClientError(message: "已取消"))
        } catch {
            let ns = error as NSError
            if ns.code == NSURLErrorCancelled {
                return .failure(ImageClientError(message: "已取消"))
            }
            return .failure(ImageClientError(message: error.localizedDescription))
        }
    }

    private static func progressText(_ json: [String: Any]) -> String {
        let stage = (json["stage"] as? String) ?? "采样"
        let step = json["step"] as? Int
        let total = json["total"] as? Int
        if let step, let total, total > 0 {
            return "\(stageName(stage)) \(step)/\(total)"
        }
        return stageName(stage)
    }

    private static func stageName(_ raw: String) -> String {
        switch raw.lowercased() {
        case "denoise", "sample", "sampling": return "去噪"
        case "encode", "text_encoder": return "读提示词"
        case "decode", "vae", "vae_decode": return "解码图像"
        case "load": return "加载模型"
        default: return raw
        }
    }

    /// 响应里既可能是 `{"data":[{"b64_json": ...}]}`，也可能是
    /// `{"type":"complete","data":[...]}`，统一取第一张图。
    private static func imageData(in json: [String: Any]) -> Data? {
        guard let items = json["data"] as? [[String: Any]], let first = items.first else { return nil }
        if let base64 = first["b64_json"] as? String,
           let data = Data(base64Encoded: base64.replacingOccurrences(of: "\n", with: "")) {
            return data
        }
        return nil
    }

    private static func errorMessage(in data: Data) -> String? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        return json["message"] as? String
    }
}

/// 生成结果落盘与回读。图片和对话历史分开存：历史只记路径，删会话不会连带
/// 删掉已经保存的作品。
enum ImageStore {
    static var directory: String { Paths.supportDirectory + "/images" }

    static func save(_ data: Data) -> String? {
        let directory = Self.directory
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let path = directory + "/" + UUID().uuidString + ".png"
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            return path
        } catch {
            return nil
        }
    }

    /// 把用户挑的外来图拷进作品目录：历史只记路径，源文件被移走也不能让
    /// 这张底图从会话里消失。
    static func importImage(atPath path: String) -> String? {
        let ext = (path as NSString).pathExtension.lowercased()
        let directory = Self.directory
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let target = directory + "/" + UUID().uuidString + "." + (ext.isEmpty ? "png" : ext)
            try FileManager.default.copyItem(atPath: path, toPath: target)
            return target
        } catch {
            return nil
        }
    }

    static func base64(atPath path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return data.base64EncodedString()
    }

    /// 参考图统一转成 JPEG：服务端只收 PNG/JPEG，HEIC 原样发会被拒；顺便按
    /// 最长边缩放，九张相机原图也不会一下把 60 MB 的请求预算吃满。
    static func jpegBase64(atPath path: String,
                           maximumPixel: CGFloat,
                           quality: CGFloat = 0.8) -> String? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maximumPixel),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0,
                                                              options as CFDictionary)
        else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .jpeg,
                                               properties: [.compressionFactor: quality])
        else { return nil }
        return data.base64EncodedString()
    }

    /// 回传给视觉模型的一张小图。1024px 是 Qwen 系视觉塔的常用输入边长：
    /// 再大 token 数暴涨，再小画面里的文字、手指就糊了。JPEG 控制请求体积，
    /// 八张图也不至于把对话请求撑到几十 MB。
    static func chatImageURL(atPath path: String, maximumPixel: CGFloat = 1024) -> String? {
        guard let base64 = jpegBase64(atPath: path, maximumPixel: maximumPixel, quality: 0.85) else {
            return nil
        }
        return "data:image/jpeg;base64," + base64
    }

    /// 只读文件头拿像素尺寸。别用 `NSImage(contentsOfFile:)`：那是整张解码，
    /// 拖入一张相机原图会把主线程卡住。
    static func pixelSize(atPath path: String) -> CGSize? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else { return nil }
        return CGSize(width: width, height: height)
    }

    /// 界面里显示用的缩略图（同步）。按「路径 + 目标像素」缓存，同一张图在
    /// 滚动、打字、流式刷新时只解码一次。
    ///
    /// 只在本来就拿得到结果的地方用：一张 2–4 MB 的 PNG 解成 520 px 要 20 ms
    /// 上下，在 `body` 里同步调用，一屏十几二十张就是一秒的主线程停顿。网格和
    /// 列表一律走 `thumbnailAsync`。
    static func thumbnail(atPath path: String, maxPixel: CGFloat) -> NSImage? {
        ImageThumbnailCache.shared.image(atPath: path, maxPixel: maxPixel)
    }

    /// 缓存里已经有的缩略图；没解过就是 nil，不会触发解码。视图首帧可以先问
    /// 这个，命中就省掉一次占位闪烁。
    static func cachedThumbnail(atPath path: String, maxPixel: CGFloat) -> NSImage? {
        ImageThumbnailCache.shared.cached(atPath: path, maxPixel: maxPixel)
    }

    /// 后台解码的缩略图。同一张图同时被多个视图要，只解一次。
    static func thumbnailAsync(atPath path: String, maxPixel: CGFloat) async -> NSImage? {
        await ImageThumbnailCache.shared.load(atPath: path, maxPixel: maxPixel)
    }
}

/// 缩略图缓存：解码放在后台队列，内存按像素成本记账。
///
/// 旧版只有 24 张的上限，比一屏还小，滚动时刚解出来的图立刻被挤掉、回头再解
/// 一遍；现在按字节记账（128 MB ≈ 一百多张 520 px 缩略图），一屏和相邻几屏都
/// 留在内存里。
///
/// 跨线程安全由两件事保证：`NSCache` 自己就是并发安全的，唯一的可变状态
/// `pending` 只在 `lock` 里读改写。
private final class ImageThumbnailCache: @unchecked Sendable {
    static let shared = ImageThumbnailCache()

    private let cache = NSCache<NSString, NSImage>()
    /// 解码走自己的并发队列：不占主线程，也不和磁盘/网络 IO 抢同一条串行队列。
    private let queue = DispatchQueue(label: "flashcat.image.thumbnail",
                                      qos: .userInitiated,
                                      attributes: .concurrent)
    private let lock = NSLock()
    /// 正在解码的 key：同一张图的后来者挂在同一个 continuation 上，不重复解码。
    private var pending: [ThumbnailKey: [CheckedContinuation<NSImage?, Never>]] = [:]

    private init() {
        cache.countLimit = 400
        cache.totalCostLimit = 128 * 1024 * 1024
    }

    func cached(atPath path: String, maxPixel: CGFloat) -> NSImage? {
        cache.object(forKey: Self.key(path, maxPixel).cacheKey)
    }

    func image(atPath path: String, maxPixel: CGFloat) -> NSImage? {
        let key = Self.key(path, maxPixel)
        if let hit = cache.object(forKey: key.cacheKey) { return hit }
        guard let made = Self.downsample(atPath: path, maxPixel: maxPixel) else { return nil }
        store(made, forKey: key)
        return made
    }

    func load(atPath path: String, maxPixel: CGFloat) async -> NSImage? {
        let key = Self.key(path, maxPixel)
        if let hit = cache.object(forKey: key.cacheKey) { return hit }
        return await withCheckedContinuation { (continuation: CheckedContinuation<NSImage?, Never>) in
            lock.lock()
            // 拿到锁以后再查一次：解码可能刚好在另一个队列上完成。
            if let hit = cache.object(forKey: key.cacheKey) {
                lock.unlock()
                continuation.resume(returning: hit)
                return
            }
            if pending[key] != nil {
                pending[key]?.append(continuation)
                lock.unlock()
                return
            }
            pending[key] = [continuation]
            lock.unlock()

            queue.async { [self] in
                let image = Self.downsample(atPath: path, maxPixel: maxPixel)
                if let image { store(image, forKey: key) }
                lock.lock()
                let waiting = pending.removeValue(forKey: key) ?? []
                lock.unlock()
                for waiter in waiting { waiter.resume(returning: image) }
            }
        }
    }

    private func store(_ image: NSImage, forKey key: ThumbnailKey) {
        let width = max(1, Int(image.size.width))
        let height = max(1, Int(image.size.height))
        cache.setObject(image, forKey: key.cacheKey, cost: width * height * 4)
    }

    /// 「路径 + 目标像素」。Swift 的字典键要用 `String`，`NSCache` 要 `NSString`，
    /// 两边各留一个视图，免得调用点到处做 `as` 转换。
    private struct ThumbnailKey: Hashable {
        let path: String
        let maxPixel: Int

        var cacheKey: NSString { "\(path)#\(maxPixel)" as NSString }
    }

    private static func key(_ path: String, _ maxPixel: CGFloat) -> ThumbnailKey {
        ThumbnailKey(path: path, maxPixel: Int(maxPixel))
    }

    private static func downsample(atPath path: String, maxPixel: CGFloat) -> NSImage? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixel),
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cgImage,
                       size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
