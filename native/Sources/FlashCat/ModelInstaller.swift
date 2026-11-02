import Foundation
import FlashCatKit

/// Everything the model page needs to install weights for one engine.
///
/// Two shapes exist, and both fetch through the huggingface_hub that ships
/// inside the engine packs — no curl, no second downloader:
///
/// * oMLX and MTPLX read a folder of weights directly, so flashCat runs a small
///   `hf_snapshot.py` that puts the snapshot in the engine's own model folder.
///   That folder is watched to turn bytes on disk into a percentage.
/// * Splash serves a prepared assembly, and its installer is what selects one
///   GGUF quant out of a repository that carries a dozen, so flashCat asks it
///   to prepare the model. It downloads through the same huggingface_hub and
///   prints its own percentage.
enum ModelInstaller {
    enum Failure: Error {
        case message(String)

        var message: String {
            switch self {
            case .message(let text): return text
            }
        }
    }

    struct Plan {
        let engine: EngineID
        let model: String
        let executable: String
        let arguments: [String]
        let workingDirectory: String
        let environment: [String: String]
        /// Folder whose growth tracks the transfer, or nil when the engine
        /// reports progress itself.
        let watchDirectory: String?
        /// Where the weights end up, for the confirmation prompt.
        let destination: String
    }

    // MARK: Destination

    /// Weight folders are flat: `owner--repo` is the id every engine serves, and
    /// the same shape a download lands in.
    static func folderName(for repo: String) -> String {
        let flat = repo.replacingOccurrences(of: "/", with: "--")
        return flat.replacingOccurrences(of: ":", with: "-")
    }

    static func destination(engine: EngineID, repo: String) -> String {
        EnginePaths.modelsDirectory(engine) + "/" + folderName(for: repo)
    }

    /// 公共目录的落地路径。一份权重由哪些引擎共享，记在 `ModelSharing` 的
    /// 授权表里，下载器只管把快照放进去。
    static func sharedDestination(repo: String) -> String {
        ModelSharing.path(for: repo)
    }

    // MARK: Plan

    static func plan(engine: EngineID,
                     model: String,
                     draftRepository: String?,
                     runtime: EngineRuntime?,
                     cache: String) throws -> Plan {
        switch engine {
        case .splash:
            return try splashPlan(model: model,
                                  draftRepository: draftRepository,
                                  runtime: runtime,
                                  cache: cache)
        case .omlx, .mtplx:
            return try snapshotPlan(engine: engine, model: model, cache: cache)
        }
    }

    private static func splashPlan(model: String,
                                   draftRepository: String?,
                                   runtime: EngineRuntime?,
                                   cache: String) throws -> Plan {
        guard let runtime, runtime.exists else {
            throw Failure.message("还没有安装 Splash 引擎，无法下载模型")
        }
        let script = runtime.root + "/install/models.py"
        guard Paths.fileExists(script) else {
            throw Failure.message("Splash 引擎缺少 install/models.py")
        }
        var arguments = ["-u", script,
                         "--models", Paths.modelsDirectory,
                         "--model", model]
        if let draftRepository {
            arguments += ["--draft-model", draftRepository]
        }
        arguments.append("prepare")
        return Plan(engine: .splash,
                    model: model,
                    executable: runtime.pythonPath,
                    arguments: arguments,
                    workingDirectory: runtime.root,
                    environment: environment(pythonRoot: runtime.root, cache: cache),
                    watchDirectory: nil,
                    destination: Paths.modelsDirectory)
    }

    /// 任取一个 Hub 仓库下到公共目录。下载器仍是引擎包里那个
    /// `huggingface_hub`，跟落盘位置无关：哪个 pack 装了就用哪个，都没有才
    /// 回落到 Splash 的运行时。
    static func sharedPlan(repo: String, engines: [EngineID],
                           runtime: EngineRuntime?, cache: String) throws -> Plan {
        var candidates = engines.filter { $0 != .splash }
        candidates += [EngineID.omlx, .mtplx, .splash]
        var python: String?
        var root: String?
        for id in candidates {
            if id == .splash {
                guard let runtime, runtime.exists else { continue }
                python = runtime.pythonPath
                root = runtime.root
            } else {
                guard let installation = EngineInstallations.newest(id, version: nil),
                      Paths.fileExists(installation.entrypoint.path) else { continue }
                python = installation.entrypoint.path
                root = installation.root.path
            }
            break
        }
        guard let python, let root else {
            throw Failure.message("下载器来自引擎包：先安装 Splash、oMLX、MTPLX 中的任意一个")
        }
        let script = try scriptPath()
        let name = repo.split(separator: ":", maxSplits: 1).first.map(String.init) ?? repo
        let destination = sharedDestination(repo: name)
        var arguments = [script, name, destination]
        let trimmed = cache.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { arguments += ["--cache", trimmed] }
        return Plan(engine: engines.first ?? .omlx,
                    model: name,
                    executable: python,
                    arguments: arguments,
                    workingDirectory: root,
                    environment: environment(pythonRoot: root, cache: cache),
                    watchDirectory: destination,
                    destination: destination)
    }

    private static func snapshotPlan(engine: EngineID, model: String, cache: String) throws -> Plan {
        guard let installation = EngineInstallations.newest(engine, version: nil) else {
            throw Failure.message("还没有安装 \(engine.displayName) 引擎，无法下载模型")
        }
        let python = installation.entrypoint.path
        guard Paths.fileExists(python) else {
            throw Failure.message("\(engine.displayName) 引擎缺少内置 Python")
        }
        let script = try scriptPath()
        let repo = model.split(separator: ":", maxSplits: 1).first.map(String.init) ?? model
        let destination = destination(engine: engine, repo: repo)
        // No ensureDirectory here: an empty folder up front is still an empty
        // folder once the downloader starts filling it, and the model page
        // scans these directories — the library must not see a half-built
        // model as installed. hf_snapshot.py creates the folder itself.

        var arguments = [script, repo, destination]
        let trimmed = cache.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { arguments += ["--cache", trimmed] }

        return Plan(engine: engine,
                    model: model,
                    executable: python,
                    arguments: arguments,
                    workingDirectory: installation.root.path,
                    environment: environment(pythonRoot: installation.root.path, cache: cache),
                    watchDirectory: destination,
                    destination: destination)
    }

    /// A pack must never inherit the user's Python environment; a stray
    /// `PYTHONPATH` would load a different mlx and break the engine.
    static func environment(pythonRoot: String, cache: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PYTHONNOUSERSITE"] = "1"
        environment.removeValue(forKey: "PYTHONPATH")
        environment.removeValue(forKey: "PYTHONHOME")
        let prefix = pythonRoot + "/bin"
        if let path = environment["PATH"], !path.isEmpty {
            environment["PATH"] = prefix + ":" + path
        } else {
            environment["PATH"] = prefix + ":/usr/bin:/bin:/usr/sbin:/sbin"
        }
        let trimmed = cache.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { environment["HF_HUB_CACHE"] = trimmed }
        // Xet chunks land in HF_HOME/xet instead of the folder the download
        // watch measures, so a shard can stream for minutes while the watched
        // size holds still — the exact "进度卡住" report. Plain HTTP downloads
        // write straight into the watched `.incomplete` files, and the mirror
        // endpoints this app is used with do not speak xet anyway.
        environment["HF_HUB_DISABLE_XET"] = "1"
        // python 的 requests 不读 macOS 的系统代理设置：用户在「网络」里配了
        // 代理（或者挂着本地代理软件）时，URLSession 一路通畅，下载器却直接
        // ConnectTimeout。把系统代理原样塞进环境变量，两边走同一条路。
        if let proxy = systemProxy() {
            for key in ["HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy"] {
                environment[key] = proxy
            }
        }
        // 镜像端点同样是「设置里改了，下载器也得知道」的那一类。
        let endpoint = UserDefaults.standard.string(forKey: "hfEndpoint")?.trimmingCharacters(in: .whitespaces) ?? ""
        if !endpoint.isEmpty { environment["HF_ENDPOINT"] = endpoint }
        return environment
    }

    /// 系统代理（scutil --proxy 的结果），形如 `http://127.0.0.1:7890`。
    /// 没开代理返回 nil —— 不要给下载器塞空字符串，requests 会当成无效代理。
    static func systemProxy() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/scutil")
        process.arguments = ["--proxy"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        func value(_ key: String) -> String? {
            for line in output.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix(key + " :") else { continue }
                return trimmed.dropFirst(key.count + 2).trimmingCharacters(in: .whitespaces)
            }
            return nil
        }
        for (enable, host, port) in [("HTTPSEnable", "HTTPSProxy", "HTTPSPort"), ("HTTPEnable", "HTTPProxy", "HTTPPort")] {
            guard value(enable) == "1", let host = value(host), let port = value(port), !host.isEmpty else { continue }
            return "http://\(host):\(port)"
        }
        return nil
    }

    // MARK: Downloader script

    static var scriptPathValue: String { Paths.supportDirectory + "/scripts/hf_snapshot.py" }

    /// Write the snapshot downloader next to the support files, rewriting it
    /// only when its text changed so an update lands without touching mtimes
    /// on every download.
    static func scriptPath() throws -> String {
        let path = scriptPathValue
        let folder = (path as NSString).deletingLastPathComponent
        Paths.ensureDirectory(folder)
        if (try? String(contentsOfFile: path, encoding: .utf8)) != script {
            do {
                try script.write(toFile: path, atomically: true, encoding: .utf8)
            } catch {
                throw Failure.message("无法写入下载脚本：\(error.localizedDescription)")
            }
        }
        return path
    }

    /// Download one repository into a folder with huggingface_hub (v1 layout:
    /// partial files stay in `<destination>/.cache`), reporting the repo size
    /// first so the app can turn bytes on disk into a percentage.
    static let script = """
    #!/usr/bin/env python3
    \"\"\"Download one Hub repository into an engine's model folder.

    flashCat runs this with the Python that ships inside the engine pack, so
    every engine fetches weights through the same huggingface_hub with the same
    cache. `TOTAL <bytes>` is printed before the transfer so the app can show a
    percentage from the folder size, and the resolved path comes last.

    usage: hf_snapshot.py <owner/repo> <destination> [--cache DIR] [--revision REV]
    \"\"\"

    import argparse
    import os
    import sys


    def main() -> int:
        parser = argparse.ArgumentParser()
        parser.add_argument("repo")
        parser.add_argument("destination")
        parser.add_argument("--cache", default=None)
        parser.add_argument("--revision", default=None)
        args = parser.parse_args()

        from huggingface_hub import HfApi, snapshot_download

        cached = args.cache or None
        total = 0
        try:
            info = HfApi().model_info(args.repo, revision=args.revision, files_metadata=True)
            total = sum(size.size or 0 for size in (info.siblings or []))
        except Exception as error:  # size is a nicety, never a reason to stop
            print(f"Warning: 无法读取仓库大小：{error}", file=sys.stderr, flush=True)
        print(f"TOTAL {total}", flush=True)

        os.makedirs(args.destination, exist_ok=True)
        path = snapshot_download(
            repo_id=args.repo,
            revision=args.revision,
            local_dir=args.destination,
            cache_dir=cached,
            max_workers=8,
        )
        print(f"DONE {path}", flush=True)
        return 0


    if __name__ == "__main__":
        sys.exit(main())

    """

    // MARK: Progress

    /// Bytes currently on disk under a folder, partial downloads included.
    static func size(of directory: String) -> Int {
        guard let enumerator = FileManager.default.enumerator(atPath: directory) else { return 0 }
        var total = 0
        for case let entry as String in enumerator {
            let path = directory + "/" + entry
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let kind = attributes[.type] as? FileAttributeType,
                  kind == .typeRegular,
                  let bytes = attributes[.size] as? NSNumber else { continue }
            total += bytes.intValue
        }
        return total
    }
}
