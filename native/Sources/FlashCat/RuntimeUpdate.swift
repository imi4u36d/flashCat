import Foundation

enum UpdatePhase: String {
    case idle = "未检查"
    case checking = "检查中"
    case upToDate = "已是最新"
    case available = "有更新"
    case preparing = "准备中"
    case downloading = "下载中"
    case verifying = "校验中"
    case installing = "安装中"
    case installed = "已安装"
    case failed = "失败"
}

struct UpdateState {
    var phase: UpdatePhase = .idle
    var version: String = ""
    var availableVersion: String?
    var progress: Double?
    var message: String?

    var busy: Bool {
        switch phase {
        case .checking, .preparing, .downloading, .verifying, .installing: return true
        default: return false
        }
    }
}

/// Checks github.com/incoai/splash releases and installs a newer runtime into
/// ~/Library/Application Support/flashCat/runtimes/<version>.
final class RuntimeUpdater: NSObject, URLSessionDelegate, URLSessionTaskDelegate, URLSessionDataDelegate {
    private var state = UpdateState()
    private var assetURL: String?
    private var digest: String?
    private var checksumURL: String?
    private var handle: FileHandle?
    private var received = 0
    private var total = 0
    private var httpStatus = 0
    private var completion: CheckedContinuation<Void, Never>?

    var currentVersion: String
    var onStateChanged: (UpdateState) -> Void = { _ in }
    var onInstalled: (EngineRuntime) -> Void = { _ in }
    var onLog: (String) -> Void = { _ in }

    init(currentVersion: String) {
        self.currentVersion = currentVersion
        state.version = currentVersion
    }

    var currentState: UpdateState { state }

    func check() async {
        if state.busy { return }
        state = UpdateState(phase: .checking, version: currentVersion)
        onLog("正在检查 GitHub 上的 splash 运行时更新…")
        onStateChanged(state)

        var request = URLRequest(url: URL(string: "https://api.github.com/repos/incoai/splash/releases/latest")!)
        request.timeoutInterval = 25
        request.setValue("flashCat", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status < 200 || status >= 300 { throw failure("GitHub 返回 HTTP \(status)") }
            guard let release = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let assets = release["assets"] as? [[String: Any]] else {
                throw failure("无法解析发布信息")
            }
            let tag = release["tag_name"] as? String ?? ""
            let expected = "splash-\(tag)-arm64-macos26.tar.gz"
            var asset: [String: Any]?
            for item in assets where item["name"] as? String == expected { asset = item; break }
            if asset == nil {
                throw failure("版本 \(tag) 没有 macOS 运行时归档")
            }
            assetURL = asset?["browser_download_url"] as? String
            if let value = asset?["digest"] as? String {
                let lowered = value.lowercased()
                digest = lowered.hasPrefix("sha256:") ? String(lowered.dropFirst(7)) : lowered
            }
            checksumURL = nil
            for item in assets {
                let name = item["name"] as? String ?? ""
                if name == "\(expected).sha256" || name == "SHA256SUMS" {
                    checksumURL = item["browser_download_url"] as? String
                    break
                }
            }
            let newer = isNewer(tag, currentVersion)
            onLog(newer ? "发现新运行时 splash \(tag)（当前 \(currentVersion)）"
                        : "运行时已是最新：splash \(currentVersion)")
            state = UpdateState(phase: newer ? .available : .upToDate,
                                version: currentVersion, availableVersion: tag)
        } catch {
            state = UpdateState(phase: .failed, version: currentVersion,
                                message: "检查更新失败：\(error.localizedDescription)")
        }
        onStateChanged(state)
    }

    func install() async {
        if state.busy { return }
        if state.phase != .available || assetURL == nil || state.availableVersion == nil {
            await check()
            return
        }
        let version = state.availableVersion!
        Paths.ensureDirectory(Paths.runtimesDirectory)
        let archive = Paths.runtimesDirectory + "/.download-\(Int(Date().timeIntervalSince1970 * 1000)).tar.gz"

        do {
            state = UpdateState(phase: .downloading, version: currentVersion, availableVersion: version, progress: 0)
            onLog("开始下载 splash \(version) 运行时…")
            onStateChanged(state)

            try await fetchArchive(from: URL(string: assetURL!)!, to: archive)

            state = UpdateState(phase: .verifying, version: currentVersion, availableVersion: version)
            onStateChanged(state)

            if (digest == nil || digest!.count != 64), let url = checksumURL {
                var checksumRequest = URLRequest(url: URL(string: url)!)
                checksumRequest.setValue("flashCat", forHTTPHeaderField: "User-Agent")
                if let (data, _) = try? await URLSession.shared.data(for: checksumRequest) {
                    let text = String(data: data, encoding: .utf8) ?? ""
                    if let match = TextPattern.firstMatch("[0-9a-fA-F]{64}", text) {
                        digest = match[0]
                    }
                }
            }
            if digest == nil || digest!.count != 64 {
                throw failure("发布页没有提供 SHA-256 校验值")
            }
            let actual = sha256(of: archive)
            if actual?.lowercased() != digest!.lowercased() {
                throw failure("SHA-256 校验失败（下载文件与发布页校验值不一致）")
            }

            state = UpdateState(phase: .installing, version: currentVersion, availableVersion: version)
            onStateChanged(state)

            let destination = Paths.runtimesDirectory + "/" + version
            try? FileManager.default.removeItem(atPath: destination)
            Paths.ensureDirectory(destination)

            let tar = Process()
            tar.launchPath = "/usr/bin/tar"
            tar.arguments = ["-xzf", archive, "--strip-components=1", "-C", destination]
            try tar.run()
            tar.waitUntilExit()
            if tar.terminationStatus != 0 {
                throw failure("解包失败（tar 退出码 \(tar.terminationStatus)）", code: Int(tar.terminationStatus))
            }

            let runtime = EngineRuntime(root: destination)
            if !runtime.exists {
                throw failure("更新包缺少运行时文件")
            }
            if runtime.version != version {
                throw failure("运行时版本不匹配：\(runtime.version)")
            }
            EngineRuntime.selectRuntime(version)
            currentVersion = version
            state = UpdateState(phase: .installed, version: version, availableVersion: version)
            onInstalled(runtime)
        } catch {
            state = UpdateState(phase: .failed, version: currentVersion, availableVersion: version,
                                message: "安装更新失败：\(error.localizedDescription)")
            onLog("安装运行时更新失败：\(error.localizedDescription)")
        }
        try? FileManager.default.removeItem(atPath: archive)
        onStateChanged(state)
    }

    /// Download the release archive, retrying once: a dropped connection while
    /// fetching a 75 MB asset is the usual way an update fails, and a second
    /// attempt costs seconds where a failed one costs the reader a retry.
    private func fetchArchive(from url: URL, to archive: String) async throws {
        var lastError: Error?
        for attempt in 1...2 {
            do {
                try await download(url, to: archive)
                return
            } catch {
                lastError = error
                if attempt == 1 {
                    onLog("下载中断（\(error.localizedDescription)），正在重试…")
                    try? FileManager.default.removeItem(atPath: archive)
                }
            }
        }
        throw lastError ?? failure("下载失败")
    }

    private func download(_ url: URL, to archive: String) async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = 300
        request.setValue("flashCat", forHTTPHeaderField: "User-Agent")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        received = 0
        total = 0
        httpStatus = 0
        try? Data().write(to: URL(fileURLWithPath: archive))
        guard let handle = FileHandle(forWritingAtPath: archive) else {
            throw failure("无法写入下载文件：\(archive)")
        }
        self.handle = handle
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 900
        configuration.waitsForConnectivity = true
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let task = session.dataTask(with: request)
        await withCheckedContinuation { continuation in
            completion = continuation
            task.resume()
        }
        completion = nil
        session.finishTasksAndInvalidate()
        handle.closeFile()
        self.handle = nil
        if let error = task.error {
            throw failure("下载失败：\(error.localizedDescription)")
        }
        if httpStatus >= 400 {
            throw failure("下载失败：GitHub 返回 HTTP \(httpStatus)")
        }
        if total > 0 && received != total {
            throw failure("下载不完整：收到 \(received) / \(total) 字节")
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        total = Int(response.expectedContentLength)
        httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        handle?.write(data)
        received += data.count
        if total > 0 {
            state = UpdateState(phase: .downloading, version: currentVersion,
                                availableVersion: state.availableVersion,
                                progress: Double(received) / Double(total))
            onStateChanged(state)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        completion?.resume()
        completion = nil
    }

    /// NSError with a localized description: `userInfo["message"]` is not what
    /// `localizedDescription` reads, so failures used to surface only as
    /// "未能完成操作。（flashCat错误0。）".
    private func failure(_ message: String, code: Int = 0) -> NSError {
        NSError(domain: "flashCat", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func isNewer(_ candidate: String, _ current: String) -> Bool {
        func parse(_ value: String) -> [Int]? {
            let lowered = value.hasPrefix("v") ? String(value.dropFirst()) : value
            let clean = lowered.split(separator: "-").first ?? ""
            let parts = clean.split(separator: ".").map { Int($0) }
            return parts.isEmpty || parts.contains(nil) ? nil : parts.compactMap { $0 }
        }
        guard let left = parse(candidate), let right = parse(current) else {
            return candidate != current
        }
        let length = max(left.count, right.count)
        for index in 0..<length {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a > b }
        }
        return false
    }
}
