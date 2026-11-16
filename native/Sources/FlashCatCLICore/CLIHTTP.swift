// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import Foundation

/// The CLI has no use for an on-disk URL cache, and writing one under
/// `~/Library/Caches/flashcat-cli` is both noise and (under a sandbox) an error
/// dump on stderr. Ephemeral sessions keep every command self-contained.
///
/// 会话是共享的：`status --watch` / `logs --follow` 每秒发一次请求，每次新建
/// URLSession 又不 invalidate 会让进程里堆满永不释放的连接池和 delegate 线程。
/// 会话本身只承载配置，认证令牌仍然由每个请求自己的 header 带，所以共享不会串号。
public enum CLIHTTP {
    /// 用到的工具链已经把 `URLSession` 标成 `Sendable`，静态常量不需要再加
    /// `nonisolated(unsafe)`（加了反而多一条警告）。请求超时仍由每个请求的
    /// `timeoutInterval` 覆盖。
    public static let shared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 24 * 3600
        return URLSession(configuration: configuration)
    }()
}
