// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import Foundation
import Network

/// 一条解析好的入站请求。头部名统一转小写；`path` 里不含查询串（拆开的键值放在
/// `query` 里）。
public struct GatewayRequest: Sendable {
    public let method: String
    public let path: String
    public let query: [String: String]
    public let headers: [String: String]
    public let body: Data

    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    /// 请求带着官方 SDK 必发的头，就说明它说的是 Anthropic 方言。`GET /v1/models`
    /// 是两种方言共用的唯一路由，所以要看头来决定回答按哪种形状给出。
    public var isAnthropicStyle: Bool {
        header("x-api-key") != nil || header("anthropic-version") != nil
    }
}

/// 路由给出的回答。JSON 响应一次性写完；SSE 响应则把一个会话交给路由，由它往里
/// 推事件，直到上游（或客户端）结束。
/// 这个值从路由（可能跳到主 actor 上）交回连接队列。构造好之后载荷不再变，唯一
/// 不是 Sendable 的成员是那个可选的流式闭包；两端都由服务端持有，所以
/// `@unchecked` 是对这次交接的如实描述。
public struct GatewayResponse: @unchecked Sendable {
    public var status: Int = 200
    public var contentType: String = "application/json"
    public var headers: [String: String] = [:]
    public var body: Data = Data()
    /// 设好之后忽略 `body`，改由这个闭包流式写出响应。
    public var stream: ((GatewaySSESession) async -> Void)? = nil

    public init() {}

    public static func json(_ object: Any, status: Int = 200) -> GatewayResponse {
        var response = GatewayResponse()
        response.status = status
        response.body = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return response
    }

    public static func sse(_ producer: @escaping (GatewaySSESession) async -> Void) -> GatewayResponse {
        var response = GatewayResponse()
        response.contentType = "text/event-stream"
        response.headers["Cache-Control"] = "no-cache"
        response.stream = producer
        return response
    }
}

/// 一次性的 `CheckedContinuation` 闸门。
///
/// 重复恢复一个 checked continuation 会 trap，一直不恢复又会把调用方永远挂住——
/// 这两件事以前都在 `start` 里出现过：`.ready` 与 `.failed` 各恢复一次，而
/// `.cancelled`（端口绑不上时实际会产生的状态）一次都没有恢复。这里的每次等待都
/// 可能被好几条互不相干的路径唤醒（状态迁移、发送完成、截止定时器），所以只允许
/// 其中一条赢。
private final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    /// 本次调用真的执行了恢复才返回 true；之后的调用都是空操作。
    @discardableResult
    func resume(_ value: Value) -> Bool {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return false
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(returning: value)
        return true
    }
}

/// 一条流式响应的写端。客户端一走 `write` 就返回 false，产出方因此会停手，不再
/// 继续翻译一条没人读的上游流。
public final class GatewaySSESession: @unchecked Sendable {
    private let lock = NSLock()
    private weak var connection: NWConnection?
    private var closed = false
    /// 已交给 socket、但还没被 `contentProcessed` 确认的帧数。非零表示结尾那一帧
    /// （`data: [DONE]` / `message_stop`）还在路上。
    private var pendingSends = 0
    private var flushWaiters: [ResumeOnce<Void>] = []

    public init(connection: NWConnection) {
        self.connection = connection
    }

    public var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    /// 写一帧 Server-Sent-Events。NWConnection 按 FIFO 处理 send，所以帧序天然
    /// 保持，不需要额外同步。客户端断开后返回 false，产出方应当停手。
    @discardableResult
    public func write(_ text: String) -> Bool {
        lock.lock()
        guard !closed, let connection else {
            lock.unlock()
            return false
        }
        pendingSends += 1
        lock.unlock()
        connection.send(
            content: Data(text.utf8),
            completion: .contentProcessed { [weak self] error in
                self?.noteSendFinished(error: error)
            })
        return !isClosed
    }

    @discardableResult
    public func writeEvent(name: String? = nil, data: String, id: String? = nil) -> Bool {
        var frame = ""
        if let id { frame += "id: \(id)\n" }
        if let name { frame += "event: \(name)\n" }
        for line in data.split(separator: "\n", omittingEmptySubsequences: false) {
            frame += "data: \(line)\n"
        }
        frame += "\n"
        return write(frame)
    }

    public func close() { markClosed() }

    /// 等到已经交给 `write` 的帧全部抵达 socket，或者 `timeout` 到点（默认 2 秒）。
    ///
    /// 产出方一返回，服务端立刻关连接，而它写的最后一帧就是客户端唯一的「这次答案
    /// 完了」信号。这里替掉的固定 `sleep(80ms)`，只要 socket 比定时器慢就会把那一帧
    /// 丢掉，客户端只好干等自己的超时。`NWConnection` 按顺序处理 send，所以「最后
    /// 一次 `contentProcessed` 触发了」就等于结尾帧已经发出。超时是为了不让一个
    /// 半死的 socket 把响应任务钉住；反正调用方随后会 `cancel()` 把队列冲掉。
    func flush(timeout: TimeInterval = 2) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let gate = ResumeOnce(continuation)
            lock.lock()
            let idle = pendingSends == 0
            if !idle { flushWaiters.append(gate) }
            lock.unlock()
            if idle {
                gate.resume(())
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                gate.resume(())
            }
        }
    }

    private func noteSendFinished(error: Error?) {
        lock.lock()
        if error != nil { closed = true }
        pendingSends = max(0, pendingSends - 1)
        let waiters = pendingSends == 0 ? flushWaiters : []
        if pendingSends == 0 { flushWaiters.removeAll(keepingCapacity: true) }
        lock.unlock()
        for waiter in waiters { waiter.resume(()) }
    }

    private func markClosed() {
        lock.lock()
        closed = true
        lock.unlock()
    }
}

/// 本地网关用的最小 HTTP/1.1 服务端。只监听回环、只有一个路由处理器、支持
/// keep-alive，协议实现刚好够 OpenAI / Anthropic SDK 客户端用：请求行、请求头、
/// Content-Length 正文，以及流式 `text/event-stream` 回答。
/// `@unchecked Sendable`：每个可变字段要么不可变（`handler`），要么由 `lock`
/// 保护；listener 与连接只在 `queue` 上碰。所以连接回调在队列之间跳是安全的。
public final class GatewayHTTPServer: @unchecked Sendable {
    /// 正文超过这个值就回 413 拒绝——这些是聊天调用，连一批 base64 图片也远低于
    /// 上限。
    public static let maximumBodyBytes = 128 * 1024 * 1024

    /// 请求头超过这个值就拒绝（回 400）。不设上限的话，一个只发头字节、永不结束
    /// 这个块的客户端会把接收缓冲一路撑大，直到网关内存耗尽。
    public static let maximumHeadBytes = 64 * 1024

    /// `start` 等 listener 报出终态的最长时间。`NWListener` 偶尔既不报 `.ready`
    /// 也不报失败（端口卡在半开状态、描述符耗尽）；没有截止时间的话，一次坏的启动
    /// 就能把网关挂到应用重启。
    private static let startTimeout: TimeInterval = 2

    public typealias Handler = @Sendable (GatewayRequest) async -> GatewayResponse

    private let handler: Handler
    private let queue = DispatchQueue(label: "flashcat.gateway.server")
    private var listener: NWListener?
    private var port: UInt16 = 0
    private let lock = NSLock()
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    public var boundPort: UInt16 {
        lock.lock()
        defer { lock.unlock() }
        return port
    }

    /// `NSLock.lock()` 在 async 函数里不能直接用；走这层同步跳板，让写入落在
    /// `boundPort` 读取用的同一把锁下。
    private func setBoundPort(_ value: UInt16) {
        lock.lock()
        defer { lock.unlock() }
        port = value
    }

    /// 绑定 127.0.0.1:`port`，等 listener 就绪（true）或失败（false，例如端口已
    /// 被占用）后返回。
    public func start(port: UInt16) async -> Bool {
        guard let endpoint = NWEndpoint.Port(rawValue: port) else { return false }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: endpoint)
        parameters.allowLocalEndpointReuse = true
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            return false
        }

        setBoundPort(port)
        let timeout = Self.startTimeout
        let ready = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let gate = ResumeOnce(continuation)
            // 每个终态都必须恰好恢复一次，而且由闸门、而不是状态名来决定谁赢：
            // `.ready` 之后还可能来 `.failed`/`.cancelled`（listener 起来后又死掉）。
            // `.waiting` 表示端点暂时绑不上；只监听回环的 listener 没有网络可等，
            // 所以把它当失败处理，而不是一直挂到截止时间。
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: gate.resume(true)
                case .failed, .cancelled, .waiting: gate.resume(false)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            lock.lock()
            self.listener = listener
            lock.unlock()
            listener.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                gate.resume(false)
            }
        }
        guard ready else {
            // 每条失败路径都要释放 listener：留在 `.waiting` 的那个会把端口一直占
            // 着，下一次 start 也会跟着失败。
            stop()
            return false
        }
        return true
    }

    /// 停止接受新连接并丢掉所有连接。重复调用、或 `start` 失败后调用都安全；
    /// 停止之后 `boundPort` 报 0。
    public func stop() {
        lock.lock()
        listener?.cancel()
        listener = nil
        port = 0
        let all = connections
        connections.removeAll()
        lock.unlock()
        for (_, connection) in all { connection.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        let identifier = ObjectIdentifier(connection)
        lock.lock()
        connections[identifier] = connection
        lock.unlock()

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .failed, .cancelled:
                self.lock.lock()
                self.connections.removeValue(forKey: ObjectIdentifier(connection))
                self.lock.unlock()
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveRequest(connection, progress: ReadProgress())
    }

    // MARK: request reading（请求读取）

    /// 一条请求的读取状态，跨多次 `receive` 回调携带。
    private struct ReadProgress {
        var buffer = Data()
        /// `100 Continue` 每条请求只回一次，不随每次 `receive` 回调重发。
        var acknowledgedContinue = false
    }

    /// 一条请求解析出来的请求行与请求头。
    private struct RequestHead {
        let method: String
        let path: String
        let query: [String: String]
        let headers: [String: String]

        /// `Expect: 100-continue` 要求服务端在正文发出前先应一声；否则 SDK 客户端
        /// 会一直阻塞到自己的超时。
        var expectsContinue: Bool {
            (headers["expect"] ?? "").lowercased() == "100-continue"
        }
    }

    /// 在接收缓冲里找请求头的结果。
    private enum HeadParse {
        /// 还没出现 `\r\n\r\n`：调用方继续读。
        case incomplete
        /// 确定不是这个服务端能回答的请求；回 400 并关连接。
        case invalid(String)
        case complete(RequestHead, contentLength: Int, bodyOffset: Int)
    }

    private func receiveRequest(_ connection: NWConnection, progress: ReadProgress) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            var progress = progress
            if let data { progress.buffer.append(data) }

            switch Self.parseHead(progress.buffer) {
            case .invalid(let message):
                self.writeSimpleResponse(connection, status: 400, body: Self.errorBody(message))
                return
            case .incomplete:
                guard progress.buffer.count <= Self.maximumHeadBytes else {
                    self.writeSimpleResponse(
                        connection, status: 400,
                        body: Self.errorBody("request head exceeds \(Self.maximumHeadBytes) bytes"))
                    return
                }
            case .complete(let head, let contentLength, let bodyOffset):
                guard contentLength <= Self.maximumBodyBytes else {
                    self.writeSimpleResponse(
                        connection, status: 413,
                        body: #"{"error":{"message":"request body too large"}}"#)
                    return
                }
                if head.expectsContinue, !progress.acknowledgedContinue {
                    // 客户端在等这一行，收到之后才肯发正文。
                    progress.acknowledgedContinue = true
                    self.write(connection, data: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8)) { _ in }
                }
                let start = progress.buffer.startIndex
                let bodyStart = start + bodyOffset
                guard progress.buffer.count - bodyOffset >= contentLength else {
                    // 正文还没收全。
                    self.receiveRequest(connection, progress: progress)
                    return
                }
                let body = progress.buffer.subdata(in: bodyStart..<(bodyStart + contentLength))
                let rest = progress.buffer.count - bodyOffset - contentLength
                self.dispatch(
                    connection,
                    head: head,
                    body: body,
                    leftover: rest > 0
                        ? progress.buffer.subdata(in: (bodyStart + contentLength)..<progress.buffer.endIndex)
                        : Data())
                return
            }

            if error != nil || isComplete {
                if !progress.buffer.isEmpty {
                    connection.cancel()
                }
                return
            }
            self.receiveRequest(connection, progress: progress)
        }
    }

    /// 请求头块完整时把它从缓冲里切出来。
    private static func parseHead(_ buffer: Data) -> HeadParse {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = buffer.range(of: separator) else { return .incomplete }
        let bodyOffset = range.upperBound - buffer.startIndex
        // 不是 UTF-8 的请求头不可能是本服务端能路由的请求行。以前这种请求会当成
        // 空 method/path 落下去、回一个 404，等于用一个看起来像样的回答把坏客户端
        // 藏了起来。
        guard let text = String(data: buffer[buffer.startIndex..<range.lowerBound], encoding: .utf8) else {
            return .invalid("request head is not valid UTF-8")
        }
        var lines = text.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst()
        let parts = requestLine.split(separator: " ")
        // `METHOD SP TARGET SP HTTP/1.1`：少于两段就没有 method 可分发，也没有
        // target 可路由。
        guard parts.count >= 2 else { return .invalid("malformed request line") }
        let method = String(parts[0]).uppercased()
        let target = String(parts[1])
        guard !method.isEmpty, !target.isEmpty else { return .invalid("malformed request line") }
        let (path, query) = splitTarget(target)

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { headers[name] = value }
        }
        // 分块正文不带 Content-Length：长度只有边读边算才知道，而本服务端要把整块
        // 正文缓冲起来。回 400 是如实的结果——以前按零字节正文处理，交给路由的是
        // 一份看起来完整、其实为空的载荷。
        if let transferEncoding = headers["transfer-encoding"],
            transferEncoding.lowercased() != "identity"
        {
            return .invalid("unsupported transfer-encoding: \(transferEncoding)")
        }
        let contentLength: Int
        if let raw = headers["content-length"] {
            guard let parsed = Int(raw), parsed >= 0 else { return .invalid("invalid content-length") }
            contentLength = parsed
        } else {
            contentLength = 0
        }
        let head = RequestHead(method: method, path: path, query: query, headers: headers)
        return .complete(head, contentLength: contentLength, bodyOffset: bodyOffset)
    }

    private static func splitTarget(_ target: String) -> (String, [String: String]) {
        guard let question = target.firstIndex(of: "?") else { return (target, [:]) }
        let path = String(target[..<question])
        var query: [String: String] = [:]
        let queryString = target[target.index(after: question)...]
        for pair in queryString.split(separator: "&") {
            let equals = pair.firstIndex(of: "=")
            let name = equals.map { String(pair[..<$0]) } ?? String(pair)
            let value = equals.map { String(pair[pair.index(after: $0)...]) } ?? ""
            query[name.removingPercentEncoding ?? name] = value.removingPercentEncoding ?? value
        }
        return (path, query)
    }

    // MARK: response writing（响应写出）

    private func dispatch(
        _ connection: NWConnection,
        head: RequestHead,
        body: Data,
        leftover: Data
    ) {
        let request = GatewayRequest(
            method: head.method,
            path: head.path,
            query: head.query,
            headers: head.headers,
            body: body)
        let keepAlive = (head.headers["connection"] ?? "").lowercased() != "close"
        Task { [weak self] in
            guard let self else { return }
            let response = await self.handler(request)
            await self.respond(connection, response: response, keepAlive: keepAlive)
            // 同一条 socket 上的下一条请求——只对缓冲响应成立；流式回答在产出方
            // 结束时就把连接关了。
            if keepAlive, response.stream == nil {
                self.continueReading(connection, leftover: leftover)
            }
        }
    }

    private func continueReading(_ connection: NWConnection, leftover: Data) {
        guard !leftover.isEmpty else {
            receiveRequest(connection, progress: ReadProgress())
            return
        }
        switch Self.parseHead(leftover) {
        case .invalid(let message):
            writeSimpleResponse(connection, status: 400, body: Self.errorBody(message))
            return
        case .complete(let head, let contentLength, let bodyOffset):
            guard contentLength <= Self.maximumBodyBytes else {
                writeSimpleResponse(
                    connection, status: 413,
                    body: #"{"error":{"message":"request body too large"}}"#)
                return
            }
            let start = leftover.startIndex
            let bodyStart = start + bodyOffset
            if leftover.count - bodyOffset >= contentLength {
                let body = leftover.subdata(in: bodyStart..<(bodyStart + contentLength))
                let rest = leftover.count - bodyOffset - contentLength
                dispatch(
                    connection, head: head, body: body,
                    leftover: rest > 0
                        ? leftover.subdata(in: (bodyStart + contentLength)..<leftover.endIndex)
                        : Data())
                return
            }
        case .incomplete:
            break
        }
        receiveRequest(connection, progress: ReadProgress())
    }

    private func respond(_ connection: NWConnection, response: GatewayResponse, keepAlive: Bool) async {
        if let producer = response.stream {
            var head = "HTTP/1.1 \(response.status) \(Self.reasonPhrase(response.status))\r\n"
            head += "Content-Type: \(response.contentType)\r\n"
            head += "Connection: close\r\n"
            for (name, value) in response.headers { head += "\(name): \(value)\r\n" }
            head += "\r\n"
            let session = GatewaySSESession(connection: connection)
            write(connection, data: Data(head.utf8)) { _ in }
            await producer(session)
            // 结尾的 `data: [DONE]` / `message_stop` 帧才是客户端判断答案完整的
            // 真正信号：先等最后一次 send 抵达 socket 再关，否则优雅的 FIN 会抢在
            // 它前面。
            await session.flush()
            connection.cancel()
            return
        }

        var head = "HTTP/1.1 \(response.status) \(Self.reasonPhrase(response.status))\r\n"
        head += "Content-Type: \(response.contentType)\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        head += keepAlive ? "Connection: keep-alive\r\n" : "Connection: close\r\n"
        for (name, value) in response.headers { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        let data = Data(head.utf8) + response.body
        write(connection, data: data) { _ in
            if !keepAlive { connection.cancel() }
        }
    }

    private func writeSimpleResponse(_ connection: NWConnection, status: Int, body: String) {
        let head =
            "HTTP/1.1 \(status) \(Self.reasonPhrase(status))\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
        write(connection, data: Data((head + body).utf8)) { _ in connection.cancel() }
    }

    /// 协议层拒答（`400`）用的 JSON 正文。保持成字符串，这样一个被拒的请求不会去
    /// 分配响应对象。
    private static func errorBody(_ message: String) -> String {
        let escaped = message.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return #"{"error":{"message":"\#(escaped)","type":"invalid_request_error"}}"#
    }

    private func write(
        _ connection: NWConnection, data: Data,
        completion: @escaping @Sendable (Error?) -> Void
    ) {
        connection.send(
            content: data,
            completion: .contentProcessed { error in
                completion(error)
            })
    }

    public static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 202: return "Accepted"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Payload Too Large"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        case 504: return "Gateway Timeout"
        default: return "Status \(status)"
        }
    }
}
