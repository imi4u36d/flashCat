// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import Combine
import FlashCatKit
import Foundation

/// 下载收尾时要交回 AppState 的两件事。
///
/// 这两件事都得看 AppState 才知道怎么办：「这次下载是不是启动前的补件」「下完
/// 该不该把选中模型换过去」牵扯当前引擎与模型目录。所以 store 只交出「发生了
/// 什么」，怎么反应留给消费方——这样它就不必反过来持有 AppState。
enum DownloadEvent {
    /// 权重已经落盘、模型能用了。
    /// - Parameter installed: 模型库里的 id。splash 用仓库名、其他引擎用文件夹
    ///   名，这个换算在 store 里因为它知道自己的目标目录；但要不要选中它，只有
    ///   AppState 能定。
    case modelReady(engine: EngineID, model: String, installed: String)
    /// 公共目录里的仓库下完了：写授权表、建链接、刷新模型页都归 AppState。
    case shareRequested(repo: String, engines: [EngineID])
}

/// How a download ended, for the callers that wait on one instead of
/// watching the download center.
enum DownloadOutcome {
    /// Every byte arrived and the model is installed.
    case finished
    /// The user paused or cancelled it; nothing is wrong, it just is not there.
    case cancelled
    case failed(String)
}

/// 下载中心：一个下载子进程、一条进度、一份持久化的任务行列表。
///
/// 它只负责「传输」——起进程、读字节、暂停/续传/取消、记任务行。「什么时候该
/// 下载」「下完要不要切模型」仍然留在 AppState，那些判断牵扯当前引擎、模型目录
/// 和授权表，搬过来只会把两边绑成环。往外用 `hooks` 回调，往回调用
/// `DownloadEvent`，谁也不持有对方。
@MainActor
final class DownloadCenter: ObservableObject {
    /// 外层能帮的事。用闭包注入而不是持有 AppState：外层已经持有本对象，反向
    /// 再持有一个就是循环引用，改动一处会安静地泄漏整个 AppState。
    struct Hooks {
        /// 引擎日志。`engine` 为 nil 表示「当前引擎」：退出清理发生在下载之外，
        /// 该写哪一份日志只有 AppState 知道。
        var log: @MainActor (_ line: String, _ engine: EngineID?) -> Void = { _, _ in }
        /// 灵动岛提示。第二个参数是一过性（只闪几秒，不进通知历史）。
        var toast: @MainActor (_ message: String, _ transient: Bool) -> Void = { _, _ in }
        /// 阻塞式错误横幅：用户必须看见、不会自己滚走的失败。
        var setNotice: @MainActor (_ message: String) -> Void = { _ in }
        /// 模型目录变了（下完 / 清掉半成品）：模型列表的短缓存要作废并重扫。
        var reloadModels: @MainActor () -> Void = {}
        /// 任务行集合变了（引擎 / 模型 / 状态）：侧栏与模型页的扫盘缓存要作废。
        var modelInventoryChanged: @MainActor () -> Void = {}
    }

    var hooks = Hooks()
    var onEvent: (@MainActor (DownloadEvent) -> Void)?

    /// 正在下载的模型 id 与它所属的引擎。两个引擎可能有同名模型，只有正在写
    /// 的那一个才显示进度。
    @Published private(set) var downloadingModel: String?
    @Published private(set) var downloadingEngine: EngineID?
    @Published private(set) var downloadFraction: Double?
    /// Live transfer speed of the running download, bytes per second.
    @Published private(set) var downloadSpeed: Double = 0
    /// 下载中心的行。暂停/失败的传输重启后仍在（Hub 的半成品留在目标的
    /// `.cache` 里），所以这份列表要持久化，加载时「下载中」降级成「已暂停」。
    @Published private(set) var downloadTasks: [ModelDownloadTask] = [] {
        didSet {
            // 进度每跳都会改 `downloadedBytes`，但模型集合没变；只有引擎/模型/
            // 状态真的变化时才让外层的模型目录缓存失效，避免下载期间侧栏和
            // 模型页反复扫盘。
            let before = oldValue.map { "\($0.engine.rawValue)|\($0.model)|\($0.status.rawValue)" }
            let after = downloadTasks.map { "\($0.engine.rawValue)|\($0.model)|\($0.status.rawValue)" }
            if before != after { hooks.modelInventoryChanged() }
        }
    }

    /// 轮询间隔。以前是 0.5 秒：模型目录动辄上千个分片，每跳都要把整棵树 stat
    /// 一遍，换个模型就能白烧掉可观的 CPU 和磁盘唤醒。进度条 1 秒更新一次已经
    /// 看不出卡顿，扫盘次数却砍半。
    private static let watchInterval: UInt64 = 1_000_000_000

    /// Polls the folder a snapshot download writes into, so the card can show
    /// a percentage without the downloader having to report one.
    private var downloadWatchTask: Task<Void, Never>?
    /// Bytes the Hub says the whole repository needs, printed by the downloader
    /// before the transfer starts.
    private var downloadTotalBytes = 0
    /// 本次会话里 downloader 宣布「还要抓」的字节数。Splash 的每个仓库只报
    /// 尚未进缓存的那部分，续传时它是「剩余」而不是总量，所以总量要用
    /// `downloadResumeBytes + downloadFetchedBytes` 重新算。
    private var downloadFetchedBytes = 0
    /// The running downloader child process; terminating it is how pause and
    /// cancel stop the transfer while the Hub's partial files stay on disk.
    private var downloadProcess: Process?
    /// Sibling marker for the model folder this transfer writes. It is created
    /// before the child starts and removed only on success, so a canceled or
    /// crashed download can never pass the scanner as an installed model.
    private var downloadIncompleteMarker: String?
    /// Set while a caller waits for a download to end (a launch that has to
    /// fetch the model's DFlash2 draft first). Reported once, in
    /// `finishDownload`, whichever way the process ended.
    private var downloadCompletion: ((DownloadOutcome) -> Void)?
    private var pauseRequested = false
    private var cancelRequested = false
    /// 用户直接删掉了正在跑的那一行：停掉子进程后 `finishDownload` 要把
    /// 任务行和半成品一起清掉，而不是像普通取消那样留一行「已暂停」。
    private var removeRequested = false
    private var lastWatchBytes = 0
    private var lastWatchDate: Date?
    /// Bytes this transfer already had on disk when it (re)started. A resumed
    /// download begins counting from here instead of 0, so both the card and
    /// the download center keep showing 已下载/总量 across a pause.
    private var downloadResumeBytes = 0
    /// Hub cache folders the running download fills, discovered from the
    /// child's `Fetching …` lines. Splash's tqdm only counts finished files —
    /// its bar sits at 0% for minutes while one shard streams — so byte growth
    /// under these folders is what actually moves the bar.
    private var downloadWatchDirectories: [String] = []
    /// Size of each watched folder when it joined the watch: bytes that were
    /// already cached before this download started are not new progress.
    private var downloadWatchBaselines: [String: Int] = [:]
    /// 正在下载到公共目录的仓库与它的授权引擎：下载成功后据此写授权表、建
    /// 链接。非公共下载时为 nil。
    private var pendingSharedRepo: String?
    private var pendingSharedEngines: [EngineID] = []
    private var terminatingDownloadPid: Int32?

    init() {
        // 上一次运行留下的行也要显示：暂停/失败的传输重启后还能继续。
        downloadTasks = ModelDownloadStore.load()
    }

    // MARK: transfer lifecycle

    /// - Returns: whether the process started; `false` comes with a notice.
    @discardableResult
    func startDownload(
        _ plan: ModelInstaller.Plan,
        engine: EngineID,
        id: String,
        shared: [EngineID]?
    ) -> Bool {
        pendingSharedRepo = shared == nil ? nil : id
        pendingSharedEngines = shared ?? []
        pauseRequested = false
        cancelRequested = false
        removeRequested = false
        downloadSpeed = 0
        // Resume, not restart: a paused/failed row already recorded where the
        // transfer stood, and the Hub's partial files are still on disk. Seed
        // the progress with those bytes so the bar continues from 已下载/总量
        // instead of dropping back to 0%. A brand-new download has no row and
        // therefore starts at zero.
        let previous = downloadTasks.first { $0.engine == engine && $0.model == id }
        let resumeTotal = max(previous?.totalBytes ?? 0, 0)
        let previousBytes = max(previous?.downloadedBytes ?? 0, 0)
        // Without a known total the row still knows how many bytes were on
        // disk; keep them and let the first TOTAL line supply the denominator.
        let resumeBytes = resumeTotal > 0 ? min(previousBytes, resumeTotal) : previousBytes
        downloadResumeBytes = resumeBytes
        downloadFetchedBytes = 0
        lastWatchBytes = resumeBytes
        lastWatchDate = nil
        downloadWatchDirectories = []
        downloadWatchBaselines = [:]
        downloadIncompleteMarker = plan.incompleteMarker
        // 标记只下在「本来就不存在」的目标上，且必须落在模型目录内：否则一次
        // 失败的重复下载会给已装好的模型盖章，之后「移除」就会删掉好权重。
        if let marker = plan.incompleteMarker,
            !Paths.fileExists(plan.destination),
            FlashCatPaths.contains(plan.destination, in: EnginePaths.modelsRoot)
        {
            Paths.ensureDirectory((marker as NSString).deletingLastPathComponent)
            FileManager.default.createFile(atPath: marker, contents: nil)
        }
        upsertTask(engine: engine, model: id) { task in
            task.status = .downloading
            task.shared = shared
            task.downloadedBytes = resumeBytes
            task.totalBytes = max(task.totalBytes, resumeTotal)
            if task.addedAt.timeIntervalSinceNow < -60 * 60 * 24 * 30 { task.addedAt = Date() }
        }
        downloadingModel = id
        downloadingEngine = engine
        downloadTotalBytes = resumeTotal
        downloadFraction = resumeTotal > 0 ? Double(resumeBytes) / Double(resumeTotal) : 0
        append(
            shared == nil
                ? "==> \(engine.displayName) 下载模型：\(id)"
                : "==> 下载模型到公共目录：\(id)", engine: engine)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: plan.executable)
        process.arguments = plan.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: plan.workingDirectory)
        process.environment = plan.environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        // Where this child's Hub cache lives: splash downloads land there
        // before the finished assembly is installed into the models folder.
        let hubCacheRoot =
            plan.environment["HF_HUB_CACHE"]
            ?? (plan.environment["HF_HOME"].map { $0 + "/hub" }
                ?? (Paths.home + "/.cache/huggingface/hub"))

        TailReader.read(pipe) { line in
            DispatchQueue.main.async {
                self.append(line, engine: engine)
                if let total = Self.totalBytes(in: line) {
                    // Snapshot downloader: TOTAL is the repository's full size,
                    // so it is the denominator with or without a resume.
                    self.downloadTotalBytes = max(total, self.downloadResumeBytes)
                    self.upsertTask(engine: engine, model: id) {
                        $0.totalBytes = max($0.totalBytes, self.downloadTotalBytes)
                    }
                    if let directory = plan.watchDirectory {
                        self.watch(directory, engine: engine, model: id)
                    }
                } else if let fetch = Self.fetchPlan(in: line) {
                    // Splash's installer announces every repository it is
                    // about to fetch with its exact byte size. On a fresh
                    // download those sizes sum to the total; on a resume the
                    // cache already holds part of the repository and the
                    // announcement only covers what is still missing, so the
                    // denominator is 已下载 + 剩余, never just 剩余.
                    self.downloadFetchedBytes += fetch.bytes
                    self.downloadTotalBytes = max(
                        self.downloadTotalBytes,
                        self.downloadResumeBytes + self.downloadFetchedBytes)
                    self.upsertTask(engine: engine, model: id) {
                        $0.totalBytes = max($0.totalBytes, self.downloadTotalBytes)
                    }
                    self.watch(
                        hubCacheRoot + "/models--"
                            + fetch.repo.replacingOccurrences(of: "/", with: "--"),
                        engine: engine, model: id)
                } else if self.downloadTotalBytes == 0,
                    let match = TextPattern.firstMatch("(\\d{1,3})%", line),
                    let value = Double(match[1])
                {
                    // Fallback when no total is known: the downloader's own
                    // percentage. Snapshot engines and splash both report
                    // byte totals now, so this only covers unusual output.
                    let fraction = min(max(value / 100, 0), 1)
                    self.downloadFraction = fraction
                    if self.downloadTotalBytes > 0 {
                        self.upsertTask(engine: engine, model: id) {
                            $0.downloadedBytes = Int(fraction * Double(self.downloadTotalBytes))
                        }
                    }
                }
            }
        }

        process.terminationHandler = { finished in
            let status = finished.terminationStatus
            // 走到这里时下载进程已经退出，回调只带三个可发送的值；用
            // `Task { @MainActor }` 而不是闭包里的 `self?`——弱引用在
            // `@Sendable` 闭包里被当成「可变捕获」，严格并发会报错。
            Task { @MainActor in
                AppState.shared.downloads.finishDownload(engine: engine, model: id, status: status)
            }
        }

        do {
            try process.run()
            downloadProcess = process
            return true
        } catch {
            downloadingModel = nil
            downloadingEngine = nil
            downloadFraction = nil
            downloadTotalBytes = 0
            downloadResumeBytes = 0
            downloadFetchedBytes = 0
            lastWatchBytes = 0
            lastWatchDate = nil
            downloadWatchDirectories = []
            downloadWatchBaselines = [:]
            downloadIncompleteMarker = nil
            if let marker = plan.incompleteMarker {
                discard(marker, why: "下载未能启动，清掉半成品标记")
            }
            removeTask(engine: engine, model: id)
            hooks.setNotice("无法启动下载：\(error.localizedDescription)")
            return false
        }
    }

    /// 等这次下载结束的人（启动前补 DFlash2 的那条路径）在这里挂上回调。
    /// 只能有一个等待者：第二次挂上会覆盖掉第一次，于是第一个 `await` 永远
    /// 不醒——调用方要先确认没有别的传输在跑。
    func setCompletion(_ completion: ((DownloadOutcome) -> Void)?) {
        downloadCompletion = completion
    }

    /// Stop the running transfer. Partial files stay in the destination's
    /// `.cache`, so 继续 picks up exactly where this left off.
    func pauseDownload() {
        guard let process = downloadProcess, let model = downloadingModel else { return }
        pauseRequested = true
        downloadSpeed = 0
        append("==> 暂停下载：\(model)，进度已保留", engine: downloadingEngine)
        process.terminate()
    }

    // MARK: termination

    /// Quit-time cleanup. The downloader is a child process too, and an orphaned
    /// one keeps pulling gigabytes to disk with no window left to stop it from.
    func prepareForTermination() {
        guard let process = downloadProcess, process.isRunning else { return }
        terminatingDownloadPid = processPid(process)
        append("==> 退出应用，终止正在进行的下载", engine: downloadingEngine)
        process.terminate()
    }

    /// SIGTERM was ignored, or the child is blocked inside a network read.
    /// Partial files stay on disk, so the next launch resumes the transfer
    /// instead of starting over.
    func finishTermination() {
        guard let pid = terminatingDownloadPid else { return }
        terminatingDownloadPid = nil
        kill(pid, SIGKILL)
    }

    /// Drop a task from the center. For a running transfer that means
    /// terminating the child; partial files stay on disk so nothing else is
    /// destroyed — a later download simply resumes them.
    func cancelDownload(_ task: ModelDownloadTask) {
        if let process = downloadProcess,
            downloadingModel == task.model, downloadingEngine == task.engine
        {
            cancelRequested = true
            downloadSpeed = 0
            append("==> 取消下载：\(task.model)", engine: task.engine)
            process.terminate()
        } else {
            removeTask(engine: task.engine, model: task.model)
            discardPartialDownload(task)
            hooks.toast("已从下载中心移除", false)
        }
    }

    /// Remove a finished/failed/stale row from the center.
    ///
    /// Deleting the row of the transfer that is still running has to stop the
    /// child as well: the progress watcher upserts the row every second, so
    /// merely dropping it from the list would make it reappear immediately.
    func removeTask(_ task: ModelDownloadTask) {
        if let process = downloadProcess, process.isRunning,
            downloadingModel == task.model, downloadingEngine == task.engine
        {
            removeRequested = true
            cancelRequested = true
            downloadSpeed = 0
            append("==> 删除下载任务并停止传输：\(task.model)", engine: task.engine)
            process.terminate()
            return
        }
        removeTask(engine: task.engine, model: task.model)
        discardPartialDownload(task)
    }

    // MARK: watch

    /// Watch the folders the running download fills and turn bytes on disk
    /// into a percentage, plus a smoothed transfer speed for the download
    /// center. The walk happens off the main actor: a model folder holds
    /// thousands of shards and the UI thread has a card to animate.
    private func watch(_ directory: String, engine: EngineID, model: String) {
        if !downloadWatchDirectories.contains(directory) {
            downloadWatchDirectories.append(directory)
        }
        startDownloadWatch(engine: engine, model: model)
    }

    private func startDownloadWatch(engine: EngineID, model: String) {
        downloadWatchTask?.cancel()
        downloadWatchTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let directories = self.downloadWatchDirectories
                let sizes = await Task.detached(priority: .utility) {
                    directories.map { directory in
                        // 只 stat 还在盘上的目录：目标可能被取消/移除删掉了，
                        // 不存在的目录每跳都要白跑一次 FileManager 枚举。
                        Paths.fileExists(directory) ? ModelInstaller.size(of: directory) : 0
                    }
                }.value
                guard !Task.isCancelled else { return }
                // A folder's first sighting sets its baseline, so weights that
                // were already in the cache before this download don't count.
                // The bytes the resumed transfer started with are added back on
                // top: they are part of this model, unlike a foreign cache entry.
                var downloaded = self.downloadResumeBytes
                for (index, directory) in directories.enumerated() {
                    if let baseline = self.downloadWatchBaselines[directory] {
                        downloaded += max(sizes[index] - baseline, 0)
                    } else {
                        self.downloadWatchBaselines[directory] = sizes[index]
                    }
                }
                let now = Date()

                if let last = self.lastWatchDate,
                    now.timeIntervalSince(last) > 0, downloaded > self.lastWatchBytes
                {
                    let instant = Double(downloaded - self.lastWatchBytes) / now.timeIntervalSince(last)
                    self.downloadSpeed =
                        self.lastWatchBytes == 0
                        ? instant
                        : self.downloadSpeed * 0.65 + instant * 0.35
                }
                self.lastWatchBytes = downloaded
                self.lastWatchDate = now
                let total = self.downloadTotalBytes
                if total > 0 {
                    self.downloadFraction = min(max(Double(downloaded) / Double(total), 0), 1)
                }
                self.upsertTask(engine: engine, model: model) { task in
                    task.downloadedBytes = downloaded
                    task.totalBytes = max(task.totalBytes, total)
                }
                do {
                    try await Task.sleep(nanoseconds: Self.watchInterval)
                } catch {
                    // 只有取消会让这里抛错，而取消就是「别再看了」。
                    return
                }
            }
        }
    }

    // MARK: finish

    func finishDownload(engine: EngineID, model: String, status: Int32) {
        let sharedRepo = pendingSharedRepo
        let sharedEngines = pendingSharedEngines
        let incompleteMarker = downloadIncompleteMarker
        downloadIncompleteMarker = nil
        pendingSharedRepo = nil
        pendingSharedEngines = []
        downloadWatchTask?.cancel()
        downloadWatchTask = nil
        downloadProcess = nil
        downloadingModel = nil
        downloadingEngine = nil
        downloadFraction = nil
        downloadTotalBytes = 0
        downloadSpeed = 0
        downloadResumeBytes = 0
        downloadFetchedBytes = 0
        lastWatchBytes = 0
        lastWatchDate = nil
        downloadWatchDirectories = []
        downloadWatchBaselines = [:]
        hooks.reloadModels()

        // A launch may be waiting on this download; it resumes exactly once,
        // whichever branch below ends up running.
        var outcome = DownloadOutcome.failed("下载失败，退出码 \(status)")
        defer {
            let completion = downloadCompletion
            downloadCompletion = nil
            completion?(outcome)
        }

        if pauseRequested {
            pauseRequested = false
            upsertTask(engine: engine, model: model) { $0.status = .paused }
            append("==> 已暂停 \(model)，可从下载中心继续", engine: engine)
            hooks.toast("已暂停下载，进度已保留", true)
            outcome = .cancelled
            return
        }
        if cancelRequested {
            cancelRequested = false
            if removeRequested {
                // 用户点的是删除而不是暂停：行和半成品一起清掉。
                removeRequested = false
                let stale = ModelDownloadTask(
                    engine: engine, model: model, status: .paused,
                    shared: sharedRepo == nil ? nil : sharedEngines)
                removeTask(engine: engine, model: model)
                discardPartialDownload(stale)
                append("==> 已删除下载任务 \(model)，半成品已清理", engine: engine)
                hooks.toast("已从下载中心移除", false)
                outcome = .cancelled
                return
            }
            // Keep the row as paused: the partial bytes and the marker are
            // still on disk, so the model card must keep showing that state
            // instead of flipping back to a clickable "下载". Removing the row
            // is a second, explicit step in the download center.
            upsertTask(engine: engine, model: model) { $0.status = .paused }
            append("==> 已停止下载 \(model)，进度已保留", engine: engine)
            hooks.toast("已停止下载，可在下载中心继续或移除", true)
            outcome = .cancelled
            return
        }

        guard status == 0 else {
            upsertTask(engine: engine, model: model) { $0.status = .failed }
            append("==> 下载失败，退出码 \(status)", engine: engine)
            let message = "模型下载失败，退出码 \(status)（下载中心里可重试）"
            hooks.setNotice(message)
            outcome = .failed(message)
            return
        }

        removeTask(engine: engine, model: model)
        if let incompleteMarker {
            discard(incompleteMarker, why: "下载已完成，清掉半成品标记")
        }
        // The scan at the top of this method still saw the marker; drop the
        // cached byte count and rescan now that the destination is complete,
        // so the card can flip from progress to "使用".
        EngineModelStore.invalidateMetaCache()
        hooks.reloadModels()

        if let sharedRepo {
            append("==> 已下载 \(sharedRepo) 到公共目录", engine: engine)
            outcome = .finished
            onEvent?(.shareRequested(repo: sharedRepo, engines: sharedEngines))
            return
        }

        // Splash addresses a model by its repository id, the packs by the
        // folder name flashCat gave it.
        let repo = model.split(separator: ":", maxSplits: 1).first.map(String.init) ?? model
        let installed =
            engine.adapter == .splash
                || engine.descriptor.modelLayout == .nested
                || engine.descriptor.modelLayout == .external
            ? model
            : ModelInstaller.folderName(for: repo)
        append("==> 已下载 \(model)", engine: engine)
        outcome = .finished
        // 要不要选中它、要不要提示，取决于这次下载是不是启动前的补件、
        // 用户在不在看这个引擎——那些判断留在 AppState，这里只交出事实。
        onEvent?(.modelReady(engine: engine, model: model, installed: installed))
    }

    // MARK: rows

    private func upsertTask(engine: EngineID, model: String, _ mutate: (inout ModelDownloadTask) -> Void) {
        if let index = downloadTasks.firstIndex(where: { $0.engine == engine && $0.model == model }) {
            mutate(&downloadTasks[index])
        } else {
            var task = ModelDownloadTask(engine: engine, model: model, status: .downloading)
            mutate(&task)
            downloadTasks.append(task)
        }
        ModelDownloadStore.save(downloadTasks)
    }

    private func removeTask(engine: EngineID, model: String) {
        downloadTasks.removeAll { $0.engine == engine && $0.model == model }
        ModelDownloadStore.save(downloadTasks)
        // 下载行消失 = 这份权重在磁盘上定形了，下次扫描重新读字节数。
        EngineModelStore.invalidateMetaCache()
    }

    /// Removing a paused/failed row is the explicit "throw the partial bytes
    /// away" action. Only folders still carrying the incomplete marker are
    /// touched, so a finished model that happens to share the id is safe.
    private func discardPartialDownload(_ task: ModelDownloadTask) {
        let path: String
        if let shared = task.shared, !shared.isEmpty {
            path = ModelSharing.path(for: task.model)
        } else if task.engine.adapter == .splash {
            return
        } else {
            path = EnginePaths.modelPath(for: task.engine, model: task.model)
        }
        let marker = ModelInstaller.incompleteMarker(for: path)
        guard Paths.fileExists(marker),
            FlashCatPaths.contains(path, in: EnginePaths.modelsRoot)
        else { return }
        discard(path, why: "清理半成品")
        discard(marker, why: "清理半成品标记")
        EngineModelStore.invalidateMetaCache()
        hooks.reloadModels()
    }

    // MARK: helpers

    /// 删文件的失败不值得打断下载流程（最多是半成品占着磁盘），但也不能静默
    /// 吞掉：写进引擎日志，下次「怎么又多占了几十 G」至少查得到。
    private func discard(_ path: String, why: String) {
        guard Paths.fileExists(path) else { return }
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch {
            append("==> \(why)失败：\(path)（\(error.localizedDescription)）", engine: downloadingEngine)
        }
    }

    /// 日志只有一份出口：外层把它写进对应引擎的日志流，界面上才看得见。
    private func append(_ line: String, engine: EngineID?) {
        hooks.log(line, engine)
    }

    private static func totalBytes(in line: String) -> Int? {
        guard line.hasPrefix("TOTAL ") else { return nil }
        return Int(line.dropFirst(6).trimmingCharacters(in: .whitespaces))
    }

    /// `Fetching 8 file(s), 20.43 GB, from owner/repo@38740b847e4c; cached
    /// files are reused.` — how the Splash installer announces each repository
    /// it is about to fetch, with its exact size (hub.py prints GB as 1e9
    /// bytes). The repo's Hub cache folder is where those bytes land.
    private static func fetchPlan(in line: String) -> (bytes: Int, repo: String)? {
        guard
            let match = TextPattern.firstMatch(
                "Fetching \\d+ file\\(s\\), ([\\d.]+) (GB|MB|KB), from ([^@\\s]+)@", line),
            let value = Double(match[1])
        else { return nil }
        let multiplier: Double
        switch match[2] {
        case "GB": multiplier = 1e9
        case "MB": multiplier = 1e6
        default: multiplier = 1e3
        }
        return (Int((value * multiplier).rounded()), match[3])
    }
}
