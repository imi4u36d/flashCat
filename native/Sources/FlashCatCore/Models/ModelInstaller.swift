// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import FlashCatKit
import Foundation

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
package enum ModelInstaller {
    package enum Failure: Error {
        case message(String)

        package var message: String {
            switch self {
            case .message(let text): return text
            }
        }
    }

    package struct Plan {
        package let engine: EngineID
        package let model: String
        package let executable: String
        package let arguments: [String]
        package let workingDirectory: String
        package let environment: [String: String]
        /// Folder whose growth tracks the transfer, or nil when the engine
        /// reports progress itself.
        package let watchDirectory: String?
        /// Where the weights end up, for the confirmation prompt.
        package let destination: String
        /// Sibling marker written before the transfer starts and removed only
        /// when it succeeds. A canceled or crashed download leaves it behind,
        /// so a half-written snapshot (config.json + tokenizer already on
        /// disk) can never be mistaken for an installed model. Nil for Splash:
        /// its partials live in the Hub cache until the assembly is complete.
        package let incompleteMarker: String?

        package init(
            engine: EngineID, model: String, executable: String, arguments: [String],
            workingDirectory: String, environment: [String: String], watchDirectory: String?,
            destination: String, incompleteMarker: String?
        ) {
            self.engine = engine
            self.model = model
            self.executable = executable
            self.arguments = arguments
            self.workingDirectory = workingDirectory
            self.environment = environment
            self.watchDirectory = watchDirectory
            self.destination = destination
            self.incompleteMarker = incompleteMarker
        }
    }

    /// Marker lives next to the model folder, not inside it: the downloader
    /// owns that directory, and nested engines must be free to create it.
    package static func incompleteMarker(for destination: String) -> String {
        destination + ".flashcat-incomplete"
    }

    // MARK: Destination

    /// Weight folders are flat: `owner--repo` is the id every engine serves, and
    /// the same shape a download lands in. The rule lives in `FlashCatPaths`
    /// so the CLI resolves an existing weight folder identically.
    package static func folderName(for repo: String) -> String {
        FlashCatPaths.modelFolderName(for: repo)
    }

    package static func destination(engine: EngineID, repo: String) -> String {
        EnginePaths.modelPath(for: engine, model: repo)
    }

    /// 公共目录的落地路径。一份权重由哪些引擎共享，记在 `ModelSharing` 的
    /// 授权表里，下载器只管把快照放进去。
    package static func sharedDestination(repo: String) -> String {
        ModelSharing.path(for: repo)
    }

    // MARK: Plan

    package static func plan(
        engine: EngineID,
        model: String,
        draftRepository: String?,
        cache: String,
        source: HubSource = .huggingFace,
        include: [String] = []
    ) throws -> Plan {
        switch engine.adapter {
        case .splash:
            return try splashPlan(
                model: model,
                draftRepository: draftRepository,
                cache: cache,
                source: source)
        case .omlx, .mtplx:
            return try snapshotPlan(
                engine: engine, model: model, cache: cache, source: source, include: include)
        case .mlxServe:
            // The native puller only takes whole Hugging Face repositories.
            // A quant pick or a mirror needs the shared Python downloader,
            // which can still write into MLX-Serve's nested model directory.
            if source == .huggingFace, include.isEmpty {
                return try mlxServePlan(engine: engine, model: model, cache: cache, source: source)
            }
            return try snapshotPlan(
                engine: engine, model: model, cache: cache, source: source, include: include)
        default:
            return try snapshotPlan(
                engine: engine, model: model, cache: cache, source: source, include: include)
        }
    }

    private static func splashPlan(
        model: String,
        draftRepository: String?,
        cache: String,
        source: HubSource
    ) throws -> Plan {
        guard source.isHuggingFaceCompatible else {
            throw Failure.message(
                "Splash 的安装器只支持 Hugging Face；要经 ModelScope 下载，请选择 oMLX、MTPLX 或 MLX-Serve")
        }
        guard let installation = EngineInstallations.newest(.splash, version: nil) else {
            throw Failure.message("还没有安装 Splash 引擎，无法下载模型")
        }
        let runtime = EngineRuntime(root: installation.root.path)
        guard runtime.exists else {
            throw Failure.message("Splash pack 不完整，缺少安装器或运行时")
        }
        let script = runtime.root + "/install/models.py"
        guard Paths.fileExists(script) else {
            throw Failure.message("Splash 引擎缺少 install/models.py")
        }
        var arguments = [
            "-u", script,
            "--models", Paths.modelsDirectory,
            "--model", model,
        ]
        if let draftRepository {
            arguments += ["--draft-model", draftRepository]
        }
        arguments.append("prepare")
        return Plan(
            engine: .splash,
            model: model,
            executable: runtime.pythonPath,
            arguments: arguments,
            workingDirectory: runtime.root,
            environment: environment(pythonRoot: runtime.root, cache: cache, source: source),
            watchDirectory: nil,
            destination: Paths.modelsDirectory,
            incompleteMarker: nil)
    }

    /// 任取一个 Hub 仓库下到公共目录。下载器仍是引擎包里那个 Python：HF 走
    /// `huggingface_hub`，ModelScope 走标准库脚本；哪个 pack 装了 Python 就用
    /// 哪个，都没有才报错。
    ///
    /// `include` 是 GGUF 量化选项挑出来的文件清单（含 mmproj），只对
    /// Python 下载器生效；MLX-Serve 的原生 puller 只会整仓下载。
    package static func sharedPlan(
        repo: String, engines: [EngineID],
        cache: String,
        source: HubSource = .huggingFace,
        include: [String] = []
    ) throws -> Plan {
        var candidates = engines
        candidates += EngineCatalog.allIDs
        var python: String?
        var root: String?
        var seen = Set<EngineID>()
        for id in candidates where seen.insert(id).inserted {
            // Shared downloads require a Python pack. Native adapters use their
            // own puller and never receive flashCat's snapshot script.
            guard let installation = EngineInstallations.newest(id, version: nil),
                installation.entrypoint.path.contains("/python/"),
                Paths.fileExists(installation.entrypoint.path)
            else { continue }
            python = installation.entrypoint.path
            root = installation.root.path
            break
        }
        if python == nil,
            engines.contains(.mlxServe) || seen.contains(.mlxServe),
            let installation = EngineInstallations.newest(.mlxServe, version: nil)
        {
            guard source.isHuggingFaceCompatible, include.isEmpty else {
                throw Failure.message("MLX-Serve 的原生下载器只能整仓下载 Hugging Face 仓库，选量化需要先装一个带 Python 的引擎包")
            }
            // 原生 puller 把 huggingface.co 写死了，不读 HF_ENDPOINT；要走镜像
            // 得换一个 Python 下载器，否则会在国内不可达的官方端点上卡住。
            guard source == .huggingFace else {
                throw Failure.message("MLX-Serve 的原生下载器不支持镜像端点；要经 HF-Mirror 下载，请先装一个带 Python 的引擎包：Splash、oMLX 或 MTPLX")
            }
            return try mlxServeSharedPlan(
                repo: repo,
                installation: installation,
                cache: cache,
                source: source)
        }
        guard let python, let root else {
            throw Failure.message("公共下载需要已安装的 MLX-Serve，或任意一个带 Python 的引擎包：Splash、oMLX、MTPLX")
        }
        let name = repo.split(separator: ":", maxSplits: 1).first.map(String.init) ?? repo
        let destination = sharedDestination(repo: name)
        let script: String
        switch source {
        case .huggingFace, .hfMirror: script = try scriptPath()
        case .modelScope: script = try modelScopeScriptPath()
        }
        var arguments = [script, name, destination]
        if source.isHuggingFaceCompatible {
            let trimmed = cache.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { arguments += ["--cache", trimmed] }
        }
        for pattern in include {
            arguments += ["--include", pattern]
        }
        return Plan(
            engine: engines.first ?? .omlx,
            model: name,
            executable: python,
            arguments: arguments,
            workingDirectory: root,
            environment: environment(pythonRoot: root, cache: cache, source: source),
            watchDirectory: destination,
            destination: destination,
            incompleteMarker: incompleteMarker(for: destination))
    }

    /// Use MLX-Serve's native puller when no Python downloader is installed,
    /// then move the completed nested repository into flashCat's shared layout.
    private static func mlxServeSharedPlan(
        repo: String,
        installation: EngineInstallation,
        cache: String,
        source: HubSource
    ) throws -> Plan {
        let name = repo.split(separator: ":", maxSplits: 1).first.map(String.init) ?? repo
        let home = Paths.supportDirectory + "/engine-homes/mlx-serve-shared"
        let stagingRoot = home + "/.mlx-serve/models"
        let staged = stagingRoot + "/" + name
        let destination = sharedDestination(repo: name)
        Paths.ensureDirectory(stagingRoot)
        Paths.ensureDirectory((destination as NSString).deletingLastPathComponent)
        var environment = self.environment(
            pythonRoot: installation.root.path, cache: cache, source: source)
        environment["HOME"] = home
        environment["MLX_SERVE_NO_UPDATE_CHECK"] = "1"
        let script = """
            set -euo pipefail
            "$1" pull "$2"
            mkdir -p "$(dirname "$3")"
            mv "$4" "$3"
            """
        return Plan(
            engine: .mlxServe,
            model: repo,
            executable: "/bin/sh",
            arguments: [
                "-c", script, "flashcat-mlx-serve",
                installation.entrypoint.path, repo, destination, staged,
            ],
            workingDirectory: installation.root.path,
            environment: environment,
            watchDirectory: staged,
            destination: destination,
            incompleteMarker: incompleteMarker(for: destination))
    }

    /// Snapshot one repository into an engine's own model directory.
    ///
    /// The engine's bundled Python does the transfer. A native engine (MLX-Serve)
    /// has no Python of its own, so a quant pick or a mirror borrows any other
    /// installed pack's Python while still writing into the chosen engine's
    /// directory.
    private static func snapshotPlan(
        engine: EngineID,
        model: String,
        cache: String,
        source: HubSource,
        include: [String]
    ) throws -> Plan {
        guard let installation = EngineInstallations.newest(engine, version: nil) else {
            throw Failure.message("还没有安装 \(engine.displayName) 引擎，无法下载模型")
        }
        var python = installation.entrypoint.path
        var pythonRoot = installation.root.path
        if !python.contains("/python/") {
            let fallback = EngineCatalog.allIDs.lazy
                .filter { $0 != engine }
                .compactMap { EngineInstallations.newest($0, version: nil) }
                .first { $0.entrypoint.path.contains("/python/") }
            guard let fallback else {
                throw Failure.message(
                    "\(engine.displayName) 是原生运行时，选量化或镜像下载需要先装一个带 Python 的引擎包：Splash、oMLX 或 MTPLX")
            }
            python = fallback.entrypoint.path
            pythonRoot = fallback.root.path
        }
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
        for pattern in include {
            arguments += ["--include", pattern]
        }

        return Plan(
            engine: engine,
            model: model,
            executable: python,
            arguments: arguments,
            workingDirectory: pythonRoot,
            environment: environment(
                pythonRoot: pythonRoot, cache: cache, source: source),
            watchDirectory: destination,
            destination: destination,
            incompleteMarker: incompleteMarker(for: destination))
    }

    /// mlx-serve owns its downloader. Redirect its isolated HOME's model store
    /// to flashCat's model directory so the app remains the source of truth.
    private static func mlxServePlan(
        engine: EngineID,
        model: String,
        cache: String,
        source: HubSource
    ) throws -> Plan {
        // 原生 puller 不读 HF_ENDPOINT：镜像来源在这里只能明确拒绝，不能
        // 悄悄退回官方端点。
        guard source == .huggingFace else {
            throw Failure.message(
                "MLX-Serve 的原生下载器不支持镜像端点；请在「设置 → 模型来源」切回 Hugging Face，或先装一个带 Python 的引擎包")
        }
        guard let installation = EngineInstallations.newest(engine, version: nil) else {
            throw Failure.message("还没有安装 \(engine.displayName) 引擎，无法下载模型")
        }
        let engineHome = Paths.supportDirectory + "/engine-homes/mlx-serve"
        let metadataRoot = engineHome + "/.mlx-serve"
        let modelsRoot = EnginePaths.modelsDirectory(engine)
        Paths.ensureDirectory(metadataRoot)
        Paths.ensureDirectory(modelsRoot)
        let link = metadataRoot + "/models"
        if !Paths.fileExists(link) {
            try? FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: modelsRoot)
        }
        guard FlashCatPaths.isSafeRepository(model) else {
            throw Failure.message("模型 id 要写成 owner/repo，不能包含路径分隔符或 `..`")
        }
        let repo = model.split(separator: ":", maxSplits: 1).first.map(String.init) ?? model
        let destination = modelsRoot + "/" + repo
        var environment = self.environment(
            pythonRoot: installation.root.path, cache: cache, source: source)
        environment["HOME"] = engineHome
        environment["MLX_SERVE_NO_UPDATE_CHECK"] = "1"
        return Plan(
            engine: engine,
            model: model,
            executable: installation.entrypoint.path,
            arguments: ["pull", model],
            workingDirectory: installation.root.path,
            environment: environment,
            watchDirectory: destination,
            destination: destination,
            incompleteMarker: incompleteMarker(for: destination))
    }

    /// A pack must never inherit the user's Python environment; a stray
    /// `PYTHONPATH` would load a different mlx and break the engine.
    package static func environment(
        pythonRoot: String,
        cache: String,
        source: HubSource = .huggingFace
    ) -> [String: String] {
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
        // 镜像端点同样是「来源选了什么，下载器就得知道」的那一类：HF-Mirror
        // 固定写 hf-mirror.com，官方来源写设置里的自定义端点（空 = 官方）。
        // huggingface_hub 在 import 时读这个变量，所以按来源注入才生效。
        if let endpoint = HFEndpoint.resolved(for: source) {
            environment["HF_ENDPOINT"] = endpoint
        } else {
            environment.removeValue(forKey: "HF_ENDPOINT")
        }
        return environment
    }

    /// 系统代理（scutil --proxy 的结果），形如 `http://127.0.0.1:7890`。
    /// 没开代理返回 nil —— 不要给下载器塞空字符串，requests 会当成无效代理。
    package static func systemProxy() -> String? {
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
        for (enable, host, port) in [
            ("HTTPSEnable", "HTTPSProxy", "HTTPSPort"), ("HTTPEnable", "HTTPProxy", "HTTPPort"),
        ] {
            guard value(enable) == "1", let host = value(host), let port = value(port), !host.isEmpty else { continue }
            return "http://\(host):\(port)"
        }
        return nil
    }

    // MARK: Downloader script

    package static var scriptPathValue: String { Paths.supportDirectory + "/scripts/hf_snapshot.py" }
    package static var modelScopeScriptPathValue: String { Paths.supportDirectory + "/scripts/ms_snapshot.py" }

    /// Write the snapshot downloader next to the support files, rewriting it
    /// only when its text changed so an update lands without touching mtimes
    /// on every download.
    package static func scriptPath() throws -> String {
        try writeScript(script, to: scriptPathValue)
    }

    package static func modelScopeScriptPath() throws -> String {
        try writeScript(modelScopeScript, to: modelScopeScriptPathValue)
    }

    private static func writeScript(_ text: String, to path: String) throws -> String {
        let folder = (path as NSString).deletingLastPathComponent
        Paths.ensureDirectory(folder)
        if (try? String(contentsOfFile: path, encoding: .utf8)) != text {
            do {
                try text.write(toFile: path, atomically: true, encoding: .utf8)
            } catch {
                throw Failure.message("无法写入下载脚本：\(error.localizedDescription)")
            }
        }
        return path
    }

    /// Download one repository into a folder with huggingface_hub (v1 layout:
    /// partial files stay in `<destination>/.cache`), reporting the repo size
    /// first so the app can turn bytes on disk into a percentage.
    package static let script = """
        #!/usr/bin/env python3
        \"\"\"Download one Hub repository into an engine's model folder.

        flashCat runs this with the Python that ships inside the engine pack, so
        every engine fetches weights through the same huggingface_hub with the same
        cache. `TOTAL <bytes>` is printed before the transfer so the app can show a
        percentage from the folder size, and the resolved path comes last.

        usage: hf_snapshot.py <owner/repo> <destination> [--cache DIR] [--revision REV] [--include PATTERN ...]
        \"\"\"

        import argparse
        import fnmatch
        import os
        import sys


        def main() -> int:
            parser = argparse.ArgumentParser()
            parser.add_argument("repo")
            parser.add_argument("destination")
            parser.add_argument("--cache", default=None)
            parser.add_argument("--revision", default=None)
            parser.add_argument("--include", action="append", default=[])
            args = parser.parse_args()

            from huggingface_hub import HfApi, snapshot_download

            cached = args.cache or None
            total = 0
            try:
                info = HfApi().model_info(args.repo, revision=args.revision, files_metadata=True)
                files = info.siblings or []
                if args.include:
                    files = [
                        item for item in files
                        if any(fnmatch.fnmatch(item.rfilename, pattern) for pattern in args.include)
                    ]
                total = sum(size.size or 0 for size in files)
            except Exception as error:  # size is a nicety, never a reason to stop
                print(f"Warning: 无法读取仓库大小：{error}", file=sys.stderr, flush=True)
            print(f"TOTAL {total}", flush=True)

            os.makedirs(args.destination, exist_ok=True)
            path = snapshot_download(
                repo_id=args.repo,
                revision=args.revision,
                local_dir=args.destination,
                cache_dir=cached,
                allow_patterns=args.include or None,
                max_workers=8,
            )
            print(f"DONE {path}", flush=True)
            return 0


        if __name__ == "__main__":
            sys.exit(main())

        """

    /// ModelScope 没有 huggingface_hub 那套快照器，但它的文件清单和
    /// `resolve` 地址已经够用：标准库列文件、Range 续传、`.part` 落盘，
    /// 进度仍交给 DownloadCenter 看文件夹大小。`--include` 接的是仓库里的
    /// 完整路径（量化选择传选中的分片 + mmproj）。
    package static let modelScopeScript = """
        #!/usr/bin/env python3
        # Download one ModelScope repository into a folder with the standard library.
        #
        # flashCat runs this with the Python inside an engine pack. `TOTAL <bytes>` is
        # printed before the transfer so the app can show a percentage, and `DONE` last.
        # `--include` takes exact repository paths (the GGUF quant picker sends the
        # chosen shard files plus mmproj), and partial `.part` files resume by Range.

        import argparse
        import fnmatch
        import json
        import os
        import sys
        import urllib.error
        import urllib.parse
        import urllib.request
        from concurrent.futures import ThreadPoolExecutor, as_completed

        ENDPOINT = "https://www.modelscope.cn"


        def quote(value):
            return urllib.parse.quote(value, safe="/")


        def read_json(url):
            request = urllib.request.Request(url, headers={"User-Agent": "flashCat/1.0"})
            with urllib.request.urlopen(request, timeout=60) as response:
                return json.load(response)


        def list_files(repo, revision):
            last = None
            for candidate in [revision, "main"]:
                url = (
                    ENDPOINT + "/api/v1/models/" + quote(repo) + "/repo/files?Revision="
                    + urllib.parse.quote(candidate) + "&Recursive=true"
                )
                try:
                    payload = read_json(url)
                except urllib.error.HTTPError as error:
                    if error.code != 404:
                        raise
                    last = error
                    continue
                files = (payload.get("Data") or {}).get("Files") or []
                return [item for item in files if (item.get("Type") or "blob") == "blob"], candidate
            raise last


        def download(item, destination, repo, revision):
            path = item.get("Path") or ""
            if not path:
                return
            size = int(item.get("Size") or 0)
            target = os.path.join(destination, path)
            parent = os.path.dirname(target)
            if parent:
                os.makedirs(parent, exist_ok=True)
            if os.path.exists(target) and (size == 0 or os.path.getsize(target) == size):
                return
            part = target + ".part"
            offset = os.path.getsize(part) if os.path.exists(part) else 0
            if size and offset == size:
                os.replace(part, target)
                return
            if not size:
                offset = 0
            elif offset > size:
                os.remove(part)
                offset = 0
            url = (
                ENDPOINT + "/models/" + quote(repo) + "/resolve/" + urllib.parse.quote(revision)
                + "/" + quote(path)
            )
            request = urllib.request.Request(url, headers={"User-Agent": "flashCat/1.0"})
            if offset:
                request.add_header("Range", "bytes=%d-" % offset)
            with urllib.request.urlopen(request, timeout=120) as response:
                status = getattr(response, "status", 200)
                mode = "ab" if status == 206 else "wb"
                with open(part, mode) as output:
                    while True:
                        chunk = response.read(1024 * 1024)
                        if not chunk:
                            break
                        output.write(chunk)
            if size and os.path.getsize(part) != size:
                raise RuntimeError("size mismatch: %s" % path)
            os.replace(part, target)


        def main():
            parser = argparse.ArgumentParser()
            parser.add_argument("repo")
            parser.add_argument("destination")
            parser.add_argument("--revision", default="master")
            parser.add_argument("--include", action="append", default=[])
            args = parser.parse_args()

            repo = args.repo.strip().strip("/")
            if repo.count("/") != 1:
                print("ERROR 仓库 id 要写成 owner/repo", file=sys.stderr, flush=True)
                return 2
            os.makedirs(args.destination, exist_ok=True)
            try:
                files, revision = list_files(repo, args.revision)
            except Exception as error:
                print("ERROR 无法读取 ModelScope 文件清单：%s" % error, file=sys.stderr, flush=True)
                return 1
            if args.include:
                files = [
                    item for item in files
                    if any(fnmatch.fnmatch(item.get("Path") or "", pattern) for pattern in args.include)
                ]
            total = sum(int(item.get("Size") or 0) for item in files)
            print("TOTAL %d" % total, flush=True)
            if not files:
                print("ERROR 没有匹配到要下载的文件", file=sys.stderr, flush=True)
                return 1

            errors = []
            with ThreadPoolExecutor(max_workers=8) as pool:
                futures = [
                    pool.submit(download, item, args.destination, repo, revision)
                    for item in files
                ]
                for future in as_completed(futures):
                    try:
                        future.result()
                    except Exception as error:
                        errors.append(str(error))
            if errors:
                for message in errors:
                    print("ERROR %s" % message, file=sys.stderr, flush=True)
                return 1
            print("DONE %s" % args.destination, flush=True)
            return 0


        if __name__ == "__main__":
            sys.exit(main())

        """

    // MARK: Progress

    /// Bytes currently on disk under a folder, partial downloads included.
    package static func size(of directory: String) -> Int {
        guard let enumerator = FileManager.default.enumerator(atPath: directory) else { return 0 }
        var total = 0
        for case let entry as String in enumerator {
            let path = directory + "/" + entry
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                let kind = attributes[.type] as? FileAttributeType,
                kind == .typeRegular,
                let bytes = attributes[.size] as? NSNumber
            else { continue }
            total += bytes.intValue
        }
        return total
    }
}
