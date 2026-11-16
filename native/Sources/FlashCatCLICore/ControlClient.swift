// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import FlashCatKit
import Foundation

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

    public static func discover(
        invocation: CLIInvocation,
        environment: [String: String],
        runtime: ControlRuntime? = ControlRuntime.load()
    ) throws -> ControlLocation {
        let explicitURL = invocation.option("control-url") ?? environment["FLASHCAT_CONTROL_URL"]
        let explicitPort =
            invocation.option("control-port")
            ?? environment["FLASHCAT_CONTROL_PORT"]
        let explicitToken =
            invocation.option("control-token")
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
            throw CLIError(
                "找不到控制接口（control.json）",
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
            throw CLIError(
                "拒绝把控制令牌发往 \(url.host ?? "远程主机")：控制接口只监听本机",
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

    public func get<T: Decodable>(
        _ path: String,
        query: [URLQueryItem] = [],
        timeout: TimeInterval = 30
    ) async throws -> T {
        let data = try await request(method: "GET", path: path, query: query, body: nil, timeout: timeout)
        return try decode(data)
    }

    public func post<T: Decodable, Body: Encodable>(
        _ path: String,
        body: Body,
        timeout: TimeInterval = 30
    ) async throws -> T {
        let encoded = try ControlJSON.encoder(pretty: false).encode(body)
        let data = try await request(method: "POST", path: path, query: [], body: encoded, timeout: timeout)
        return try decode(data)
    }

    public func post<T: Decodable>(
        _ path: String,
        timeout: TimeInterval = 30
    ) async throws -> T {
        let data = try await request(
            method: "POST", path: path, query: [],
            body: Data("{}".utf8), timeout: timeout)
        return try decode(data)
    }

    public func postData(
        _ path: String,
        body: Data?,
        timeout: TimeInterval = 30
    ) async throws -> Data {
        try await request(method: "POST", path: path, query: [], body: body, timeout: timeout)
    }

    public func getData(
        _ path: String,
        query: [URLQueryItem] = [],
        timeout: TimeInterval = 30
    ) async throws -> Data {
        try await request(method: "GET", path: path, query: query, body: nil, timeout: timeout)
    }

    /// 放宽到 internal 是为了让退出码映射可以被单测直接覆盖：它是脚本判断故障类型
    /// 的唯一依据，但此前只藏在 `request` 的非 2xx 分支里。
    func decode<T: Decodable>(_ data: Data) throws -> T {
        guard !data.isEmpty else { throw CLIError("控制接口返回了空响应") }
        do {
            return try ControlJSON.decoder().decode(T.self, from: data)
        } catch {
            throw CLIError("无法解析控制接口响应：\(error.localizedDescription)")
        }
    }

    private func request(
        method: String,
        path: String,
        query: [URLQueryItem],
        body: Data?,
        timeout: TimeInterval
    ) async throws -> Data {
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
            (data, response) = try await CLIHTTP.shared.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .cannotConnectToHost, .networkConnectionLost, .cannotFindHost,
                .notConnectedToInternet, .dnsLookupFailed:
                throw CLIError(
                    "连不上 flashCat 控制接口（\(baseURL.absoluteString)）",
                    exit: .notRunning,
                    hint: "应用可能没有运行：先执行 flashcat app open")
            case .timedOut:
                throw CLIError(
                    "等待 flashCat 响应超时", exit: .timeout,
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
                throw CLIError(
                    document.error.message,
                    exit: Self.exitCode(status: status, code: document.error.code),
                    hint: document.error.code == ControlErrorCode.unauthorized
                        ? "控制令牌已过期；重启 flashCat 后再试"
                        : nil)
            }
            let text = String(data: data, encoding: .utf8) ?? ""
            throw CLIError(
                "控制接口返回 HTTP \(status)\(text.isEmpty ? "" : "：\(text)")",
                exit: Self.exitCode(status: status, code: nil))
        }
        return data
    }

    /// HTTP 状态 → 退出码。internal 便于单测；调用方只在非 2xx 分支用它，
    /// 200 也给出 `.success` 只是让这张表完整（否则函数对 200 会答「失败」）。
    ///
    /// 映射本身不再写在这里：`CLICommandTable.exitCodes` 是唯一来源，`help` 里
    /// 打印的「哪个码对应哪个 HTTP 状态」和这里执行的是同一行数据。错误体里的
    /// `error.code` 优先于状态码——令牌过期常常带 500 回来，只看状态会误报成
    /// 「执行失败」，脚本据此判断「要不要重启应用」就会做错决定。
    static func exitCode(status: Int, code: String?) -> CLIExit {
        if let code, let mapped = CLICommandTable.exitCode(forControlErrorCode: code) {
            return mapped
        }
        return CLICommandTable.exitCode(forHTTPStatus: status) ?? .failure
    }
}
