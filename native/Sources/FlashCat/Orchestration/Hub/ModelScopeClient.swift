// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import FlashCatCore
import FlashCatKit
import Foundation

/// ModelScope 的只读浏览器。
///
/// 两套接口拼出一份和 Hugging Face 同形的 `HubModel`：
/// - `/openapi/v1/models`（搜索、详情）给下载量、许可、README；
/// - `/api/v1/models/{repo}/repo/files` 给文件清单与体积，GGUF 量化选项
///   正是从这份清单里算出来的。
///
/// 这里不下载、不写盘。真正的传输由 `ms_snapshot.py` 完成，和 HF 的
/// `hf_snapshot.py` 一样只依赖引擎包里的 Python 标准库。
enum ModelScopeClient {
    static let endpoint = HubSource.modelScope.endpoint
    static let pageSize = 24
    private static let revision = "master"

    // MARK: Public

    static func search(
        query: String,
        sort: HubSort,
        filter: HubFilter,
        page: Int
    ) async throws -> ModelScopePage {
        let text = searchText(query: query, filter: filter)
        // 常量域名拼出来的地址不会失败，但项目禁 `NeverForceUnwrap`：真拼不出来时
        // 按「地址造不出来」报错，比在用户机器上崩掉好。
        guard var components = URLComponents(string: endpoint + "/openapi/v1/models") else {
            throw ModelScopeError.message("ModelScope 搜索地址拼不出来")
        }
        var items = [
            URLQueryItem(name: "search", value: text),
            URLQueryItem(name: "page_number", value: String(max(0, page) + 1)),
            URLQueryItem(name: "page_size", value: String(pageSize)),
        ]
        if sort == .downloads {
            items.append(URLQueryItem(name: "sort", value: "downloads"))
        }
        components.queryItems = items
        guard let url = components.url else {
            throw ModelScopeError.message("ModelScope 搜索地址拼不出来")
        }

        let payload: ListPayload = try await decode(url)
        let raw = payload.data?.models ?? []
        let models =
            raw
            .filter { !($0.gated ?? false) }
            .map { model(from: $0, files: [], readme: nil) }
            .filter { model in
                switch filter {
                case .all: return true
                case .gguf: return model.isGGUF
                case .mlx: return model.isMLX
                }
            }
        let total = payload.data?.totalCount ?? 0
        let hasMore = total > 0 ? (page + 1) * pageSize < total : raw.count >= pageSize
        return ModelScopePage(models: models, hasMore: hasMore)
    }

    static func detail(_ repo: String) async throws -> HubModel {
        let base = try repoPath(repo)
        let detailURL = try url(endpoint + "/openapi/v1/models/" + base)
        let filesURL = try url(
            endpoint + "/api/v1/models/" + base + "/repo/files?Revision="
                + (revision.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? revision)
                + "&Recursive=true")
        async let detailData: Data = fetch(detailURL)
        async let filesData: Data = fetch(filesURL)
        let (detailPayload, filePayload) = try await (
            decodePayload(DetailPayload.self, from: detailData),
            decodePayload(FilesPayload.self, from: filesData)
        )
        guard let item = detailPayload.data else {
            throw ModelScopeError.message("ModelScope 上没有这个仓库")
        }
        let files = filePayload.files()
        return model(from: item, files: files, readme: item.readme)
    }

    // MARK: Request

    private static func searchText(query: String, filter: HubFilter) -> String {
        var text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // ModelScope 的列表接口没有格式筛选参数（传了也被忽略），但全文搜索
        // 认得 `GGUF`/`MLX`，所以把筛选折进关键词；空查询也要给一个词，否则
        // 筛选等于没生效。
        switch filter {
        case .all:
            break
        case .gguf:
            if text.isEmpty {
                text = "GGUF"
            } else if !text.lowercased().contains("gguf") {
                text += " GGUF"
            }
        case .mlx:
            if text.isEmpty {
                text = "MLX"
            } else if !text.lowercased().contains("mlx") {
                text += " MLX"
            }
        }
        return text
    }

    private static func repoPath(_ repo: String) throws -> String {
        let trimmed = repo.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            throw ModelScopeError.message("仓库 id 要写成 owner/repo")
        }
        return parts.map {
            String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
        }.joined(separator: "/")
    }

    private static func url(_ text: String) throws -> URL {
        guard let value = URL(string: text) else {
            throw ModelScopeError.message("ModelScope 地址拼不出来")
        }
        return value
    }

    private static func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("flashCat/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ModelScopeError.message("ModelScope 没有返回 HTTP 响应")
        }
        switch http.statusCode {
        case 200..<300:
            return data
        case 401, 403:
            throw ModelScopeError.message("这个 ModelScope 仓库需要登录或授权")
        case 404:
            throw ModelScopeError.message("ModelScope 上没有这个仓库")
        case 429:
            throw ModelScopeError.message("ModelScope 请求太频繁，稍等一下再搜")
        default:
            throw ModelScopeError.message("ModelScope 返回 HTTP \(http.statusCode)")
        }
    }

    private static func decode<T: Decodable>(_ url: URL) async throws -> T {
        let data = try await fetch(url)
        return try decodePayload(T.self, from: data)
    }

    private static func decodePayload<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw ModelScopeError.message("无法解析 ModelScope 的响应：\(error.localizedDescription)")
        }
    }

    // MARK: Mapping

    private static func model(
        from item: some MSRepository,
        files: [HubFile],
        readme: String?
    ) -> HubModel {
        var tags = item.tags ?? []
        let libraries = tags.compactMap { tag -> String? in
            guard tag.hasPrefix("library:") else { return nil }
            return String(tag.dropFirst("library:".count)).lowercased()
        }
        let library = libraries.first { $0 == "gguf" || $0 == "mlx" } ?? libraries.first
        if let library {
            if !tags.contains(library) { tags.append(library) }
        } else if tags.contains("custom_tag:gguf"), !tags.contains("gguf") {
            tags.append("gguf")
        }
        if let license = item.license, !license.isEmpty,
            !tags.contains(where: { $0.hasPrefix("license:") })
        {
            tags.append("license:\(license)")
        }
        let size = item.fileSize ?? files.compactMap(\.size).reduce(0, +)
        return HubModel(
            id: item.id,
            downloads: Int(item.downloads ?? 0),
            likes: Int(item.likes ?? 0),
            pipeline: item.tasks?.first,
            libraryName: library,
            tags: tags,
            parameters: (item.params ?? 0) > 0 ? item.params : nil,
            parameterPrecision: nil,
            sizeBytes: size > 0 ? size : nil,
            files: files,
            modelCard: readme,
            gated: item.gated ?? false,
            updated: item.lastModified
        )
    }
}

/// 一页搜索结果。ModelScope 给总数，翻页判断比 HF 的「这一页满了就还有」
/// 更准。
struct ModelScopePage {
    let models: [HubModel]
    let hasMore: Bool
}

enum ModelScopeError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        if case .message(let text) = self { return text }
        return nil
    }
}

// MARK: - Wire types

/// 列表与详情共有的字段。两个接口的 JSON 只差 `readme`，所以用同一份映射。
private protocol MSRepository {
    var id: String { get }
    var downloads: Int64? { get }
    var likes: Int64? { get }
    var license: String? { get }
    var tasks: [String]? { get }
    var tags: [String]? { get }
    var fileSize: Int64? { get }
    var params: Int64? { get }
    var gated: Bool? { get }
    var lastModified: String? { get }
}

private struct ListPayload: Decodable {
    let success: Bool?
    let data: ListData?
}

private struct ListData: Decodable {
    let models: [MSModel]?
    let totalCount: Int?
}

private struct MSModel: Decodable, MSRepository {
    let id: String
    let downloads: Int64?
    let likes: Int64?
    let license: String?
    let tasks: [String]?
    let tags: [String]?
    let fileSize: Int64?
    let params: Int64?
    let gated: Bool?
    let lastModified: String?
}

private struct DetailPayload: Decodable {
    let success: Bool?
    let data: MSDetail?
}

private struct MSDetail: Decodable, MSRepository {
    let id: String
    let downloads: Int64?
    let likes: Int64?
    let license: String?
    let tasks: [String]?
    let tags: [String]?
    let fileSize: Int64?
    let params: Int64?
    let gated: Bool?
    let lastModified: String?
    let readme: String?
}

private struct FilesPayload: Decodable {
    let code: Int?
    let data: FilesData?

    enum CodingKeys: String, CodingKey {
        case code = "Code"
        case data = "Data"
    }

    func files() -> [HubFile] {
        (data?.files ?? [])
            .filter { ($0.type ?? "blob") == "blob" }
            .map { item in
                let name = item.path.hasPrefix("/") ? String(item.path.dropFirst()) : item.path
                return HubFile(name: name, size: item.size)
            }
            .filter { !$0.name.isEmpty }
            .sorted { ($0.size ?? 0) > ($1.size ?? 0) }
    }
}

private struct FilesData: Decodable {
    let files: [MSFile]?

    enum CodingKeys: String, CodingKey {
        case files = "Files"
    }
}

private struct MSFile: Decodable {
    let path: String
    let size: Int64?
    let type: String?

    enum CodingKeys: String, CodingKey {
        case path = "Path"
        case size = "Size"
        case type = "Type"
    }
}
