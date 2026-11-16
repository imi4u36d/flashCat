// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import Foundation

/// 请求引擎却没有拿到响应的原因。
///
/// 以前网关把所有传输层失败都压成 `nil`：路由对它们一律回 503，日志里一个字都
/// 不留。「引擎没启动」（连接被拒）、「引擎在预热」和「模型超过截止时间」这三种
/// 情况，客户端分不出来，翻网关日志的人也分不出来。拆成三个具名 case，路由才能
/// 回 503 还是 504，并说清是哪一种失败。
public enum GatewayUpstreamError: Error, Equatable, Sendable {
    /// 端口上没人监听——引擎没在跑，或者还在启动中。
    case notReachable(port: Int, reason: String)
    /// 引擎接了请求，但 `seconds` 秒内没有回答。
    case timedOut(port: Int, seconds: TimeInterval)
    /// 连接断了，或者请求因为别的原因根本构造不出来。具体原因写进日志。
    case transport(port: Int, reason: String)

    public var port: Int {
        switch self {
        case .notReachable(let port, _), .timedOut(let port, _), .transport(let port, _):
            return port
        }
    }

    /// 503 = 没就绪，504 = 起来了但太慢，502 = 请求没走通（构造不出来或中途断掉）。
    /// 把差别转给客户端，它才能分清「等引擎起来再重试一次」和「这次没救了」。
    public var status: Int {
        switch self {
        case .notReachable: return 503
        case .timedOut: return 504
        case .transport: return 502
        }
    }

    /// 给 `LogStore` 的一行说明。网关日志是用户唯一能看到 API 调用为何失败的
    /// 地方，所以消息里要带上端口和原因。
    public var logMessage: String {
        switch self {
        case .notReachable(let port, let reason):
            return "上游引擎不可达（127.0.0.1:\(port)）：\(reason)；引擎可能未启动或仍在加载"
        case .timedOut(let port, let seconds):
            return "上游引擎超时（127.0.0.1:\(port)，\(Int(seconds)) 秒无响应）"
        case .transport(let port, let reason):
            return "上游连接中断（127.0.0.1:\(port)）：\(reason)"
        }
    }
}

/// 代表网关调用引擎的 OpenAI 兼容接口。`/v1/models` 与非流式聊天走缓冲，SSE 走
/// 字节流——引擎产出一片就转发一片，不必等整段答案攒完。
///
/// 每个入口都返回 `Result` 而不是可选值：路由需要知道是没人监听（503）、超过了
/// 截止时间（504），还是连接中途断了（502）。
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

    /// 带响应超时的 JSON POST。冷启动时引擎的首个 token 可能等很久，所以默认
    /// 超时给得很宽。
    public static func postJSON(
        port: Int,
        path: String,
        body: Data,
        timeout: TimeInterval = 600
    ) async -> Result<BufferedResponse, GatewayUpstreamError> {
        await buffered(method: "POST", port: port, path: path, body: body, timeout: timeout)
    }

    /// JSON GET，用于向引擎读取 `/v1/models`。
    public static func getJSON(
        port: Int,
        path: String,
        timeout: TimeInterval = 10
    ) async -> Result<BufferedResponse, GatewayUpstreamError> {
        await buffered(method: "GET", port: port, path: path, body: nil, timeout: timeout)
    }

    /// 响应头一到就返回的 POST；调用方按自己的节奏消费 `bytes`（SSE 流）。
    public static func postStreaming(
        port: Int,
        path: String,
        body: Data,
        timeout: TimeInterval = 600
    ) async -> Result<StreamResponse, GatewayUpstreamError> {
        guard let request = request(method: "POST", port: port, path: path, body: body, timeout: timeout) else {
            return .failure(.transport(port: port, reason: "无法构造上游 URL"))
        }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            // 消费 AsyncBytes 期间 URLSession 一直持有底层 task，不需要在这里
            // 显式 retain。
            return .success(StreamResponse(status: status, bytes: bytes))
        } catch {
            return .failure(classify(error, port: port, timeout: timeout))
        }
    }

    // MARK: plumbing（管道：构造请求、归类错误）

    private static func buffered(
        method: String,
        port: Int,
        path: String,
        body: Data?,
        timeout: TimeInterval
    ) async -> Result<BufferedResponse, GatewayUpstreamError> {
        guard let request = request(method: method, port: port, path: path, body: body, timeout: timeout) else {
            return .failure(.transport(port: port, reason: "无法构造上游 URL"))
        }
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return .success(BufferedResponse(status: status, body: data))
        } catch {
            return .failure(classify(error, port: port, timeout: timeout))
        }
    }

    /// 把 `URLError` 归到网关能处理的三种情况上。只有真正意味着「没人监听」的
    /// 错误码才算 `notReachable`；连接被掐断归 `transport`，因为引擎确实起来过。
    private static func classify(_ error: Error, port: Int, timeout: TimeInterval) -> GatewayUpstreamError {
        guard let urlError = error as? URLError else {
            return .transport(port: port, reason: error.localizedDescription)
        }
        switch urlError.code {
        case .cannotConnectToHost, .cannotFindHost, .notConnectedToInternet:
            return .notReachable(port: port, reason: urlError.localizedDescription)
        case .timedOut:
            return .timedOut(port: port, seconds: timeout)
        default:
            return .transport(port: port, reason: urlError.localizedDescription)
        }
    }

    /// 网关面向所有本地客户端，请求可能很频繁。每个请求新建并销毁
    /// `URLSession` 会造成连接池和线程反复抖动；复用同一个会话，
    /// 超时由 request 级 `timeoutInterval` 控制。
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 8
        configuration.timeoutIntervalForRequest = 600
        configuration.timeoutIntervalForResource = 3600
        return URLSession(configuration: configuration)
    }()

    private static func request(
        method: String,
        port: Int,
        path: String,
        body: Data?,
        timeout: TimeInterval
    ) -> URLRequest? {
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

    // MARK: SSE parsing（SSE 解析）

    /// 取出 SSE `data:` 行里的 JSON 载荷；注释行、空行与结尾的 `[DONE]` 标记
    /// 返回 nil。
    public static func dataPayload(ofLine line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("data:") else { return nil }
        let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload.isEmpty || payload == "[DONE]" { return nil }
        return payload
    }
}
