import Foundation

// MARK: - Hub repositories

/// What a Hugging Face repository holds, as far as this app cares.
///
/// The three engines do not share a weight format: Splash serves GGUF, MTPLX
/// wants its own packaged snapshot, oMLX takes MLX weights. A repository says
/// which one it is through metadata it publishes itself (`library_name`, tags,
/// file names) — never through the repository name, which authors choose freely.
public enum HubModelKind: String, Sendable, Equatable {
    /// Root `*.gguf` files, or split GGUFs kept one-per-`VARIANT/` folder.
    case gguf
    /// An MTPLX pack: its own runtime snapshot plus the `mtp.safetensors` head.
    case mtplx
    /// MLX weights, marked as such by `library_name = mlx` or the `mlx` tag.
    case mlx
    /// `config.json` + safetensors with no MLX marker at all — it *might* load,
    /// nothing in the repository promises it.
    case unmarked
    /// Neither weights nor a layout this app can serve (ONNX, `.bin`, empty).
    case unknown
}

/// One selectable GGUF file inside a repository.
///
/// `name` is exactly what Splash takes after the colon in `owner/repo:VARIANT`
/// — see `HubModelLayout.ggufVariants` for how it is derived — and is `nil` when
/// the repository holds a single target GGUF and the engine wants no variant.
public struct GGUFVariant: Sendable, Equatable {
    public let name: String?
    public let bytes: Int
    public let files: [String]

    public init(name: String?, bytes: Int, files: [String]) {
        self.name = name
        self.bytes = bytes
        self.files = files
    }
}

/// One repository as the Hub API describes it. `paths` and `sizes` come from
/// the repository listing (`?blobs=true`), which is the only endpoint that
/// reports both files and their byte counts in one request.
public struct HubModel: Sendable, Equatable, Identifiable {
    public let id: String
    public let downloads: Int
    public let libraryName: String?
    public let tags: [String]
    public let paths: [String]
    public let sizes: [String: Int]

    public init(id: String,
                downloads: Int = 0,
                libraryName: String? = nil,
                tags: [String] = [],
                paths: [String] = [],
                sizes: [String: Int] = [:]) {
        self.id = id
        self.downloads = downloads
        self.libraryName = libraryName
        self.tags = tags
        self.paths = paths
        self.sizes = sizes
    }

    public var kind: HubModelKind {
        HubModelLayout.kind(libraryName: libraryName, tags: tags, paths: paths)
    }

    /// Every GGUF the engine can be pointed at, in repository order.
    public var ggufVariants: [GGUFVariant] {
        HubModelLayout.ggufVariants(paths: paths, sizes: sizes)
    }

    /// Bytes of the weights for a chosen GGUF variant, or the whole snapshot
    /// for the other layouts. `variant` is ignored outside GGUF repositories.
    public func weightBytes(ggufVariant variant: String? = nil) -> Int {
        HubModelLayout.weightBytes(kind: kind,
                                   paths: paths,
                                   sizes: sizes,
                                   ggufVariant: variant)
    }
}

public enum HubModelLayout {
    /// Classify a repository.
    ///
    /// Precedence, highest first: the author's own `library_name`, then the
    /// evidence that Splash can serve the repository (a `.gguf` at the root or a
    /// complete split folder), then an MTPLX runtime (`mtp.safetensors`), then
    /// MLX. An MTPLX pack also carries the `mlx` tag, so its own tag has to win
    /// over that one; a repository holding `.gguf` files is served by Splash no
    /// matter what else it carries.
    public static func kind(libraryName: String?, tags: [String], paths: [String]) -> HubModelKind {
        let library = libraryName?.lowercased()
        let tags = Set(tags.map { $0.lowercased() })
        let lowered = paths.map { $0.lowercased() }

        if library == "mtplx" {
            return .mtplx
        }
        if library == "gguf"
            || tags.contains("gguf")
            || !rootGGUFs(paths).isEmpty
            || !splitGGUFFolders(paths).isEmpty {
            return .gguf
        }
        if lowered.contains("mtp.safetensors")
            || lowered.contains("mtplx_runtime.json") {
            return .mtplx
        }
        if library == "mlx" || tags.contains("mlx") {
            return .mlx
        }
        if paths.contains("config.json"), paths.contains(where: { $0.hasSuffix(".safetensors") }) {
            return .unmarked
        }
        return .unknown
    }

    /// The GGUFs at a repository's root that the engine will load.
    ///
    /// Mirrors Splash's own rule: a root `.gguf` is a target unless it is a
    /// vision projector (`mmproj-*.gguf`, `MODEL-mmproj-*.gguf`).
    public static func rootGGUFs(_ paths: [String]) -> [String] {
        paths.filter { path in
            guard !path.contains("/"), path.hasSuffix(".gguf") else { return false }
            return !isProjector(path)
        }
    }

    public static func isProjector(_ path: String) -> Bool {
        (path as NSString).deletingPathExtension.lowercased().contains("mmproj")
    }

    /// Every `VARIANT/` folder holding a complete split GGUF (`…-00001-of-0000N.gguf`).
    public static func splitGGUFFolders(_ paths: [String]) -> [(variant: String, files: [String])] {
        var parts: [String: [(index: Int, total: Int, path: String)]] = [:]
        for path in paths {
            guard let split = splitName(path) else { continue }
            parts[split.variant, default: []].append((split.index, split.total, path))
        }
        var folders: [(String, [String])] = []
        for (variant, files) in parts.sorted(by: { $0.key < $1.key }) {
            guard let total = files.first?.total,
                  files.allSatisfy({ $0.total == total }),
                  Set(files.map(\.index)) == Set(1...total),
                  files.count == total else { continue }
            folders.append((variant, files.sorted { $0.index < $1.index }.map(\.path)))
        }
        return folders
    }

    /// `VARIANT/MODEL-VARIANT-00001-of-00002.gguf` → its folder, order and count.
    ///
    /// Splash only splits a folder when every part matches
    /// `-\d{5}-of-\d{5}\.gguf` (`install/upstream.py:SPLIT_NAME`), so a shorter
    /// part number is not a split at all.
    private static func splitName(_ path: String) -> (variant: String, index: Int, total: Int)? {
        let pieces = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard pieces.count == 2, !isProjector(pieces[1]) else { return nil }
        let name = pieces[1]
        guard name.hasSuffix(".gguf") else { return nil }
        let stem = String(name.dropLast(".gguf".count))
        let words = stem.split(separator: "-").map(String.init)
        // `NAME-00001-of-00002`: the part number, then `of`, then the count.
        guard words.count >= 3,
              words[words.count - 2] == "of",
              words[words.count - 3].count == 5, words[words.count - 3].allSatisfy(\.isNumber),
              words[words.count - 1].count == 5, words[words.count - 1].allSatisfy(\.isNumber),
              let index = Int(words[words.count - 3]),
              let total = Int(words[words.count - 1]),
              index >= 1, total >= 1, index <= total else { return nil }
        return (pieces[0], index, total)
    }

    /// The variants a GGUF repository offers, named the way the engine matches
    /// them.
    ///
    /// Splash's `install/upstream.py:select_gguf` resolves `:VARIANT` in two
    /// shapes, and this mirrors both rather than inventing a rule of its own:
    /// the root files' names minus the word prefix they all share
    /// (`X-Q4_K_M.gguf` → `Q4_K_M`), and the folder name of a split GGUF
    /// (`Q2_0/…-00001-of-00002.gguf` → `Q2_0`). A repository with exactly one
    /// root GGUF names no variant. A file whose name adds nothing after the
    /// shared prefix stays reachable through the engine's second rule — the
    /// shortest tail that ends `-VARIANT` for that file alone — and only a name
    /// no tail can pick out is left out.
    public static func ggufVariants(paths: [String], sizes: [String: Int]) -> [GGUFVariant] {
        var variants: [GGUFVariant] = []
        var used = Set<String>()

        let folders = splitGGUFFolders(paths)
        for folder in folders {
            let bytes = folder.files.reduce(0) { $0 + (sizes[$1] ?? 0) }
            guard used.insert(folder.variant).inserted else { continue }
            variants.append(GGUFVariant(name: folder.variant, bytes: bytes, files: folder.files))
        }

        let roots = rootGGUFs(paths)
        let words = roots.map { path -> [String] in
            (path as NSString).deletingPathExtension.split(separator: "-").map(String.init)
        }
        let shared = commonPrefixLength(words)
        for (path, name) in zip(roots, words) {
            var rest = Array(name.dropFirst(shared))
            if rest.isEmpty {
                // The shared prefix ate the whole name, so only the suffix rule
                // can reach this file.
                guard let token = uniqueSuffix(for: path, among: roots) else { continue }
                rest = [token]
            }
            let token = rest.joined(separator: "-")
            guard used.insert(token).inserted else { continue }
            variants.append(GGUFVariant(name: token,
                                        bytes: sizes[path] ?? 0,
                                        files: [path]))
        }
        // One root GGUF and no split folders: the engine needs no variant, and
        // the shared prefix swallowing the whole name is the normal shape here.
        if roots.count == 1, folders.isEmpty {
            variants = [GGUFVariant(name: nil, bytes: sizes[roots[0]] ?? 0, files: [roots[0]])]
        }
        return variants
    }

    /// The shortest tail of `path` that the engine's `-VARIANT` suffix rule
    /// resolves to `path` and nothing else in `roots`.
    private static func uniqueSuffix(for path: String, among roots: [String]) -> String? {
        let name = (path as NSString).deletingPathExtension
        let words = name.split(separator: "-").map(String.init)
        let stems = roots.map { ($0 as NSString).deletingPathExtension.lowercased() }
        let lowered = name.lowercased()
        for length in 1...max(words.count, 1) {
            let token = words.suffix(length).joined(separator: "-")
            let matches = stems.filter { $0.hasSuffix("-" + token.lowercased()) }
            if matches == [lowered] { return token }
            if matches.isEmpty { return nil }
        }
        return nil
    }

    private static func commonPrefixLength(_ words: [[String]]) -> Int {
        guard let first = words.first else { return 0 }
        var shared = first.count
        for other in words.dropFirst() {
            var count = 0
            while count < shared, count < other.count, first[count] == other[count] { count += 1 }
            shared = count
        }
        return shared
    }

    /// Weight bytes to download: the chosen GGUF, or every safetensors file for
    /// the other layouts. `mtp.safetensors` counts — MTPLX cannot serve without it.
    public static func weightBytes(kind: HubModelKind,
                                   paths: [String],
                                   sizes: [String: Int],
                                   ggufVariant variant: String?) -> Int {
        switch kind {
        case .gguf:
            let variants = ggufVariants(paths: paths, sizes: sizes)
            if let variant, let match = variants.first(where: { $0.name == variant }) {
                return match.bytes
            }
            return variants.map(\.bytes).max() ?? 0
        case .mtplx, .mlx, .unmarked:
            return paths
                .filter { $0.hasSuffix(".safetensors") }
                .reduce(0) { $0 + (sizes[$1] ?? 0) }
        case .unknown:
            return 0
        }
    }

    /// Unified-memory floor, in GiB, for a snapshot of `bytes`: weights plus a
    /// fifth for the KV cache and the runtime. Compared against
    /// `DeviceProfile.memoryGB`, so the divisor is the same GiB.
    public static func estimatedMemoryGB(bytes: Int) -> Int {
        guard bytes > 0 else { return 0 }
        let gib = Double(bytes) * 1.2 / 1_073_741_824
        return max(1, Int(gib.rounded(.up)))
    }
}

// MARK: - Hub API

public enum HubError: Error, LocalizedError, Equatable {
    case http(Int)
    case decoding
    case notFound(String)

    public var errorDescription: String? {
        switch self {
        case .http(let status): return "Hugging Face 返回 HTTP \(status)"
        case .decoding: return "无法解析 Hugging Face 的响应"
        case .notFound(let repo): return "Hugging Face 上找不到 \(repo)"
        }
    }
}

/// Search and fetch over the Hub API. Unauthenticated on purpose: gated and
/// private repositories are out of scope, so a repository this client cannot
/// read is simply not a result.
public actor HubSearchClient {
    private let session: URLSession
    private let baseURL: URL
    private var cache: [String: HubModel] = [:]

    public init(session: URLSession = .shared,
                baseURL: URL = URL(string: "https://huggingface.co")!) {
        self.session = session
        self.baseURL = baseURL
    }

    /// Repositories whose metadata says they hold servable weights, most
    /// downloaded first. Repositories the client cannot read anonymously are
    /// dropped here rather than surfaced and then failed at download time.
    public func search(_ query: String, limit: Int = 20) async throws -> [HubModel] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var components = URLComponents(url: baseURL.appendingPathComponent("api/models"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "search", value: trimmed),
            URLQueryItem(name: "limit", value: String(max(1, min(limit, 50)))),
            URLQueryItem(name: "sort", value: "downloads"),
            URLQueryItem(name: "direction", value: "-1"),
            URLQueryItem(name: "full", value: "true"),
        ]
        guard let url = components.url else { throw HubError.decoding }
        let entries = try await get(url)
        guard let raw = try? JSONSerialization.jsonObject(with: entries) as? [[String: Any]] else {
            throw HubError.decoding
        }
        return raw.compactMap(Self.model(from:)).filter { $0.kind != .unknown }
    }

    /// One repository with file sizes. The list endpoint reports `size` as null,
    /// so the per-repository endpoint (`?blobs=true`) is what fills them in; its
    /// answer is cached because the page may redraw many times per search.
    public func model(_ repo: String) async throws -> HubModel {
        if let cached = cache[repo] { return cached }
        var components = URLComponents(url: baseURL.appendingPathComponent("api/models/\(repo)"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "blobs", value: "true")]
        guard let url = components.url else { throw HubError.decoding }
        let data = try await get(url)
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = Self.model(from: raw) else {
            throw HubError.decoding
        }
        cache[repo] = model
        return model
    }

    /// Fills in sizes for a batch of search results, a few at a time so a search
    /// cannot open twenty sockets at once. A repository that fails keeps its
    /// metadata and simply carries no byte counts.
    public func enrich(_ models: [HubModel], concurrent: Int = 4) async -> [HubModel] {
        var result: [HubModel] = []
        result.reserveCapacity(models.count)
        for chunk in stride(from: 0, to: models.count, by: max(1, concurrent)).map({
            Array(models[$0..<min($0 + max(1, concurrent), models.count)])
        }) {
            let enriched = await withTaskGroup(of: HubModel.self) { group in
                for model in chunk {
                    group.addTask {
                        (try? await self.model(model.id)) ?? model
                    }
                }
                var collected: [HubModel] = []
                for await model in group { collected.append(model) }
                return collected
            }
            // `withTaskGroup` yields in completion order; the page keeps the
            // Hub's ranking, so the chunk is re-sorted back into it.
            result.append(contentsOf: chunk.map { model in
                enriched.first { $0.id == model.id } ?? model
            })
        }
        return result
    }

    static func model(from raw: [String: Any]) -> HubModel? {
        guard let id = (raw["id"] as? String) ?? (raw["modelId"] as? String) else { return nil }
        // `gated` is `false`, `"auto"`, `"manual"` — anything but false needs a
        // token, and this client has none.
        if let gated = raw["gated"], !(gated is Bool) || (gated as? Bool) == true { return nil }
        if (raw["private"] as? Bool) == true { return nil }
        let siblings = (raw["siblings"] as? [[String: Any]]) ?? []
        let paths = siblings.compactMap { $0["rfilename"] as? String }
        var sizes: [String: Int] = [:]
        for sibling in siblings {
            guard let name = sibling["rfilename"] as? String, let size = sibling["size"] as? Int else { continue }
            sizes[name] = size
        }
        return HubModel(id: id,
                        downloads: (raw["downloads"] as? Int) ?? 0,
                        libraryName: raw["library_name"] as? String,
                        tags: (raw["tags"] as? [String]) ?? [],
                        paths: paths,
                        sizes: sizes)
    }

    private func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("flashCat", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            if http.statusCode == 404 { throw HubError.notFound(url.lastPathComponent) }
            throw HubError.http(http.statusCode)
        }
        return data
    }
}
