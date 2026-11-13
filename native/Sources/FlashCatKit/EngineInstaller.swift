import CryptoKit
import Foundation

// MARK: - Pack index

/// One downloadable runtime pack. The index only describes *where* a pack is
/// and how to prove it arrived intact: everything else the app needs lives in
/// the manifest inside the archive.
public struct EnginePackRelease: Codable, Sendable, Equatable {
    public var version: String
    /// Absolute download address. An index names archives relative to itself
    /// (so the same index serves every machine); `loadIndex` turns those into
    /// absolute addresses before anyone tries to fetch them.
    public var url: String
    public var sha256: String
    public var bytes: Int?
    public var minMacOS: String?
    public var notes: String?

    public init(version: String,
                url: String,
                sha256: String,
                bytes: Int? = nil,
                minMacOS: String? = nil,
                notes: String? = nil) {
        self.version = version
        self.url = url
        self.sha256 = sha256
        self.bytes = bytes
        self.minMacOS = minMacOS
        self.notes = notes
    }

    /// The index a release arrived on is the base its relative address hangs
    /// off: the same index has to work served over https and read from disk.
    func resolvedAgainst(index indexURL: URL) -> EnginePackRelease {
        guard let parsed = URL(string: url), parsed.scheme == nil,
              let resolved = URL(string: url, relativeTo: indexURL) else { return self }
        var release = self
        release.url = resolved.absoluteURL.absoluteString
        return release
    }

    /// Whether the archive this entry names can actually be opened now.
    ///
    /// A bundled index resolves its relative entries against the app bundle,
    /// where no archives ship: those entries become `file://` URLs that do not
    /// exist and must not be offered as downloads. Remote entries are trusted
    /// until the install actually fetches them.
    public var hasAvailableSource: Bool {
        guard let parsed = URL(string: url), parsed.isFileURL else { return true }
        return FileManager.default.fileExists(atPath: parsed.path)
    }
}

public struct EnginePackIndex: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    /// Keyed by `EngineID.rawValue`. Unknown keys are kept out by `loadIndex`,
    /// so a UI can iterate the dictionary without filtering.
    public var engines: [String: [EnginePackRelease]]
    public init(schemaVersion: Int = 1,
                engines: [String: [EnginePackRelease]] = [:]) {
        self.schemaVersion = schemaVersion
        self.engines = engines
    }

    /// Newest first. Sorting happens here so every caller sees the same order
    /// as `installedVersions(_:)` and never has to re-derive it.
    public func releases(for id: EngineID) -> [EnginePackRelease] {
        let releases = engines[id.rawValue] ?? []
        return releases.sorted { EngineVersionOrder.isNewer($0.version, than: $1.version) }
    }

    /// Latest entry, if the index knows this engine at all.
    public func latest(for id: EngineID) -> EnginePackRelease? {
        releases(for: id).first
    }

}

// MARK: - Errors

public enum EngineInstallError: Error, LocalizedError, Equatable {
    case indexUnavailable
    case releaseNotFound(String)
    case unsupportedArchive(String)
    case checksumMismatch(expected: String, actual: String)
    case unsafeArchiveEntry(String)
    case unsafeArchiveLink(String)
    case missingEntrypoint(String)
    case invalidManifest(String)
    case downloadFailed(String)
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .indexUnavailable:
            return "无法获取引擎包索引"
        case .releaseNotFound(let version):
            return "索引中没有该引擎版本：\(version)"
        case .unsupportedArchive(let url):
            return "不支持的归档格式：\(url)（仅支持 .tar.gz 或 .tgz）"
        case .checksumMismatch(let expected, let actual):
            return "SHA256 校验失败：期望 \(expected)，实际 \(actual)"
        case .unsafeArchiveEntry(let entry):
            return "归档中包含不安全的路径：\(entry)"
        case .unsafeArchiveLink(let link):
            return "归档中包含指向包外的链接：\(link)"
        case .missingEntrypoint(let path):
            return "安装包缺少可执行入口：\(path)"
        case .invalidManifest(let reason):
            return "安装包清单无效：\(reason)"
        case .downloadFailed(let reason):
            return "下载失败：\(reason)"
        case .commandFailed(let reason):
            return "命令执行失败：\(reason)"
        }
    }
}

// MARK: - Phase

/// What the installer is doing right now. The UI renders it verbatim, so the
/// labels are user-facing Chinese and the fraction is only meaningful while a
/// download is in flight.
public enum EngineInstallPhase: Equatable, Sendable {
    case idle
    case resolving
    case downloading(progress: Double, receivedBytes: Int, totalBytes: Int?)
    case verifying
    case unpacking
    case validating
    case activating
    case installed(version: String)
    case failed(message: String)

    public var isBusy: Bool {
        switch self {
        case .resolving, .downloading, .verifying, .unpacking, .validating, .activating:
            return true
        case .idle, .installed, .failed:
            return false
        }
    }

    public var label: String {
        switch self {
        case .idle:
            return "待安装"
        case .resolving:
            return "解析版本"
        case .downloading(let progress, _, _):
            let percent = Int((min(max(progress, 0), 1) * 100).rounded())
            return "下载中 \(percent)%"
        case .verifying:
            return "校验 SHA256"
        case .unpacking:
            return "解包"
        case .validating:
            return "校验包"
        case .activating:
            return "激活"
        case .installed:
            return "已安装"
        case .failed(let message):
            return "失败：\(message)"
        }
    }

    /// 0…1 while downloading, `nil` everywhere else so a determinate bar is not
    /// drawn for steps that have no measurable progress.
    public var fraction: Double? {
        guard case .downloading(let progress, _, _) = self else { return nil }
        return min(max(progress, 0), 1)
    }
}

// MARK: - Environment

public struct EngineInstallEnvironment: Sendable {
    /// Packs land in `<packsDirectory>/<id>/<version>`.
    public var packsDirectory: String
    /// Optional remote/local `pack-index.json`. Takes precedence over the
    /// bundled copy so a nightly index can be tested without shipping a build.
    public var indexURL: URL?
    /// Fallback index shipped inside the app bundle.
    public var bundledIndexPath: String?
    public var tarPath: String
    public var xattrPath: String

    public init(packsDirectory: String,
                indexURL: URL? = nil,
                bundledIndexPath: String? = nil,
                tarPath: String = "/usr/bin/tar",
                xattrPath: String = "/usr/bin/xattr") {
        self.packsDirectory = packsDirectory
        self.indexURL = indexURL
        self.bundledIndexPath = bundledIndexPath
        self.tarPath = tarPath
        self.xattrPath = xattrPath
    }

    public static var live: EngineInstallEnvironment {
        let environment = ProcessInfo.processInfo.environment
        return EngineInstallEnvironment(
            packsDirectory: defaultPacksDirectory(environment: environment),
            indexURL: url(from: environment["FLASHCAT_PACK_INDEX_URL"]),
            bundledIndexPath: Bundle.main.url(forResource: "pack-index", withExtension: "json")?.path
        )
    }

    static func defaultPacksDirectory(environment: [String: String]) -> String {
        if let override = environment["FLASHCAT_ENGINE_PACKS_DIR"], !override.isEmpty {
            return override
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("flashCat", isDirectory: true)
            .appendingPathComponent("packs", isDirectory: true)
            .path
    }

    private static func url(from raw: String?) -> URL? {
        guard let raw, !raw.isEmpty else { return nil }
        return URL(string: raw)
    }
}

// MARK: - Archive links

/// A `tar -tvzf` entry whose type is a link.
///
/// pack 可以带链接——Python 发行包本来就有一批同目录的软链——但目标不能出包：
/// `pack/link -> ~/.ssh/id_rsa` 能把包外文件拉进来，`validate` 再给它 `chmod 755`
/// 并启动，就成了在包外执行东西。
struct ArchiveLink: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// `l` 开头：目标相对链接自己所在的目录。
        case symbolic
        /// `h` 开头：目标相对归档根。
        case hard
    }

    var kind: Kind
    /// 归档里的条目名（解包前的位置）。
    var path: String
    var target: String
}

// MARK: - Installer

public actor EngineInstaller {
    private let settings: EngineInstallEnvironment

    public init(environment: EngineInstallEnvironment) {
        self.settings = environment
    }

    /// Read-only snapshot: mutations to the returned copy never reach the actor.
    public var environment: EngineInstallEnvironment { settings }

    // MARK: Index

    public func loadIndex() async throws -> EnginePackIndex {
        for candidate in indexCandidates() {
            guard let fetched = try? await fetch(candidate) else { continue }
            guard let decoded = try? JSONDecoder().decode(EnginePackIndex.self, from: fetched.data) else {
                throw EngineInstallError.indexUnavailable
            }
            var index = decoded
            index.engines = decoded.engines
                .filter { raw, _ in
                    guard let id = EngineID(rawValue: raw) else { return false }
                    return EngineCatalog.allIDs.contains(id)
                }
                .mapValues { releases in
                    releases.map { $0.resolvedAgainst(index: fetched.url) }
                }
            return index
        }
        throw EngineInstallError.indexUnavailable
    }

    private func indexCandidates() -> [URL] {
        var candidates: [URL] = []
        if let remote = settings.indexURL { candidates.append(remote) }
        if let bundled = settings.bundledIndexPath, !bundled.isEmpty {
            candidates.append(URL(fileURLWithPath: bundled))
        }
        return candidates
    }

    /// Returns where the index actually came from alongside its bytes: a
    /// redirect moves the index (`/latest/pack-index.json` → `/v1.4.1/…`), and
    /// the archives sit beside the copy that was served, not the one we asked for.
    private func fetch(_ url: URL) async throws -> (data: Data, url: URL) {
        if url.isFileURL {
            return (try Data(contentsOf: url), url)
        }
        // 索引决定了「下哪个包、校验和是多少」，走明文 http 等于让对方直接
        // 换掉权重。远程索引只接受 https；回环地址留给测试和本机镜像。
        guard url.scheme?.lowercased() == "https" || Self.isLoopback(url) else {
            throw EngineInstallError.indexUnavailable
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw EngineInstallError.downloadFailed("服务器返回 HTTP \(http.statusCode)")
        }
        return (data, response.url ?? url)
    }

    static func isLoopback(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "http", let host = url.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    // MARK: Paths

    private var packsRoot: URL {
        URL(fileURLWithPath: settings.packsDirectory, isDirectory: true)
    }

    private var downloadsRoot: URL {
        packsRoot.appendingPathComponent(".downloads", isDirectory: true)
    }

    private var stagingRoot: URL {
        packsRoot.appendingPathComponent(".staging", isDirectory: true)
    }

    private var trashRoot: URL {
        packsRoot.appendingPathComponent(".trash", isDirectory: true)
    }

    private func engineRoot(_ id: EngineID) -> URL {
        packsRoot.appendingPathComponent(id.rawValue, isDirectory: true)
    }

    public func installedRoot(_ id: EngineID, version: String) -> String {
        engineRoot(id).appendingPathComponent(version, isDirectory: true).path
    }

    /// Directory names are the versions; anything that is not a directory is
    /// ignored so a stray `.DS_Store` cannot show up as an installed pack.
    public func installedVersions(_ id: EngineID) -> [String] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: engineRoot(id),
                                                       includingPropertiesForKeys: [.isDirectoryKey],
                                                       options: [.skipsHiddenFiles]) else {
            return []
        }
        let versions = entries.compactMap { url -> String? in
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return isDirectory ? url.lastPathComponent : nil
        }
        return versions.sorted { EngineVersionOrder.isNewer($0, than: $1) }
    }

    // MARK: Install

    public func install(_ release: EnginePackRelease,
                        for id: EngineID,
                        progress: @Sendable (EngineInstallPhase) -> Void) async throws -> EngineInstallation {
        progress(.resolving)

        let fm = FileManager.default
        let downloads = downloadsRoot
        let staging = stagingRoot
        let partial = downloads.appendingPathComponent("\(id.rawValue)-\(release.version).partial")
        let archive = downloads.appendingPathComponent("\(id.rawValue)-\(release.version).tar.gz")
        var stagingDirectory: URL?

        do {
            guard let url = URL(string: release.url) else {
                throw EngineInstallError.downloadFailed("无效的下载地址：\(release.url)")
            }
            // A relative address would "succeed" here and fail inside URLSession
            // with no hint of which index produced it.
            guard url.scheme != nil else {
                throw EngineInstallError.downloadFailed("下载地址不是绝对地址：\(release.url)")
            }
            // Checked before touching the network so a typo in the index fails
            // in milliseconds instead of after a download.
            let name = url.lastPathComponent.lowercased()
            guard name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") else {
                throw EngineInstallError.unsupportedArchive(release.url)
            }

            try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            try? fm.removeItem(at: partial)
            try? fm.removeItem(at: archive)

            try await download(url, to: partial, progress: progress)

            progress(.verifying)
            let actual = try Self.sha256(of: partial)
            let expected = release.sha256.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard actual.lowercased() == expected else {
                throw EngineInstallError.checksumMismatch(expected: expected, actual: actual)
            }
            try fm.moveItem(at: partial, to: archive)

            progress(.unpacking)
            let entries = try listArchive(archive)
            try Self.validate(entries: entries)
            let strip = Self.stripComponents(for: entries)
            let links = try Self.links(inListing: try listArchiveDetails(archive), names: entries)
            try Self.validate(links: links, stripComponents: strip)
            let unpacked = staging.appendingPathComponent("\(id.rawValue)-\(release.version)-\(UUID().uuidString)")
            try fm.createDirectory(at: unpacked, withIntermediateDirectories: true)
            stagingDirectory = unpacked
            try extract(archive, into: unpacked, stripComponents: strip)

            progress(.validating)
            try Self.validateExtractedLinks(in: unpacked)
            let installation = try validate(unpacked, expecting: id, version: release.version)

            progress(.activating)
            // Quarantine removal is best effort: a pack without the attribute
            // makes xattr exit non-zero, which must not fail the install.
            _ = try? run(settings.xattrPath, ["-dr", "com.apple.quarantine", unpacked.path])
            let destination = try activate(unpacked, for: id, version: release.version)
            stagingDirectory = nil

            try? fm.removeItem(at: archive)
            pruneIfEmpty(downloads)
            pruneIfEmpty(staging)

            let installed = EngineInstallation(id: id,
                                               manifest: installation.manifest,
                                               root: destination)
            progress(.installed(version: release.version))
            return installed
        } catch {
            // Only what this attempt created is removed: an already installed
            // older version stays where it is.
            if let stagingDirectory { try? fm.removeItem(at: stagingDirectory) }
            try? fm.removeItem(at: partial)
            try? fm.removeItem(at: archive)
            pruneIfEmpty(downloads)
            pruneIfEmpty(staging)
            let message = (error as? EngineInstallError)?.errorDescription ?? error.localizedDescription
            progress(.failed(message: message))
            throw error
        }
    }

    // MARK: Uninstall

    /// Moves a version into `.trash` and removes it. Returns false when there was
    /// nothing to remove: packs found in the app bundle or a checkout are not
    /// ours to delete, so callers can report that instead of silently doing
    /// nothing.
    @discardableResult
    public func uninstall(_ id: EngineID, version: String) throws -> Bool {
        let fm = FileManager.default
        let target = engineRoot(id).appendingPathComponent(version, isDirectory: true)
        guard fm.fileExists(atPath: target.path) else { return false }
        let trash = trashRoot
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        let doomed = trash.appendingPathComponent("\(id.rawValue)-\(version)-\(UUID().uuidString)",
                                                  isDirectory: true)
        try fm.moveItem(at: target, to: doomed)
        try? fm.removeItem(at: doomed)
        pruneIfEmpty(trash)
        return true
    }

    // MARK: Activation

    private func activate(_ unpacked: URL, for id: EngineID, version: String) throws -> URL {
        let fm = FileManager.default
        let root = engineRoot(id)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent(version, isDirectory: true)

        if fm.fileExists(atPath: destination.path) {
            let trash = trashRoot
            try fm.createDirectory(at: trash, withIntermediateDirectories: true)
            let doomed = trash.appendingPathComponent("\(id.rawValue)-\(version)-\(UUID().uuidString)",
                                                      isDirectory: true)
            try fm.moveItem(at: destination, to: doomed)
            do {
                try fm.moveItem(at: unpacked, to: destination)
            } catch {
                // 新版本没就位就把旧的搬回去：否则失败一次就变成「引擎没了」。
                do { try fm.moveItem(at: doomed, to: destination) }
                catch {
                    NSLog("flashCat: 回滚引擎 %@ 失败，旧版本仍在 %@", id.rawValue, doomed.path)
                }
                throw error
            }
            do { try fm.removeItem(at: doomed) }
            catch { NSLog("flashCat: 清理旧版本 %@ 失败：%@", doomed.path, error.localizedDescription) }
            pruneIfEmpty(trash)
        } else {
            try fm.moveItem(at: unpacked, to: destination)
        }
        return destination
    }

    // MARK: Validation

    private func validate(_ root: URL, expecting id: EngineID, version: String) throws -> EngineInstallation {
        guard let installation = EngineInstallation.load(root: root) else {
            throw EngineInstallError.invalidManifest("无法解码 manifest.json")
        }
        guard installation.manifest.id == id else {
            throw EngineInstallError.invalidManifest(
                "清单中的引擎标识为 \(installation.manifest.id.rawValue)，与期望的 \(id.rawValue) 不一致")
        }

        // 目录名来自 release.version，启动却读 manifest.version：两者不一致时
        // 卸载/清理会按清单去删另一个目录，删错或者删不掉。
        guard installation.manifest.version == version else {
            throw EngineInstallError.invalidManifest(
                "清单版本 \(installation.manifest.version) 与发布版本 \(version) 不一致")
        }

        let fm = FileManager.default
        let relative = installation.manifest.entrypoint
        guard !relative.hasPrefix("/"), !relative.hasPrefix("~"),
              !Self.pathComponents(relative).contains("..") else {
            throw EngineInstallError.unsafeArchiveEntry(relative)
        }
        let entrypoint = root.appendingPathComponent(relative)
        // 软链解析后仍必须落在 pack 内；否则 chmod 与启动都会打到包外。
        let resolvedRoot = root.resolvingSymlinksInPath().path
        let resolvedEntry = entrypoint.resolvingSymlinksInPath().path
        guard resolvedEntry == resolvedRoot || resolvedEntry.hasPrefix(resolvedRoot + "/") else {
            throw EngineInstallError.unsafeArchiveEntry(relative)
        }
        guard fm.fileExists(atPath: entrypoint.path) else {
            throw EngineInstallError.missingEntrypoint(installation.manifest.entrypoint)
        }
        if !fm.isExecutableFile(atPath: entrypoint.path) {
            // Archives built on a machine that lost the mode bits still hold a
            // usable interpreter, so repair the bit once before giving up.
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: entrypoint.path)
            guard fm.isExecutableFile(atPath: entrypoint.path) else {
                throw EngineInstallError.missingEntrypoint(installation.manifest.entrypoint)
            }
        }
        return installation
    }

    // MARK: Archive

    /// Every entry is inspected before tar is allowed to write anything:
    /// absolute paths and `..` components would escape the staging directory.
    private func listArchive(_ archive: URL) throws -> [String] {
        let result = try run(settings.tarPath, ["-tzf", archive.path])
        guard result.status == 0 else {
            throw EngineInstallError.commandFailed("tar 无法列出归档内容：\(Self.text(result.stderr))")
        }
        return Self.text(result.stdout)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    /// `tar -tvzf` 的原始行。软链与硬链只有在带类型的列表里才看得出：`tar -tzf`
    /// 只给名字，而这两种条目的目标可能指向包外。
    private func listArchiveDetails(_ archive: URL) throws -> [String] {
        let result = try run(settings.tarPath, ["-tvzf", archive.path])
        guard result.status == 0 else {
            throw EngineInstallError.commandFailed("tar 无法列出归档内容：\(Self.text(result.stderr))")
        }
        return Self.text(result.stdout)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    /// A tar entry that is absolute or climbs out with `..` would land outside
    /// the staging directory, so the whole archive is rejected.
    static func validate(entries: [String]) throws {
        for entry in entries {
            if entry.hasPrefix("/") || entry.hasPrefix("~/") {
                throw EngineInstallError.unsafeArchiveEntry(entry)
            }
            if pathComponents(entry).contains("..") {
                throw EngineInstallError.unsafeArchiveEntry(entry)
            }
        }
    }

    /// 从带类型的列表里挑出链接。看不懂的一行按失败处理：那可能正是被塞进来的
    /// 一条链接。
    static func links(inListing listing: [String], names: [String]) throws -> [ArchiveLink] {
        let known = names.sorted { $0.count > $1.count }
        var links: [ArchiveLink] = []
        for line in listing {
            guard let first = line.first, first == "l" || first == "h" else { continue }
            let kind: ArchiveLink.Kind = first == "l" ? .symbolic : .hard
            let separator = kind == .symbolic ? " -> " : " link to "
            guard let (path, target) = splitName(line, at: separator, known: known),
                  !target.isEmpty else {
                throw EngineInstallError.unsafeArchiveLink(line)
            }
            links.append(ArchiveLink(kind: kind, path: path, target: target))
        }
        return links
    }

    /// 切出「条目名 + 目标」。名字里可以有空格，甚至可以带 ` -> ` 这串字面量，
    /// 所以既不按列数、也不按第一个分隔符切：在归档的名字表里找正好停在这里的
    /// 最长后缀——tar 打印的一定是归档里的原名。GNU tar 与 bsdtar 的列数不同，
    /// 这样也不受影响。
    private static func splitName(_ line: String,
                                  at separator: String,
                                  known: [String]) -> (path: String, target: String)? {
        var start = line.startIndex
        while let range = line.range(of: separator, range: start..<line.endIndex) {
            let head = line[..<range.lowerBound]
            if let name = known.first(where: { nameStops(head: head, name: $0) }) {
                return (name, String(line[range.upperBound...]))
            }
            start = range.upperBound
        }
        return nil
    }

    /// `head` 是「元数据 + 名字」，元数据以空白收尾；名字里也可能有空格，所以
    /// 只要求名字前面是空白，不假设有多少列。
    private static func nameStops(head: Substring, name: String) -> Bool {
        guard head.hasSuffix(name) else { return false }
        let before = head.dropLast(name.count)
        return before.isEmpty || before.last == " " || before.last == "\t"
    }

    /// 链接本身可以留，它去哪才是问题。软链的目标相对链接自己所在的目录、硬链
    /// 的目标相对归档根；两者都按 `--strip-components` 之后的坐标解析，任何一步
    /// 越出 pack 根都整包拒绝。
    static func validate(links: [ArchiveLink], stripComponents: Int) throws {
        for link in links where !staysInsideRoot(link, stripComponents: stripComponents) {
            let arrow = link.kind == .symbolic ? "->" : "link to"
            throw EngineInstallError.unsafeArchiveLink("\(link.path) \(arrow) \(link.target)")
        }
    }

    /// 解析链接目标，看它是否还留在解包目录里：绝对路径与 `~` 直接拒绝，`..`
    /// 从根往上爬也拒绝。
    static func staysInsideRoot(_ link: ArchiveLink, stripComponents: Int) -> Bool {
        let target = link.target
        guard !target.hasPrefix("/"), !target.hasPrefix("~") else { return false }

        // 软链从链接所在的目录出发，硬链从归档根出发。
        var stack: [String]
        switch link.kind {
        case .symbolic:
            let components = strippedComponents(link.path, stripComponents: stripComponents)
            guard !components.isEmpty else { return false }
            stack = Array(components.dropLast())
        case .hard:
            stack = []
        }

        for component in pathComponents(target) {
            if component == ".." {
                guard !stack.isEmpty else { return false }
                stack.removeLast()
            } else {
                stack.append(component)
            }
        }

        // 硬链要指向一个真条目：`--strip-components` 之后什么都不剩也就不算。
        if link.kind == .hard {
            let strip = min(max(stripComponents, 0), stack.count)
            return !stack.dropFirst(strip).isEmpty
        }
        return true
    }

    /// 条目在解包后的位置：tar 会先去掉最前面的 N 段。
    private static func strippedComponents(_ entry: String, stripComponents: Int) -> [String] {
        var components = pathComponents(entry)
        components.removeFirst(min(max(stripComponents, 0), components.count))
        return components
    }

    /// 解包后的兜底审计。列表解析依赖 tar 的文本格式，这里直接看落盘的每一个
    /// 软链，层级按真实目录算，且不跟随链接（链接目录不再进去逐层展开）：链套链
    /// 时，越界的那一条自己会被抓到。硬链由上面那轮解析负责——tar 造不出指向
    /// 包外的硬链。
    static func validateExtractedLinks(in root: URL) throws {
        try auditLinks(inDirectory: root.path, relative: "", fm: FileManager.default)
    }

    private static func auditLinks(inDirectory path: String,
                                   relative: String,
                                   fm: FileManager) throws {
        let names: [String]
        do {
            names = try fm.contentsOfDirectory(atPath: path)
        } catch {
            throw EngineInstallError.commandFailed("无法检查归档中的链接：\(error.localizedDescription)")
        }
        for name in names {
            let childPath = path + "/" + name
            let childRelative = relative.isEmpty ? name : relative + "/" + name
            if let target = try? fm.destinationOfSymbolicLink(atPath: childPath) {
                let link = ArchiveLink(kind: .symbolic, path: childRelative, target: target)
                guard staysInsideRoot(link, stripComponents: 0) else {
                    throw EngineInstallError.unsafeArchiveLink("\(childRelative) -> \(target)")
                }
                continue
            }
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: childPath, isDirectory: &isDirectory), isDirectory.boolValue {
                try auditLinks(inDirectory: childPath, relative: childRelative, fm: fm)
            }
        }
    }

    /// Whether the archive wraps everything in one top-level directory. That
    /// decides `--strip-components 1`; a flat archive must not get it or the
    /// manifest would be stripped away with the folder name.
    static func stripComponents(for entries: [String]) -> Int {
        var head: String?
        for entry in entries {
            guard let first = pathComponents(entry).first else { continue }
            if let head {
                if head != first { return 0 }
            } else {
                head = first
            }
        }
        return head == nil ? 0 : 1
    }

    /// Splits an archive entry into meaningful components, dropping the `./`
    /// prefix tar sometimes writes.
    static func pathComponents(_ entry: String) -> [String] {
        entry.split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0 != "." }
    }

    private func extract(_ archive: URL, into destination: URL, stripComponents: Int) throws {
        var arguments = ["-xzf", archive.path, "-C", destination.path, "--no-same-owner"]
        if stripComponents == 1 {
            arguments.append("--strip-components")
            arguments.append("1")
        }
        let result = try run(settings.tarPath, arguments)
        guard result.status == 0 else {
            throw EngineInstallError.commandFailed("tar 解包失败：\(Self.text(result.stderr))")
        }
    }

    // MARK: Download

    private func download(_ url: URL,
                          to destination: URL,
                          progress: @Sendable (EngineInstallPhase) -> Void) async throws {
        if url.isFileURL {
            try downloadLocal(url, to: destination, progress: progress)
        } else {
            try await downloadRemote(url, to: destination, progress: progress)
        }
    }

    private func downloadLocal(_ url: URL,
                               to destination: URL,
                               progress: @Sendable (EngineInstallPhase) -> Void) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            throw EngineInstallError.downloadFailed("找不到下载源文件：\(url.path)")
        }
        try? fm.removeItem(at: destination)
        do {
            try fm.copyItem(at: url, to: destination)
        } catch {
            throw EngineInstallError.downloadFailed(error.localizedDescription)
        }
        var size: Int?
        if let attributes = try? fm.attributesOfItem(atPath: destination.path),
           let bytes = attributes[.size] as? Int {
            size = bytes
        }
        progress(.downloading(progress: 1.0, receivedBytes: size ?? 0, totalBytes: size))
    }

    /// Streams over HTTPS, writing bytes as they arrive so a 600 MB pack never
    /// sits in memory. `URLSession`'s delegate runs off-actor; the progress
    /// closure is therefore invoked from this actor after the hop back.
    private func downloadRemote(_ url: URL,
                                to destination: URL,
                                progress: @Sendable (EngineInstallPhase) -> Void) async throws {
        let fm = FileManager.default
        try? fm.removeItem(at: destination)

        let stream = AsyncThrowingStream<DownloadEvent, Error> { continuation in
            let delegate = RemoteDownloadDelegate(destination: destination, continuation: continuation)
            delegate.start(url)
        }

        var lastBytes: Int64 = 0
        var lastEmit = Date.distantPast
        do {
            for try await event in stream {
                switch event {
                case .progress(let received, let expected):
                    let now = Date()
                    guard received - lastBytes >= 262_144 || now.timeIntervalSince(lastEmit) >= 0.2 else {
                        continue
                    }
                    lastBytes = received
                    lastEmit = now
                    progress(Self.downloadPhase(received: received, expected: expected, fraction: nil))
                case .finished(let received, let expected):
                    progress(Self.downloadPhase(received: received, expected: expected, fraction: 1.0))
                }
            }
        } catch let error as EngineInstallError {
            throw error
        } catch {
            throw EngineInstallError.downloadFailed(error.localizedDescription)
        }
    }

    private static func downloadPhase(received: Int64, expected: Int64, fraction: Double?) -> EngineInstallPhase {
        let total = expected > 0 ? Int(expected) : nil
        let value: Double
        if let fraction {
            value = fraction
        } else if expected > 0 {
            value = min(max(Double(received) / Double(expected), 0), 1)
        } else {
            value = 0
        }
        return .downloading(progress: value, receivedBytes: Int(received), totalBytes: total)
    }

    // MARK: Hashing

    /// 1 MB chunks keep memory flat regardless of pack size.
    static func sha256(of url: URL) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw EngineInstallError.downloadFailed("无法读取文件：\(url.lastPathComponent)")
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Processes

    struct ProcessOutcome {
        var status: Int32
        var stdout: Data
        var stderr: Data
    }

    /// `Process` with an argument array — never a shell string, so a file name
    /// with a space or quote cannot turn into a second command.
    private func run(_ executable: String, _ arguments: [String]) throws -> ProcessOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            throw EngineInstallError.commandFailed("无法启动 \(executable)：\(error.localizedDescription)")
        }

        // Both pipes are drained concurrently: a tar listing can exceed the
        // pipe buffer, and a blocked read would deadlock the child.
        let collector = PipeCollector()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            collector.store(0, outPipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            collector.store(1, errPipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        group.wait()
        process.waitUntilExit()

        return ProcessOutcome(status: process.terminationStatus,
                              stdout: collector.data(0),
                              stderr: collector.data(1))
    }

    private static func text(_ data: Data) -> String {
        let value = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "无输出" : value
    }

    // MARK: Housekeeping

    private func pruneIfEmpty(_ directory: URL) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        if items.isEmpty { try? fm.removeItem(at: directory) }
    }
}

// MARK: - Download plumbing

private enum DownloadEvent: Sendable {
    case progress(received: Int64, expected: Int64)
    case finished(received: Int64, expected: Int64)
}

/// Writes the response straight to disk and reports byte counts back to the
/// actor through an `AsyncThrowingStream`.
private final class RemoteDownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let destination: URL
    private let continuation: AsyncThrowingStream<DownloadEvent, Error>.Continuation
    private let lock = NSLock()
    private var handle: FileHandle?
    private var session: URLSession?
    private var received: Int64 = 0
    private var expected: Int64 = -1
    private var isFinished = false

    init(destination: URL, continuation: AsyncThrowingStream<DownloadEvent, Error>.Continuation) {
        self.destination = destination
        self.continuation = continuation
        super.init()
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        handle = try? FileHandle(forWritingTo: destination)
    }

    func start(_ url: URL) {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        guard handle != nil else {
            finish(error: EngineInstallError.downloadFailed("无法创建下载文件：\(destination.lastPathComponent)"))
            return
        }
        session.dataTask(with: url).resume()
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        expected = response.expectedContentLength
        lock.unlock()

        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            completionHandler(.cancel)
            finish(error: EngineInstallError.downloadFailed("服务器返回 HTTP \(http.statusCode)"))
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        try? handle?.write(contentsOf: data)
        received += Int64(data.count)
        let receivedSnapshot = received
        let expectedSnapshot = expected
        lock.unlock()
        continuation.yield(.progress(received: receivedSnapshot, expected: expectedSnapshot))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(error: EngineInstallError.downloadFailed(error.localizedDescription))
        } else {
            lock.lock()
            let receivedSnapshot = received
            let expectedSnapshot = expected
            lock.unlock()
            finish(received: receivedSnapshot, expected: expectedSnapshot)
        }
    }

    private func finish(received: Int64, expected: Int64) {
        lock.lock()
        guard !isFinished else { lock.unlock(); return }
        isFinished = true
        let handle = self.handle
        self.handle = nil
        let session = self.session
        self.session = nil
        lock.unlock()

        try? handle?.close()
        session?.finishTasksAndInvalidate()
        continuation.yield(.finished(received: received, expected: expected))
        continuation.finish()
    }

    private func finish(error: Error) {
        lock.lock()
        guard !isFinished else { lock.unlock(); return }
        isFinished = true
        let handle = self.handle
        self.handle = nil
        let session = self.session
        self.session = nil
        lock.unlock()

        try? handle?.close()
        session?.invalidateAndCancel()
        continuation.finish(throwing: error)
    }
}

/// Collects the two pipe reads without touching a mutable capture from two
/// queues at once.
private final class PipeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int: Data] = [:]

    func store(_ index: Int, _ data: Data) {
        lock.lock()
        storage[index] = data
        lock.unlock()
    }

    func data(_ index: Int) -> Data {
        lock.lock()
        defer { lock.unlock() }
        return storage[index] ?? Data()
    }
}
