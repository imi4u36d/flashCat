import Foundation
import FlashCatKit

/// Discovery record shared by every command. The app writes it on launch and
/// the CLI never guesses the port: it may have moved because the configured
/// one was taken.
public struct ControlLocation: Sendable {
    public let baseURL: URL
    public let token: String
    public let runtime: ControlRuntime?

    public init(baseURL: URL, token: String, runtime: ControlRuntime?) {
        self.baseURL = baseURL
        self.token = token
        self.runtime = runtime
    }

    public static func discover(invocation: CLIInvocation,
                                environment: [String: String],
                                runtime: ControlRuntime? = ControlRuntime.load()) throws -> ControlLocation {
        let explicitURL = invocation.option("control-url") ?? environment["FLASHCAT_CONTROL_URL"]
        let explicitPort = invocation.option("control-port")
            ?? environment["FLASHCAT_CONTROL_PORT"]
        let explicitToken = invocation.option("control-token")
            ?? environment["FLASHCAT_CONTROL_TOKEN"]

        let port: UInt16
        if let explicitPort {
            guard let value = UInt16(explicitPort), value >= 1024 else {
                throw CLIError("控制端口无效：\(explicitPort)", exit: .usage)
            }
            port = value
        } else if let runtime, runtime.processIsAlive {
            port = runtime.port
        } else {
            port = 9100
        }

        let url: URL
        if let explicitURL {
            guard let parsed = URL(string: explicitURL) else {
                throw CLIError("控制接口地址无效：\(explicitURL)", exit: .usage)
            }
            url = try validatedControlURL(parsed)
        } else {
            guard let parsed = URL(string: "http://127.0.0.1:\(port)") else {
                throw CLIError("无法构造控制接口地址", exit: .usage)
            }
            url = parsed
        }

        guard let token = explicitToken ?? runtime?.token, !token.isEmpty else {
            throw CLIError("找不到控制接口（control.json）",
                           exit: .notRunning,
                           hint: "flashCat 可能没有运行，或「设置 → 命令行接口」已关闭；先执行 flashcat app open")
        }
        return ControlLocation(baseURL: url, token: token, runtime: runtime)
    }

    public var client: ControlClient {
        ControlClient(baseURL: baseURL, token: token)
    }

    /// The control token authorises quit, delete and engine start. Sending it
    /// over plain HTTP to anything but loopback would hand it to the network,
    /// so an explicit `--control-url` must be local (or HTTPS).
    private static func validatedControlURL(_ url: URL) throws -> URL {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw CLIError("控制接口地址必须使用 http 或 https：\(url.absoluteString)", exit: .usage)
        }
        guard scheme == "https" || isLoopback(url) else {
            throw CLIError("拒绝把控制令牌发往 \(url.host ?? "远程主机")：控制接口只监听本机",
                           exit: .usage,
                           hint: "远程访问请通过 HTTPS 反向代理，或使用 --control-port 指定本机端口")
        }
        return url
    }

    private static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }
}

// MARK: - Client

public struct ControlClient: Sendable {
    public let baseURL: URL
    public let token: String

    public init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
    }

    public func get<T: Decodable>(_ path: String,
                                  query: [URLQueryItem] = [],
                                  timeout: TimeInterval = 30) async throws -> T {
        let data = try await request(method: "GET", path: path, query: query, body: nil, timeout: timeout)
        return try decode(data)
    }

    public func post<T: Decodable, Body: Encodable>(_ path: String,
                                                    body: Body,
                                                    timeout: TimeInterval = 30) async throws -> T {
        let encoded = try ControlJSON.encoder(pretty: false).encode(body)
        let data = try await request(method: "POST", path: path, query: [], body: encoded, timeout: timeout)
        return try decode(data)
    }

    public func post<T: Decodable>(_ path: String,
                                   timeout: TimeInterval = 30) async throws -> T {
        let data = try await request(method: "POST", path: path, query: [],
                                     body: Data("{}".utf8), timeout: timeout)
        return try decode(data)
    }

    public func postData(_ path: String,
                         body: Data?,
                         timeout: TimeInterval = 30) async throws -> Data {
        try await request(method: "POST", path: path, query: [], body: body, timeout: timeout)
    }

    public func getData(_ path: String,
                        query: [URLQueryItem] = [],
                        timeout: TimeInterval = 30) async throws -> Data {
        try await request(method: "GET", path: path, query: query, body: nil, timeout: timeout)
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        guard !data.isEmpty else { throw CLIError("控制接口返回了空响应") }
        do {
            return try ControlJSON.decoder().decode(T.self, from: data)
        } catch {
            throw CLIError("无法解析控制接口响应：\(error.localizedDescription)")
        }
    }

    private func request(method: String,
                         path: String,
                         query: [URLQueryItem],
                         body: Data?,
                         timeout: TimeInterval) async throws -> Data {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.path = path
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else {
            throw CLIError("控制接口地址无效：\(baseURL.absoluteString)", exit: .usage)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await CLIHTTP.session().data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .cannotConnectToHost, .networkConnectionLost, .cannotFindHost,
                 .notConnectedToInternet, .dnsLookupFailed:
                throw CLIError("连不上 flashCat 控制接口（\(baseURL.absoluteString)）",
                               exit: .notRunning,
                               hint: "应用可能没有运行：先执行 flashcat app open")
            case .timedOut:
                throw CLIError("等待 flashCat 响应超时", exit: .timeout,
                               hint: "长任务可以加 --timeout 600 再试")
            default:
                throw CLIError("控制接口请求失败：\(error.localizedDescription)")
            }
        } catch {
            throw CLIError("控制接口请求失败：\(error.localizedDescription)")
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            if let document = try? ControlJSON.decoder().decode(ControlErrorDocument.self, from: data) {
                throw CLIError(document.error.message,
                               exit: Self.exitCode(status: status, code: document.error.code),
                               hint: document.error.code == ControlErrorCode.unauthorized
                                   ? "控制令牌已过期；重启 flashCat 后再试"
                                   : nil)
            }
            let text = String(data: data, encoding: .utf8) ?? ""
            throw CLIError("控制接口返回 HTTP \(status)\(text.isEmpty ? "" : "：\(text)")",
                           exit: Self.exitCode(status: status, code: nil))
        }
        return data
    }

    private static func exitCode(status: Int, code: String?) -> CLIExit {
        if code == ControlErrorCode.unauthorized { return .unauthorized }
        if code == ControlErrorCode.timeout { return .timeout }
        switch status {
        case 400: return .usage
        case 401, 403: return .unauthorized
        case 404: return .notFound
        case 408, 504: return .timeout
        case 409: return .conflict
        default: return .failure
        }
    }
}
