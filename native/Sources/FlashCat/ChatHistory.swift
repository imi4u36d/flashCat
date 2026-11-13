import Foundation

struct ChatThread: Identifiable {
    let id: String
    var title: String
    var updatedAt: Date
    var messages: [ChatMessage]
}

/// Sidebar conversation history: newest first, capped at six entries.
final class ChatHistory {
    private let limit = 6

    private struct StoredThread: Codable {
        let id: String
        let title: String
        let updatedAt: Double
        let messages: [StoredMessage]
    }

    private struct StoredMessage: Codable {
        let role: String
        let content: String
        var model: String?
        var createdAt: Double?
        var promptTokens: Int?
        var completionTokens: Int?
        var seconds: Double?
        var tokensPerSecond: Double?
        var firstTokenSeconds: Double?
        /// 思考流与思考时长随线程落盘：重开应用后折叠块仍在，旧回答也还记得
        /// 「思考了 8.4 秒」。两者都是可选的，缺字段的老历史照常解码。
        var reasoning: String?
        var thinkingSeconds: Double?
        /// 这一轮是用户点「停止」收掉的。旧历史没有该字段，解码为 false。
        var interrupted: Bool?
        /// 图像结果：PNG 落在 support/images 下，历史只记路径与那行说明。
        /// 与 interrupted 一样全部可选，缺字段的老历史照常解码。
        var imagePath: String?
        var imageNote: String?
        var imageSourcePath: String?
        var imageStrength: Double?
        var imageSeed: Int?
        /// 一轮工具调用画出的整组图（同一 seed 的系列）。老历史没有这个键，
        /// 解码为 nil，读取时退回单张的 imagePath。
        var imagePaths: [String]?
        /// 工具调用与结果：回放上下文要原样带给引擎，重启后也得能接上。
        var toolCalls: [ChatToolCall]?
        var toolResults: [ChatToolResult]?
        /// 视频结果：MP4 落在 support/videos 下，历史只记路径与说明。
        var videoPath: String?
        var videoNote: String?
        var videoSourcePath: String?
        var videoLastFramePath: String?
        /// REF2VA 的参考素材。旧历史没有这两个键，解码为 nil。
        var videoReferenceImagePaths: [String]?
        var videoReferenceClipPaths: [String]?
    }

    /// 磁盘上线程列表的进程内副本。`load()` 以前每轮回答结束都会重读并
    /// 重新去重整份历史；写入路径会同步更新缓存，读侧因此可以常量时间返回。
    private var cache: [ChatThread]?

    /// `pruneLegacy` 只在启动时打开：旧版本曾把同一段对话按轮次各存一条，
    /// 启动清理一次即可。之后再在每次 `load()` 里跑 O(n²) 的比对没有意义。
    func load(pruneLegacy: Bool = false) -> [ChatThread] {
        if !pruneLegacy, let cache { return cache }
        var threads = loadStored()
        if pruneLegacy {
            let (kept, dropped) = pruned(threads)
            // 清理只在真的摘掉东西时才写盘。
            if dropped { write(kept) }
            threads = kept
        }
        cache = threads
        return threads
    }

    /// 去掉「内容是别人前缀」的旧副本：同一段对话早先几轮存下的短版本。
    /// 内容完全相同的两条按 `updatedAt` 只留较新的那条。
    private func pruned(_ threads: [ChatThread]) -> (kept: [ChatThread], dropped: Bool) {
        func contains(_ short: [ChatMessage], _ long: [ChatMessage]) -> Bool {
            guard short.count <= long.count else { return false }
            return zip(short, long).allSatisfy { $0.role == $1.role && $0.content == $1.content }
        }
        var kept: [ChatThread] = []
        var dropped = false
        for thread in threads {
            let covered = threads.contains { other in
                guard other.id != thread.id, contains(thread.messages, other.messages) else { return false }
                // 更长的版本一定更完整；长度相同则留更新过的那个。
                return other.messages.count > thread.messages.count || other.updatedAt > thread.updatedAt
            }
            if covered { dropped = true } else { kept.append(thread) }
        }
        return (kept, dropped)
    }

    private func loadStored() -> [ChatThread] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: Paths.historyFile)) else {
            return []
        }
        if let stored = try? JSONDecoder().decode([StoredThread].self, from: data) {
            return stored.map { item in
                ChatThread(id: item.id, title: item.title,
                          updatedAt: Date(timeIntervalSince1970: item.updatedAt),
                          messages: item.messages.map { message in
                              let usage = (message.promptTokens != nil || message.completionTokens != nil)
                                  ? ChatUsage(promptTokens: message.promptTokens ?? 0,
                                              completionTokens: message.completionTokens ?? 0)
                                  : nil
                              return ChatMessage(role: message.role, content: message.content,
                                                 model: message.model,
                                                 createdAt: message.createdAt.map { Date(timeIntervalSince1970: $0) },
                                                 usage: usage,
                                                 seconds: message.seconds,
                                                 tokensPerSecond: message.tokensPerSecond,
                                                 firstTokenSeconds: message.firstTokenSeconds,
                                                 thinkingSeconds: message.thinkingSeconds,
                                                 reasoning: message.reasoning,
                                                 interrupted: message.interrupted ?? false,
                                                 imagePath: message.imagePath,
                                                 imageNote: message.imageNote,
                                                 imageSourcePath: message.imageSourcePath,
                                                 imageStrength: message.imageStrength,
                                                 imageSeed: message.imageSeed,
                                                 imagePaths: message.imagePaths ?? [],
                                                 toolCalls: message.toolCalls ?? [],
                                                 toolResults: message.toolResults ?? [],
                                                 videoPath: message.videoPath,
                                                 videoNote: message.videoNote,
                                                 videoSourcePath: message.videoSourcePath,
                                                 videoLastFramePath: message.videoLastFramePath,
                                                 videoReferenceImagePaths: message.videoReferenceImagePaths,
                                                 videoReferenceClipPaths: message.videoReferenceClipPaths)
                          })
            }
        }
        return Self.decodeLegacy(data)
    }

    /// The Flutter client wrote ISO-8601 dates and `text` fields.
    private static func decodeLegacy(_ data: Data) -> [ChatThread] {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return rows.compactMap { row in
            guard let messages = row["messages"] as? [[String: Any]], !messages.isEmpty else { return nil }
            let converted = messages.compactMap { item -> ChatMessage? in
                let role = item["role"] as? String ?? "user"
                let text = (item["text"] as? String) ?? (item["content"] as? String) ?? ""
                guard !text.isEmpty else { return nil }
                var usage: ChatUsage?
                if let tokens = item["tokens"] as? Int, tokens > 0 {
                    usage = ChatUsage(promptTokens: 0, completionTokens: tokens)
                }
                let elapsed = item["elapsed"] as? Double
                let tokens = (item["tokens"] as? Int) ?? 0
                return ChatMessage(role: role, content: text, model: item["model"] as? String,
                                   createdAt: Self.parseLegacyDate(item["createdAt"] as? String),
                                   usage: usage,
                                   seconds: elapsed,
                                   tokensPerSecond: legacyRate(tokens: tokens, elapsed: elapsed),
                                   firstTokenSeconds: (item["ttft"] as? Double).map { $0 / 1000 })
            }
            guard !converted.isEmpty else { return nil }
            let stamp = row["updatedAt"] as? String ?? ""
            return ChatThread(id: row["id"] as? String ?? UUID().uuidString,
                              title: row["title"] as? String ?? "对话",
                              updatedAt: formatter.date(from: stamp) ?? Date(),
                              messages: converted)
        }
    }

    private static func stored(_ message: ChatMessage) -> StoredMessage {
        StoredMessage(role: message.role,
                      content: message.content,
                      model: message.model,
                      createdAt: message.createdAt?.timeIntervalSince1970,
                      promptTokens: message.usage?.promptTokens,
                      completionTokens: message.usage?.completionTokens,
                      seconds: message.seconds,
                      tokensPerSecond: message.tokensPerSecond,
                      firstTokenSeconds: message.firstTokenSeconds,
                      reasoning: message.reasoning,
                      thinkingSeconds: message.thinkingSeconds,
                      interrupted: message.interrupted ? true : nil,
                      imagePath: message.imagePath,
                      imageNote: message.imageNote,
                      imageSourcePath: message.imageSourcePath,
                      imageStrength: message.imageStrength,
                      imageSeed: message.imageSeed,
                      imagePaths: message.imagePaths.isEmpty ? nil : message.imagePaths,
                      toolCalls: message.toolCalls.isEmpty ? nil : message.toolCalls,
                      toolResults: message.toolResults.isEmpty ? nil : message.toolResults,
                      videoPath: message.videoPath,
                      videoNote: message.videoNote,
                      videoSourcePath: message.videoSourcePath,
                      videoLastFramePath: message.videoLastFramePath,
                      videoReferenceImagePaths: message.videoReferenceImagePaths,
                      videoReferenceClipPaths: message.videoReferenceClipPaths)
    }

    static func parseLegacyDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: raw) { return date }
        let plain = DateFormatter()
        plain.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
        return plain.date(from: raw)
    }

    func delete(id: String) {
        var threads = load().filter { $0.id != id }
        threads = Array(threads.prefix(limit))
        write(threads)
    }

    func rename(id: String, title: String) {
        var threads = load()
        guard let index = threads.firstIndex(where: { $0.id == id }) else { return }
        threads[index].title = title
        write(threads)
    }

    /// 历史文件可能越滚越大，序列化和写盘放在主线程会让每轮回答结束时
    /// 顿一下。缓存同步更新，磁盘写入排到串行后台队列，顺序保持不变。
    private let writeQueue = DispatchQueue(label: "com.zhuo.flashCat.chat-history",
                                           qos: .utility)

    private func write(_ threads: [ChatThread]) {
        cache = threads
        let stored = threads.map { thread in
            StoredThread(id: thread.id, title: thread.title,
                         updatedAt: thread.updatedAt.timeIntervalSince1970,
                         messages: thread.messages.map(Self.stored))
        }
        writeQueue.async {
            Paths.ensureDirectory(Paths.supportDirectory)
            if let data = try? JSONEncoder().encode(stored) {
                try? data.write(to: URL(fileURLWithPath: Paths.historyFile))
            }
        }
    }

    /// 退出前等所有挂起的写盘完成，避免最后一条回答丢在队列里。
    func flushPendingWrites() {
        writeQueue.sync {}
    }

    /// 落盘的对话只收已经收尾的消息。被「停止」的空回答也要留下——否则
    /// 答案一删，历史里就只剩一句没有回应的提问。
    static func savable(_ messages: [ChatMessage]) -> [ChatMessage] {
        // 图像/视频消息的正文是空的：媒体在 imagePath/videoPath 里，不能按文本判空丢掉。
        messages.filter {
            !$0.streaming && (!$0.content.isEmpty || $0.interrupted
                              || $0.imagePath != nil || !$0.imagePaths.isEmpty
                              || !$0.toolCalls.isEmpty
                              || $0.videoPath != nil
                              || $0.videoLastFramePath != nil
                              || !($0.videoReferenceImagePaths ?? []).isEmpty
                              || !($0.videoReferenceClipPaths ?? []).isEmpty)
        }
    }

    /// 同一段对话只占一条：`threadID` 已存在就原地覆盖并提到最前，只有新会话
    /// 才 insert。以前这里无条件 insert 新 id，而每轮生成结束都会调一次，于是
    /// 一段三轮对话会在「最近对话」里留下 6/8 两条、侧栏看起来像两段。
    func save(messages: [ChatMessage], threadID: String) {
        let completed = Self.savable(messages)
        guard !completed.isEmpty else { return }

        var threads = load()
        let firstUser = completed.first(where: { $0.role == "user" })?.content ?? "未命名对话"
        let title = firstUser.split(separator: "\n").first.map(String.init) ?? "未命名对话"

        if let index = threads.firstIndex(where: { $0.id == threadID }) {
            threads.remove(at: index)
        }
        threads.insert(ChatThread(id: threadID, title: title, updatedAt: Date(),
                                  messages: completed), at: 0)
        write(Array(threads.prefix(limit)))
    }
}

/// The conversation currently open in the chat pane. Kept separate from the
/// history list so a restart of the app resumes the same context.
final class ConversationStore {
    private struct StoredMessage: Codable {
        let role: String
        let content: String
        let promptTokens: Int?
        let completionTokens: Int?
        let seconds: Double?
        let tokensPerSecond: Double?
        let firstTokenSeconds: Double?
        let model: String?
        let createdAt: Double?
        let reasoning: String?
        let thinkingSeconds: Double?
        let interrupted: Bool?
        let imagePath: String?
        let imageNote: String?
        let imageSourcePath: String?
        let imageStrength: Double?
        let imageSeed: Int?
        let imagePaths: [String]?
        let toolCalls: [ChatToolCall]?
        let toolResults: [ChatToolResult]?
        let videoPath: String?
        let videoNote: String?
        let videoSourcePath: String?
        let videoLastFramePath: String?
        let videoReferenceImagePaths: [String]?
        let videoReferenceClipPaths: [String]?
    }

    func load() -> [ChatMessage] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: Paths.conversationFile)) else {
            return []
        }
        guard let stored = try? JSONDecoder().decode([StoredMessage].self, from: data) else {
            return Self.decodeLegacy(data)
        }
        return stored.map { item in
            let usage = (item.promptTokens != nil || item.completionTokens != nil)
                ? ChatUsage(promptTokens: item.promptTokens ?? 0, completionTokens: item.completionTokens ?? 0)
                : nil
            return ChatMessage(role: item.role, content: item.content, model: item.model,
                               createdAt: item.createdAt.map { Date(timeIntervalSince1970: $0) },
                               usage: usage,
                               seconds: item.seconds,
                               tokensPerSecond: item.tokensPerSecond,
                               firstTokenSeconds: item.firstTokenSeconds,
                               thinkingSeconds: item.thinkingSeconds,
                               reasoning: item.reasoning,
                               interrupted: item.interrupted ?? false,
                               imagePath: item.imagePath,
                               imageNote: item.imageNote,
                               imageSourcePath: item.imageSourcePath,
                               imageStrength: item.imageStrength,
                               imageSeed: item.imageSeed,
                               imagePaths: item.imagePaths ?? [],
                               toolCalls: item.toolCalls ?? [],
                               toolResults: item.toolResults ?? [],
                               videoPath: item.videoPath,
                               videoNote: item.videoNote,
                               videoSourcePath: item.videoSourcePath,
                               videoLastFramePath: item.videoLastFramePath,
                               videoReferenceImagePaths: item.videoReferenceImagePaths,
                               videoReferenceClipPaths: item.videoReferenceClipPaths)
        }
    }

    /// The Flutter client stored `text`/`tokens`/`elapsed`/`ttft` instead.
    private static func decodeLegacy(_ data: Data) -> [ChatMessage] {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            let role = row["role"] as? String ?? "user"
            let text = (row["text"] as? String) ?? (row["content"] as? String) ?? ""
            guard !text.isEmpty else { return nil }
            var usage: ChatUsage?
            if let tokens = row["tokens"] as? Int, tokens > 0 {
                usage = ChatUsage(promptTokens: 0, completionTokens: tokens)
            }
            let elapsed = row["elapsed"] as? Double
            let tokens = (row["tokens"] as? Int) ?? 0
            return ChatMessage(role: role, content: text, model: row["model"] as? String,
                               createdAt: ChatHistory.parseLegacyDate(row["createdAt"] as? String),
                               usage: usage,
                               seconds: elapsed,
                               tokensPerSecond: legacyRate(tokens: tokens, elapsed: elapsed),
                               firstTokenSeconds: (row["ttft"] as? Double).map { $0 / 1000 })
        }
    }

    private let writeQueue = DispatchQueue(label: "com.zhuo.flashCat.conversation",
                                           qos: .utility)

    func save(_ messages: [ChatMessage]) {
        let stored = messages.filter { !$0.streaming }.map { message in
            StoredMessage(role: message.role, content: message.content,
                          promptTokens: message.usage?.promptTokens,
                          completionTokens: message.usage?.completionTokens,
                          seconds: message.seconds,
                          tokensPerSecond: message.tokensPerSecond,
                          firstTokenSeconds: message.firstTokenSeconds,
                          model: message.model,
                          createdAt: message.createdAt?.timeIntervalSince1970,
                          reasoning: message.reasoning,
                          thinkingSeconds: message.thinkingSeconds,
                          interrupted: message.interrupted ? true : nil,
                          imagePath: message.imagePath,
                          imageNote: message.imageNote,
                          imageSourcePath: message.imageSourcePath,
                          imageStrength: message.imageStrength,
                          imageSeed: message.imageSeed,
                          imagePaths: message.imagePaths.isEmpty ? nil : message.imagePaths,
                          toolCalls: message.toolCalls.isEmpty ? nil : message.toolCalls,
                          toolResults: message.toolResults.isEmpty ? nil : message.toolResults,
                          videoPath: message.videoPath,
                          videoNote: message.videoNote,
                          videoSourcePath: message.videoSourcePath,
                          videoLastFramePath: message.videoLastFramePath,
                          videoReferenceImagePaths: message.videoReferenceImagePaths,
                          videoReferenceClipPaths: message.videoReferenceClipPaths)
        }
        guard !stored.isEmpty else { return }
        writeQueue.async {
            Paths.ensureDirectory(Paths.supportDirectory)
            if let data = try? JSONEncoder().encode(stored) {
                try? data.write(to: URL(fileURLWithPath: Paths.conversationFile))
            }
        }
    }

    func clear() {
        // 走同一条队列：先前的 save 必须先落盘，再删文件，顺序不能反。
        writeQueue.async {
            try? FileManager.default.removeItem(atPath: Paths.conversationFile)
        }
    }

    /// 退出前等所有挂起的写盘完成。
    func flushPendingWrites() {
        writeQueue.sync {}
    }
}

/// Tokens per second from the legacy `elapsed` field. A missing or zero
/// duration means "not measured", not a division by zero.
private func legacyRate(tokens: Int, elapsed: Double?) -> Double? {
    guard let elapsed, elapsed > 0, tokens > 0 else { return nil }
    return Double(tokens) / elapsed
}
