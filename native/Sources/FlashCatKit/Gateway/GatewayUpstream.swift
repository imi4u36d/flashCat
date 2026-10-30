import Foundation

/// Calls the engine's OpenAI-compatible surface on behalf of the gateway.
/// Buffered for `/v1/models` and non-streaming chat; a byte stream for SSE so
/// chunks reach the client the moment the engine produces them.
public enum GatewayUpstream {

    public struct BufferedResponse {
        public let status: Int
        public let body: Data

        public init(status: Int, body: Data) {
            self.status = status
            self.body = body
        }
    }

    public struct StreamResponse {
        public let status: Int
        public let bytes: URLSession.AsyncBytes
    }

    /// JSON POST with a response timeout; engines can take a while on a cold
    /// first token, so the default is generous.
    public static func postJSON(port: Int,
                                path: String,
                                body: Data,
                                timeout: TimeInterval = 600) async -> BufferedResponse? {
        guard let request = request(method: "POST", port: port, path: path, body: body, timeout: timeout) else {
            return nil
        }
        let session = makeSession(timeout: timeout)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return BufferedResponse(status: status, body: data)
        } catch {
            return nil
        }
    }

    /// JSON GET, used for `/v1/models` reads against the engine.
    public static func getJSON(port: Int,
                               path: String,
                               timeout: TimeInterval = 10) async -> BufferedResponse? {
        guard let request = request(method: "GET", port: port, path: path, body: nil, timeout: timeout) else {
            return nil
        }
        let session = makeSession(timeout: timeout)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return BufferedResponse(status: status, body: data)
        } catch {
            return nil
        }
    }

    /// POST that returns as soon as response headers arrive; the caller drains
    /// `bytes` (an SSE stream) at its own pace.
    public static func postStreaming(port: Int,
                                     path: String,
                                     body: Data,
                                     timeout: TimeInterval = 600) async -> StreamResponse? {
        guard let request = request(method: "POST", port: port, path: path, body: body, timeout: timeout) else {
            return nil
        }
        let session = makeSession(timeout: timeout)
        do {
            let (bytes, response) = try await session.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            // URLSession keeps the underlying task alive while AsyncBytes is
            // being consumed; no explicit retain is needed.
            return StreamResponse(status: status, bytes: bytes)
        } catch {
            session.finishTasksAndInvalidate()
            return nil
        }
    }

    // MARK: plumbing

    private static func makeSession(timeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    private static func request(method: String,
                                port: Int,
                                path: String,
                                body: Data?,
                                timeout: TimeInterval) -> URLRequest? {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    // MARK: SSE parsing

    /// Extracts the JSON payload of one SSE `data:` line, or nil for comments,
    /// blank lines and the terminal `[DONE]` marker.
    public static func dataPayload(ofLine line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("data:") else { return nil }
        let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload.isEmpty || payload == "[DONE]" { return nil }
        return payload
    }
}
