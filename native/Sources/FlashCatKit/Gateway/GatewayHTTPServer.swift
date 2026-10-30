import Foundation
import Network

/// One parsed inbound request. Header names are lowercased; the path keeps no
/// query string (the split parts live in `query`).
public struct GatewayRequest {
    public let method: String
    public let path: String
    public let query: [String: String]
    public let headers: [String: String]
    public let body: Data

    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    /// A request speaks Anthropic when it carries the headers the official SDKs
    /// always send. `GET /v1/models` is the one route both dialects share, so
    /// the header decides which shape the answer takes.
    public var isAnthropicStyle: Bool {
        header("x-api-key") != nil || header("anthropic-version") != nil
    }
}

/// What a route answers with. A JSON response is written in one go; an SSE
/// response hands the route a session it pushes events through until the
/// upstream (or the client) is done.
public struct GatewayResponse {
    public var status: Int = 200
    public var contentType: String = "application/json"
    public var headers: [String: String] = [:]
    public var body: Data = Data()
    /// When set, `body` is ignored and the closure streams the response.
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

/// Write side of one streaming response. `write` returns false once the client
/// is gone, so a producer stops translating an upstream stream nobody reads.
public final class GatewaySSESession: @unchecked Sendable {
    private let lock = NSLock()
    private weak var connection: NWConnection?
    private var closed = false

    public init(connection: NWConnection) {
        self.connection = connection
    }

    public var isClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        return closed
    }

    /// Writes one Server-Sent-Events frame. NWConnection processes sends FIFO,
    /// so frame order is preserved without extra synchronization. Returns
    /// false once the client disconnected and the producer should stop.
    @discardableResult
    public func write(_ text: String) -> Bool {
        if isClosed { return false }
        guard let connection else { return false }
        let data = Data(text.utf8)
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if error != nil { self?.markClosed() }
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

    private func markClosed() {
        lock.lock()
        closed = true
        lock.unlock()
    }
}

/// Minimal HTTP/1.1 server for the local gateway. Loopback only, one route
/// handler, keep-alive, and enough of the protocol for OpenAI / Anthropic SDK
/// clients: request line, headers, Content-Length bodies, and streamed
/// `text/event-stream` answers.
public final class GatewayHTTPServer {
    /// A request body larger than this is refused — these are chat calls, and
    /// even a base64 image batch stays far below the cap.
    public static let maximumBodyBytes = 128 * 1024 * 1024

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
        lock.lock(); defer { lock.unlock() }
        return port
    }

    /// Binds 127.0.0.1:`port` and returns once the listener is ready (true) or
    /// failed (false, e.g. the port is taken).
    public func start(port: UInt16) async -> Bool {
        guard let endpoint = NWEndpoint.Port(rawValue: port) else { return false }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: endpoint)
        parameters.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: parameters) else { return false }

        self.port = port
        return await withCheckedContinuation { (resume: CheckedContinuation<Bool, Never>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: resume.resume(returning: true)
                case .failed: resume.resume(returning: false)
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
        }
    }

    public func stop() {
        lock.lock()
        listener?.cancel()
        listener = nil
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
        receiveRequest(connection, buffer: Data())
    }

    // MARK: request reading

    private func receiveRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }

            if let head = Self.parseHead(buffer) {
                let contentLength = head.contentLength
                guard contentLength <= Self.maximumBodyBytes else {
                    self.writeSimpleResponse(connection, status: 413,
                                             body: #"{"error":{"message":"request body too large"}}"#)
                    return
                }
                let headEnd = head.bodyOffset
                if buffer.count - headEnd >= contentLength {
                    let body = buffer.subdata(in: headEnd..<(headEnd + contentLength))
                    let leftover = buffer.count - headEnd - contentLength
                    self.dispatch(connection,
                                  head: head.head,
                                  body: body,
                                  leftover: leftover > 0 ? buffer.subdata(in: (buffer.count - leftover)..<buffer.count) : Data())
                    return
                }
                // Body not complete yet.
                self.receiveRequest(connection, buffer: buffer)
                return
            }

            if error != nil || isComplete {
                if !buffer.isEmpty {
                    connection.cancel()
                }
                return
            }
            self.receiveRequest(connection, buffer: buffer)
        }
    }

    private struct ParsedHead {
        let head: (method: String, path: String, query: [String: String], headers: [String: String])
        let contentLength: Int
        let bodyOffset: Int
    }

    /// Splits the header block off the buffer when it is complete. Returns nil
    /// while more bytes are needed.
    private static func parseHead(_ buffer: Data) -> ParsedHead? {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = buffer.range(of: separator) else { return nil }
        let headEnd = range.upperBound - buffer.startIndex
        guard let text = String(data: buffer[buffer.startIndex..<range.lowerBound], encoding: .utf8),
              !text.isEmpty else {
            return ParsedHead(head: ("", "", [:], [:]), contentLength: 0, bodyOffset: headEnd)
        }
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else {
            return ParsedHead(head: ("", "", [:], [:]), contentLength: 0, bodyOffset: headEnd)
        }
        let requestLine = lines.removeFirst()
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            return ParsedHead(head: ("", "", [:], [:]), contentLength: 0, bodyOffset: headEnd)
        }
        let method = String(parts[0]).uppercased()
        let target = String(parts[1])
        let (path, query) = splitTarget(target)

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { headers[name] = value }
        }
        let contentLength = Int(headers["content-length"] ?? "") ?? 0
        return ParsedHead(head: (method, path, query, headers),
                          contentLength: max(contentLength, 0),
                          bodyOffset: headEnd)
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

    // MARK: response writing

    private func dispatch(_ connection: NWConnection,
                          head: (method: String, path: String, query: [String: String], headers: [String: String]),
                          body: Data,
                          leftover: Data) {
        let request = GatewayRequest(method: head.method,
                                     path: head.path,
                                     query: head.query,
                                     headers: head.headers,
                                     body: body)
        let keepAlive = (head.headers["connection"] ?? "").lowercased() != "close"
        Task { [weak self] in
            guard let self else { return }
            let response = await self.handler(request)
            await self.respond(connection, response: response, keepAlive: keepAlive)
            // Next request on the same socket — only for buffered responses; a
            // streamed answer closes the connection when the producer ends.
            if keepAlive, response.stream == nil {
                self.continueReading(connection, leftover: leftover)
            }
        }
    }

    private func continueReading(_ connection: NWConnection, leftover: Data) {
        guard !leftover.isEmpty else {
            receiveRequest(connection, buffer: Data())
            return
        }
        if let head = Self.parseHead(leftover) {
            if leftover.count - head.bodyOffset >= head.contentLength {
                let body = leftover.subdata(in: head.bodyOffset..<(head.bodyOffset + head.contentLength))
                let rest = leftover.count - head.bodyOffset - head.contentLength
                dispatch(connection, head: head.head, body: body,
                         leftover: rest > 0 ? leftover.subdata(in: (leftover.count - rest)..<leftover.count) : Data())
                return
            }
        }
        receiveRequest(connection, buffer: leftover)
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
            // Give the socket a beat to flush the last frames, then close: the
            // terminal `data: [DONE]` frame is the client's real signal, and a
            // graceful FIN keeps both SDK parsers happy.
            try? await Task.sleep(nanoseconds: 80_000_000)
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
        let head = "HTTP/1.1 \(status) \(Self.reasonPhrase(status))\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
        write(connection, data: Data((head + body).utf8)) { _ in connection.cancel() }
    }

    private func write(_ connection: NWConnection, data: Data, completion: @escaping (Error?) -> Void) {
        connection.send(content: data, completion: .contentProcessed { error in
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
        default: return "Status \(status)"
        }
    }
}
