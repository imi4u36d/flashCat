import Foundation

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

/// 只要某一类权重。三个引擎吃的格式差别很大（MLX 权重 / GGUF 单文件），
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
    var tags: [String] = []
    /// `safetensors.total`。GGUF 仓库没有 safetensors，这里就是 nil。
    var parameters: Int64?
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
        if let parameters { item["parameters"] = parameters }
        if let sizeBytes { item["size"] = sizeBytes }
        if let license { item["license"] = license }
        if let updated { item["updated"] = updated }
        if !files.isEmpty { item["files"] = files.map(\.json) }
        if let modelCard, !modelCard.isEmpty { item["modelCard"] = modelCard }
        return item
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
        for key in ["safetensors", "downloads", "likes", "pipeline_tag", "tags", "lastModified"] {
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

    static func detail(_ repo: String, force: Bool = false) async throws -> HubModel {
        let key = repo.trimmingCharacters(in: .whitespacesAndNewlines)
        if !force, let cached = cache[key] { return cached }
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
        model.modelCard = try? await card(key)
        store(model)
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
        model.tags = object["tags"] as? [String] ?? []
        model.gated = (object["gated"] as? Bool) ?? false
        model.updated = object["lastModified"] as? String
        if let safetensors = object["safetensors"] as? [String: Any] {
            model.parameters = (safetensors["total"] as? NSNumber)?.int64Value
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
