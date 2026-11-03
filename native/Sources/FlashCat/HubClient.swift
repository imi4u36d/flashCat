import Foundation
import FlashCatKit

/// Hugging Face 的只读浏览器：搜索/推荐列表，加上单个仓库的详情（文件清单、
/// 参数量、README 模型卡）。
///
/// 这里只负责「看清楚再决定下不下」——真正的下载仍然交给引擎包里的
/// huggingface_hub（`ModelInstaller.sharedPlan`），所以这条链路不碰磁盘、
/// 不写缓存，失败也只是列表空着，不影响已装模型。
enum HubClientError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        if case let .message(text) = self { return text }
        return nil
    }
}

/// 列表排序：`trending` 是 HF 的 trendingScore（最近热度），`downloads` 是
/// 累计下载量。两者差别很大——trending 会冒出很多小众新仓，而下载量榜全是
/// 老牌大仓，所以下载页两种都要给。
enum HubSort: String {
    case trending
    case downloads
}

/// 只要某一类权重。不同引擎吃的格式差别很大（MLX 权重 / GGUF 单文件），
/// 先在服务端筛掉一半噪音，比自己翻十页强。
enum HubFilter: String, CaseIterable {
    case all
    case mlx
    case gguf

    /// HF 的 `filter` 参数值；`all` 不带这个参数。
    var apiValue: String? {
        switch self {
        case .all: return nil
        case .mlx: return "mlx"
        case .gguf: return "gguf"
        }
    }
}

struct HubFile: Hashable {
    let name: String
    let size: Int64?

    var json: [String: Any] {
        var item: [String: Any] = ["name": name]
        if let size { item["size"] = size }
        return item
    }
}

struct HubModel: Identifiable, Hashable {
    let id: String
    var downloads: Int = 0
    var likes: Int = 0
    var pipeline: String?
    var libraryName: String?
    var tags: [String] = []
    /// `safetensors.total`。GGUF 仓库没有 safetensors，这里就是 nil。
    var parameters: Int64?
    /// 权重的主精度（BF16 / F16 / F32…），来自 `safetensors.parameters`。
    var parameterPrecision: String?
    var sizeBytes: Int64?
    var files: [HubFile] = []
    var modelCard: String?
    var gated = false
    var updated: String?

    var license: String? {
        tags.first { $0.hasPrefix("license:") }.map { String($0.dropFirst("license:".count)) }
    }

    /// MLX 量化仓（mlx-community / Jundot / mlx-works 这类）。
    var isMLX: Bool {
        tags.contains("mlx") || id.lowercased().contains("mlx")
    }

    /// GGUF 单文件/分片仓。
    var isGGUF: Bool {
        tags.contains("gguf") || id.lowercased().contains("gguf")
    }

    /// MTPLX 只服务自带校准 MTP 头的 Youssofal 包。
    var isMTPLPack: Bool {
        id.lowercased().hasPrefix("youssofal/") && id.lowercased().contains("mtplx")
    }

    var layoutKind: HubModelKind {
        if isMTPLPack { return .mtplx }
        return HubModelLayout.kind(libraryName: libraryName,
                                   tags: tags,
                                   paths: files.map(\.name))
    }

    var ioTypes: HubIOTypes? {
        HubModelLayout.ioTypes(pipelineTag: pipeline, tags: tags)
    }

    /// A compact, user-facing quantization label. Multi-quant GGUF repos show
    /// two examples and the remaining count rather than pretending one quant
    /// represents the whole repository.
    var quantization: String? {
        switch layoutKind {
        case .gguf:
            let names = ggufVariantNames
            if !names.isEmpty {
                let shown = names.prefix(2).joined(separator: " / ")
                return names.count > 2 ? "\(shown) +\(names.count - 2)" : shown
            }
            return ggufPathQuant ?? lowBitLabel ?? "GGUF"
        case .mlx:
            return lowBitLabel ?? parameterPrecision ?? "MLX"
        case .mtplx:
            return lowBitLabel ?? parameterPrecision ?? "MTP 包"
        case .unmarked:
            return parameterPrecision ?? "原版权重"
        case .unknown:
            return nil
        }
    }

    /// Unified-memory floor in GiB. For a repository with several GGUF quants,
    /// this is the range across those files.
    var memoryRange: ClosedRange<Int>? {
        if layoutKind == .gguf, !ggufVariantNames.isEmpty {
            let variants = HubModelLayout.ggufVariants(
                paths: files.map(\.name),
                sizes: Dictionary(uniqueKeysWithValues: normalizedSizes.map { ($0.key, Int($0.value)) })
            )
            let memories = variants.compactMap { variant -> Int? in
                guard variant.bytes > 0 else { return nil }
                return HubModelLayout.estimatedMemoryGB(bytes: variant.bytes)
            }
            if let low = memories.min(), let high = memories.max() {
                return low...high
            }
        }
        let bytes = actualWeightBytes > 0 ? actualWeightBytes : estimatedWeightBytes
        guard bytes > 0 else { return nil }
        let memory = HubModelLayout.estimatedMemoryGB(bytes: Int(clamping: bytes))
        return memory...memory
    }

    /// The engine this repository's format is meant for. A plain transformers
    /// snapshot is intentionally not promised to any runtime.
    var recommendedEngine: (id: String, label: String) {
        let engines = HubSearchState.engines(for: layoutKind)
        guard let id = EngineCatalog.allIDs.first(where: { engines.contains($0) }) else {
            return ("none", "无推荐")
        }
        return (id.rawValue, id.displayName)
    }

    var json: [String: Any] {
        var item: [String: Any] = [
            "id": id,
            "downloads": downloads,
            "likes": likes,
            "tags": tags,
            "mlx": isMLX,
            "gguf": isGGUF,
            "mtplx": isMTPLPack,
            "gated": gated,
        ]
        if let pipeline { item["pipeline"] = pipeline }
        if let io = ioTypes?.label { item["io"] = io }
        if let quantization { item["quantization"] = quantization }
        if let memoryRange {
            item["memoryMin"] = memoryRange.lowerBound
            item["memoryMax"] = memoryRange.upperBound
        }
        let engine = recommendedEngine
        item["engine"] = engine.label
        item["engineID"] = engine.id
        if let parameters { item["parameters"] = parameters }
        if let sizeBytes { item["size"] = sizeBytes }
        if let license { item["license"] = license }
        if let updated { item["updated"] = updated }
        if !files.isEmpty { item["files"] = files.map(\.json) }
        if let modelCard, !modelCard.isEmpty { item["modelCard"] = modelCard }
        return item
    }

    private var normalizedSizes: [String: Int64] {
        Dictionary(uniqueKeysWithValues: files.compactMap { file in
            file.size.map { (file.name, $0) }
        })
    }

    private var ggufVariantNames: [String] {
        let sizes = Dictionary(uniqueKeysWithValues: normalizedSizes.map { ($0.key, Int(clamping: $0.value)) })
        var seen = Set<String>()
        return HubModelLayout.ggufVariants(paths: files.map(\.name), sizes: sizes)
            .compactMap(\.name)
            .filter { seen.insert($0).inserted }
    }

    private var ggufPathQuant: String? {
        let pattern = #"(?i)(?:IQ[1-4](?:_[A-Z0-9]+)+|Q[2-8](?:_[A-Z0-9]+)+|BF16|F16|FP16|F32|FP32)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        for file in files where file.name.lowercased().hasSuffix(".gguf") {
            let range = NSRange(file.name.startIndex..., in: file.name)
            if let match = regex.firstMatch(in: file.name, range: range),
               let matchRange = Range(match.range, in: file.name) {
                return String(file.name[matchRange]).uppercased()
            }
        }
        return nil
    }

    private var lowBitLabel: String? {
        let haystacks = tags + files.map(\.name) + [id]
        for value in haystacks {
            let normalized = value.lowercased()
                .replacingOccurrences(of: "_", with: "-")
                .replacingOccurrences(of: " ", with: "-")
            for bits in stride(from: 2, through: 8, by: 2) {
                if normalized.contains("\(bits)-bit") || normalized.contains("\(bits)bit") {
                    return "\(bits)-bit"
                }
            }
        }
        return nil
    }

    private var actualWeightBytes: Int64 {
        if layoutKind == .gguf {
            let sizes = Dictionary(uniqueKeysWithValues: normalizedSizes.map { ($0.key, Int(clamping: $0.value)) })
            let bytes = HubModelLayout.weightBytes(
                kind: layoutKind,
                paths: files.map(\.name),
                sizes: sizes,
                ggufVariant: nil
            )
            return Int64(bytes)
        }
        return files
            .filter { $0.name.lowercased().hasSuffix(".safetensors") }
            .compactMap(\.size)
            .reduce(0, +)
    }

    private var estimatedWeightBytes: Int64 {
        guard let parameters, parameters > 0 else { return 0 }
        let bytesPerParameter: Double
        if lowBitLabel == "4-bit" {
            bytesPerParameter = 0.5
        } else if lowBitLabel == "8-bit" {
            bytesPerParameter = 1
        } else {
            switch parameterPrecision?.uppercased() {
            case "F32", "FP32": bytesPerParameter = 4
            case "F16", "FP16", "BF16": bytesPerParameter = 2
            default: bytesPerParameter = 2
            }
        }
        return Int64((Double(parameters) * bytesPerParameter).rounded(.up))
    }
}

enum HubClient {
    /// 端点可被 `hfEndpoint` 覆盖（镜像站/内网代理）。host 之后的部分全是
    /// 标准 HF 的 REST 路径，镜像站（hf-mirror 这类）都兼容。
    static var endpoint: String {
        let raw = UserDefaults.standard.string(forKey: "hfEndpoint")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let base = raw.isEmpty ? "https://huggingface.co" : raw
        return base.hasSuffix("/") ? String(base.dropLast()) : base
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    /// 详情按仓库记忆一次：模型卡是整篇 README（几个 KB），来回翻 tab 不该
    /// 反复下载。只缓存在内存里，最多留 60 个仓库。
    private static var cache: [String: HubModel] = [:]
    private static var cacheOrder: [String] = []

    /// 一页的条数。HF 的 `skip` 就是纯偏移量，所以翻页不需要游标，
    /// 「第 N 页」算得出来，也能直接跳回上一页。
    static let pageSize = 30

    static func search(
        query: String,
        sort: HubSort,
        filter: HubFilter = .all,
        page: Int = 0,
        limit: Int = pageSize
    ) async throws -> [HubModel] {
        var components = URLComponents(string: endpoint + "/api/models")!
        var items: [URLQueryItem] = []
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { items.append(URLQueryItem(name: "search", value: trimmed)) }
        items.append(URLQueryItem(name: "limit", value: String(limit)))
        if page > 0 { items.append(URLQueryItem(name: "skip", value: String(page * limit))) }
        items.append(URLQueryItem(name: "direction", value: "-1"))
        items.append(URLQueryItem(
            name: "sort",
            value: sort == .trending ? "trendingScore" : "downloads"
        ))
        if let value = filter.apiValue { items.append(URLQueryItem(name: "filter", value: value)) }
        // 不带 expand 的话列表里没有参数量和下载量；gated 与体积只有详情才有。
        for key in ["safetensors", "downloads", "likes", "library_name",
                    "pipeline_tag", "tags", "lastModified"] {
            items.append(URLQueryItem(name: "expand[]", value: key))
        }
        components.queryItems = items
        guard let url = components.url else {
            throw HubClientError.message("搜索地址拼不出来")
        }
        let data = try await get(url)
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw HubClientError.message("Hugging Face 返回了意外的响应")
        }
        return array.compactMap(model(from:))
    }

    /// Metadata and file sizes for one repository, without the README. Search
    /// rows use this to fill quantization and memory after the list is already
    /// on screen; opening the model card still adds the README separately.
    static func metadata(_ repo: String, force: Bool = false) async throws -> HubModel {
        let key = repo.trimmingCharacters(in: .whitespacesAndNewlines)
        if !force, let cached = cache[key] { return cached }
        let model = try await fetchMetadata(key)
        store(model)
        return model
    }

    /// A page of search hits enriched in small batches. The first rows are done
    /// before the rest, and one failed repository simply keeps its list data.
    static func enrich(_ models: [HubModel], concurrent: Int = 6) async -> [HubModel] {
        var result: [HubModel] = []
        result.reserveCapacity(models.count)
        let width = max(1, concurrent)
        for start in stride(from: 0, to: models.count, by: width) {
            let chunk = Array(models[start..<min(start + width, models.count)])
            let enriched = await withTaskGroup(of: (String, HubModel?).self) { group in
                for model in chunk {
                    group.addTask {
                        (model.id, try? await fetchMetadata(model.id))
                    }
                }
                var values: [String: HubModel] = [:]
                for await (id, model) in group {
                    if let model { values[id] = model }
                }
                return values
            }
            for original in chunk {
                let model = enriched[original.id] ?? original
                if model.files.isEmpty == false { store(model) }
                result.append(model)
            }
        }
        return result
    }

    static func detail(_ repo: String, force: Bool = false) async throws -> HubModel {
        let key = repo.trimmingCharacters(in: .whitespacesAndNewlines)
        if !force, let cached = cache[key], cached.modelCard != nil { return cached }
        var model = try await metadata(key, force: force)
        model.modelCard = try? await card(key)
        store(model)
        return model
    }

    private static func fetchMetadata(_ key: String) async throws -> HubModel {
        guard !key.isEmpty else { throw HubClientError.message("仓库 id 是空的") }
        let path = key.split(separator: "/")
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        guard let url = URL(string: endpoint + "/api/models/" + path + "?blobs=true") else {
            throw HubClientError.message("仓库 id 不合法：\(key)")
        }
        let data = try await get(url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var model = model(from: object) else {
            throw HubClientError.message("找不到这个仓库：\(key)")
        }
        if let siblings = object["siblings"] as? [[String: Any]] {
            model.files = siblings.compactMap { entry in
                guard let name = entry["rfilename"] as? String else { return nil }
                return HubFile(name: name, size: (entry["size"] as? NSNumber)?.int64Value)
            }.sorted { ($0.size ?? 0) > ($1.size ?? 0) }
            let total = model.files.compactMap(\.size).reduce(Int64(0), +)
            if total > 0 { model.sizeBytes = total }
        }
        return model
    }

    /// README 就是模型卡。走 `raw/main`：拿到的是原始 markdown，前端用自己的
    /// `md()` 渲染，不再引一份 markdown 库。
    private static func card(_ repo: String) async throws -> String? {
        let path = repo.split(separator: "/")
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        for name in ["README.md", "readme.md", "README.MD"] {
            guard let url = URL(string: endpoint + "/" + path + "/raw/main/" + name) else { continue }
            if let data = try? await get(url), let text = String(data: data, encoding: .utf8) {
                return stripFrontMatter(text)
            }
        }
        return nil
    }

    /// HF 的 README 开头是一段 `---` 包起来的 YAML（license/tags/base_model…），
    /// 前端渲染会被当成水平线 + 一堆正文，看着很脏。这些都解析进字段了，删掉。
    private static func stripFrontMatter(_ text: String) -> String {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(
            separator: "\n", omittingEmptySubsequences: false
        )
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" else {
            return text
        }
        guard let end = lines.dropFirst().firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "---"
        }) else { return text }
        return lines[(end + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func model(from object: [String: Any]) -> HubModel? {
        guard let id = object["id"] as? String, !id.isEmpty else { return nil }
        var model = HubModel(id: id)
        model.downloads = (object["downloads"] as? NSNumber)?.intValue ?? 0
        model.likes = (object["likes"] as? NSNumber)?.intValue ?? 0
        model.pipeline = object["pipeline_tag"] as? String
        model.libraryName = object["library_name"] as? String
        model.tags = object["tags"] as? [String] ?? []
        model.gated = (object["gated"] as? Bool) ?? false
        model.updated = object["lastModified"] as? String
        if let safetensors = object["safetensors"] as? [String: Any] {
            model.parameters = (safetensors["total"] as? NSNumber)?.int64Value
            if let parameters = safetensors["parameters"] as? [String: Any] {
                model.parameterPrecision = parameters.compactMap { name, value -> (String, Int64)? in
                    guard let count = (value as? NSNumber)?.int64Value else { return nil }
                    return (name, count)
                }.max { $0.1 < $1.1 }?.0.uppercased()
            }
        }
        return model
    }

    private static func store(_ model: HubModel) {
        if cache[model.id] == nil {
            cacheOrder.append(model.id)
            if cacheOrder.count > 60, let oldest = cacheOrder.first {
                cacheOrder.removeFirst()
                cache.removeValue(forKey: oldest)
            }
        }
        cache[model.id] = model
    }

    private static func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // 私有/受限仓库需要 token；没有就当公开仓库查，401/403 下面翻成人话。
        if let token = UserDefaults.standard.string(forKey: "hfToken"), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HubClientError.message("Hugging Face 没有响应")
        }
        switch http.statusCode {
        case 200..<300:
            return data
        case 401, 403:
            throw HubClientError.message("这个仓库要登录授权，先在设置里填 Hugging Face token")
        case 404:
            throw HubClientError.message("Hugging Face 上没有这个仓库")
        case 429:
            throw HubClientError.message("请求太频繁，稍等一下再搜")
        default:
            throw HubClientError.message("Hugging Face 返回 \(http.statusCode)")
        }
    }
}
