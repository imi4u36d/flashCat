// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import Foundation

package struct ChatThread: Identifiable, Equatable {
    package let id: String
    package var title: String
    package var updatedAt: Date
    /// 置顶到「最近对话」最上方的时间；nil 表示未置顶。置顶是会话属性，
    /// 跟标题一起落盘，重启后仍然有效。
    package var pinnedAt: Date? = nil
    package var messages: [ChatMessage]

    package init(id: String, title: String, updatedAt: Date, pinnedAt: Date? = nil, messages: [ChatMessage]) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
        self.pinnedAt = pinnedAt
        self.messages = messages
    }

    package var pinned: Bool { pinnedAt != nil }
}

/// Sidebar conversation history: newest first. The limit is only a guard against
/// an unbounded history file — it is high enough that the list behaves like a
/// normal chat app, not a six-item shelf.
package final class ChatHistory {
    package static let limit = 200

    /// 写盘失败必须能被看见：历史是用户找回上一轮回答的唯一途径，静默失败
    /// 等于「保存成功」的假象。这里注入闭包而不是直接持有 LogStore，是因为
    /// 写盘发生在后台串行队列上，而 LogStore 归 AppState 所有，两者不该互相耦合。
    private let onWriteFailure: (@Sendable (String) -> Void)?
    private let filePath: String

    package init(
        onWriteFailure: (@Sendable (String) -> Void)? = nil,
        filePath: String = Paths.historyFile
    ) {
        self.onWriteFailure = onWriteFailure
        self.filePath = filePath
    }

    /// 测试用：等串行写队列排空。生产代码不需要主动等待。
    package func waitForWrites() {
        writeQueue.sync {}
    }

    private struct StoredThread: Codable {
        let id: String
        let title: String
        let updatedAt: Double
        /// 老历史没有这个键，解码为 nil（未置顶）。
        var pinnedAt: Double?
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
        /// 用户聊天附件：气泡里显示的附件名、带文件上下文的引擎正文、
        /// 以及视觉模型追问时要重新挂上的图片路径。旧历史缺这三个键照常解码。
        var attachmentNames: [String]?
        var engineContent: String?
        var userImagePaths: [String]?
    }

    /// 磁盘上线程列表的进程内副本。`load()` 以前每轮回答结束都会重读并
    /// 重新去重整份历史；写入路径会同步更新缓存，读侧因此可以常量时间返回。
    private var cache: [ChatThread]?

    /// `pruneLegacy` 只在启动时打开：旧版本曾把同一段对话按轮次各存一条，
    /// 启动清理一次即可。之后再在每次 `load()` 里跑 O(n²) 的比对没有意义。
    package func load(pruneLegacy: Bool = false) -> [ChatThread] {
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
            return zip(short, long).allSatisfy {
                $0.role == $1.role && $0.content == $1.content
                    && $0.engineContent == $1.engineContent
            }
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
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)) else {
            return []
        }
        if let stored = try? JSONDecoder().decode([StoredThread].self, from: data) {
            return stored.map { item in
                ChatThread(
                    id: item.id, title: item.title,
                    updatedAt: Date(timeIntervalSince1970: item.updatedAt),
                    pinnedAt: item.pinnedAt.map { Date(timeIntervalSince1970: $0) },
                    messages: item.messages.map { message in
                        let usage =
                            (message.promptTokens != nil || message.completionTokens != nil)
                            ? ChatUsage(
                                promptTokens: message.promptTokens ?? 0,
                                completionTokens: message.completionTokens ?? 0)
                            : nil
                        return ChatMessage(
                            role: message.role, content: message.content,
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
                            videoReferenceClipPaths: message.videoReferenceClipPaths,
                            attachmentNames: message.attachmentNames ?? [],
                            engineContent: message.engineContent,
                            userImagePaths: message.userImagePaths ?? [])
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
                return ChatMessage(
                    role: role, content: text, model: item["model"] as? String,
                    createdAt: Self.parseLegacyDate(item["createdAt"] as? String),
                    usage: usage,
                    seconds: elapsed,
                    tokensPerSecond: legacyRate(tokens: tokens, elapsed: elapsed),
                    firstTokenSeconds: (item["ttft"] as? Double).map { $0 / 1000 })
            }
            guard !converted.isEmpty else { return nil }
            let stamp = row["updatedAt"] as? String ?? ""
            return ChatThread(
                id: row["id"] as? String ?? UUID().uuidString,
                title: row["title"] as? String ?? "对话",
                updatedAt: formatter.date(from: stamp) ?? Date(),
                messages: converted)
        }
    }

    private static func stored(_ message: ChatMessage) -> StoredMessage {
        StoredMessage(
            role: message.role,
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
            videoReferenceClipPaths: message.videoReferenceClipPaths,
            attachmentNames: message.attachmentNames.isEmpty ? nil : message.attachmentNames,
            engineContent: message.engineContent,
            userImagePaths: message.userImagePaths.isEmpty ? nil : message.userImagePaths)
    }

    package static func parseLegacyDate(_ raw: String?) -> Date? {
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

    package func delete(id: String) {
        var threads = load().filter { $0.id != id }
        threads = Array(threads.prefix(Self.limit))
        write(threads)
    }

    package func rename(id: String, title: String) {
        var threads = load()
        guard let index = threads.firstIndex(where: { $0.id == id }) else { return }
        threads[index].title = title
        write(threads)
    }

    /// 置顶 / 取消置顶。置顶时间决定同一分组里的先后：最后置顶的排最前，
    /// 和 Splash 的 `pinned ?? .distantPast` 排序一致。
    package func pin(id: String, _ pinned: Bool, at date: Date = Date()) {
        var threads = load()
        guard let index = threads.firstIndex(where: { $0.id == id }) else { return }
        threads[index].pinnedAt = pinned ? date : nil
        write(threads)
    }

    /// 历史文件可能越滚越大，序列化和写盘放在主线程会让每轮回答结束时
    /// 顿一下。缓存同步更新，磁盘写入排到串行后台队列，顺序保持不变。
    private let writeQueue = DispatchQueue(
        label: "com.zhuo.flashCat.chat-history",
        qos: .utility)

    private func write(_ threads: [ChatThread]) {
        cache = threads
        let stored = threads.map { thread in
            StoredThread(
                id: thread.id, title: thread.title,
                updatedAt: thread.updatedAt.timeIntervalSince1970,
                pinnedAt: thread.pinnedAt?.timeIntervalSince1970,
                messages: thread.messages.map(Self.stored))
        }
        let sink = onWriteFailure
        writeQueue.async {
            Paths.ensureDirectory(Paths.supportDirectory)
            do {
                let data = try JSONEncoder().encode(stored)
                try data.write(to: URL(fileURLWithPath: self.filePath))
            } catch {
                sink?("讨论列表保存失败（\(self.filePath)）：\(error.localizedDescription)")
            }
        }
    }

    /// 退出前等所有挂起的写盘完成，避免最后一条回答丢在队列里。
    package func flushPendingWrites() {
        writeQueue.sync {}
    }

    /// 落盘的对话只收已经收尾的消息。被「停止」的空回答也要留下——否则
    /// 答案一删，历史里就只剩一句没有回应的提问。
    package static func savable(_ messages: [ChatMessage]) -> [ChatMessage] {
        // 图像/视频消息的正文是空的：媒体在 imagePath/videoPath 里，不能按文本判空丢掉。
        messages.filter {
            !$0.streaming
                && (!$0.content.isEmpty || $0.interrupted
                    || !$0.attachmentNames.isEmpty
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
    package func save(messages: [ChatMessage], threadID: String, updatedAt: Date = Date()) {
        let completed = Self.savable(messages)
        guard !completed.isEmpty else { return }

        var threads = load()
        let existing = threads.first(where: { $0.id == threadID })
        // 用户改过名、置过顶的会话在每轮保存后仍然是那个名字、那个位置：
        // 以前这里每轮都按首句重算标题，改名刚生效就被下一轮回答覆盖。
        let title =
            existing.flatMap { $0.title.isEmpty ? nil : $0.title }
            ?? Self.autoTitle(messages: completed)

        if let index = threads.firstIndex(where: { $0.id == threadID }) {
            threads.remove(at: index)
        }
        threads.insert(
            ChatThread(
                id: threadID, title: title, updatedAt: updatedAt,
                pinnedAt: existing?.pinnedAt, messages: completed),
            at: 0)
        write(Array(threads.prefix(Self.limit)))
    }

    /// 新会话的默认标题：第一条用户消息的第一行。
    package static func autoTitle(messages: [ChatMessage]) -> String {
        let firstUser = messages.first(where: { $0.role == "user" })?.content ?? "未命名对话"
        return firstUser.split(separator: "\n").first.map(String.init) ?? "未命名对话"
    }
}

/// The conversation currently open in the chat pane. Kept separate from the
/// history list so a restart of the app resumes the same context.
package final class ConversationStore {
    /// 与 `ChatHistory` 同理：对话记录是整个会话的唯一持久副本，写失败必须能被看见。
    private let onWriteFailure: (@Sendable (String) -> Void)?
    private let filePath: String

    package init(
        onWriteFailure: (@Sendable (String) -> Void)? = nil,
        filePath: String = Paths.conversationFile
    ) {
        self.onWriteFailure = onWriteFailure
        self.filePath = filePath
    }

    /// 测试用：等串行写队列排空。生产代码不需要主动等待。
    package func waitForWrites() {
        writeQueue.sync {}
    }

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
        let attachmentNames: [String]?
        let engineContent: String?
        let userImagePaths: [String]?
    }

    package func load() -> [ChatMessage] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)) else {
            return []
        }
        guard let stored = try? JSONDecoder().decode([StoredMessage].self, from: data) else {
            return Self.decodeLegacy(data)
        }
        return stored.map { item in
            let usage =
                (item.promptTokens != nil || item.completionTokens != nil)
                ? ChatUsage(promptTokens: item.promptTokens ?? 0, completionTokens: item.completionTokens ?? 0)
                : nil
            return ChatMessage(
                role: item.role, content: item.content, model: item.model,
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
                videoReferenceClipPaths: item.videoReferenceClipPaths,
                attachmentNames: item.attachmentNames ?? [],
                engineContent: item.engineContent,
                userImagePaths: item.userImagePaths ?? [])
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
            return ChatMessage(
                role: role, content: text, model: row["model"] as? String,
                createdAt: ChatHistory.parseLegacyDate(row["createdAt"] as? String),
                usage: usage,
                seconds: elapsed,
                tokensPerSecond: legacyRate(tokens: tokens, elapsed: elapsed),
                firstTokenSeconds: (row["ttft"] as? Double).map { $0 / 1000 })
        }
    }

    private let writeQueue = DispatchQueue(
        label: "com.zhuo.flashCat.conversation",
        qos: .utility)

    package func save(_ messages: [ChatMessage]) {
        let stored = messages.filter { !$0.streaming }.map { message in
            StoredMessage(
                role: message.role, content: message.content,
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
                videoReferenceClipPaths: message.videoReferenceClipPaths,
                attachmentNames: message.attachmentNames.isEmpty ? nil : message.attachmentNames,
                engineContent: message.engineContent,
                userImagePaths: message.userImagePaths.isEmpty ? nil : message.userImagePaths)
        }
        guard !stored.isEmpty else { return }
        let sink = onWriteFailure
        writeQueue.async {
            Paths.ensureDirectory(Paths.supportDirectory)
            do {
                let data = try JSONEncoder().encode(stored)
                try data.write(to: URL(fileURLWithPath: self.filePath))
            } catch {
                sink?("对话记录保存失败（\(self.filePath)）：\(error.localizedDescription)")
            }
        }
    }

    package func clear() {
        // 走同一条队列：先前的 save 必须先落盘，再删文件，顺序不能反。
        let sink = onWriteFailure
        writeQueue.async {
            do {
                try FileManager.default.removeItem(atPath: self.filePath)
            } catch let error as NSError
                where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError
            {
                // 文件本来就不存在时删除会报错，这种失败等价于成功。
            } catch {
                sink?("清空对话记录失败：\(error.localizedDescription)")
            }
        }
    }

    /// 退出前等所有挂起的写盘完成。
    package func flushPendingWrites() {
        writeQueue.sync {}
    }
}

/// Tokens per second from the legacy `elapsed` field. A missing or zero
/// duration means "not measured", not a division by zero.
private func legacyRate(tokens: Int, elapsed: Double?) -> Double? {
    guard let elapsed, elapsed > 0, tokens > 0 else { return nil }
    return Double(tokens) / elapsed
}
