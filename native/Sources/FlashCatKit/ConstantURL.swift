// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import Foundation

/// 常量地址的构造入口。
///
/// Swift 没有「不会失败」的字符串转 URL 构造器，而代码里那几个域名（Hugging Face、
/// GitHub API、某引擎的 releases 页面）是写死在源码里的常量。`URL(string:)!` 在这种
/// 场合永远不会失败，但项目禁 `NeverForceUnwrap`：一旦有人把常量改错，`!` 会在用户
/// 机器上崩掉，而这里退化成一个不可用的本地路径地址——请求会立刻以「不支持的 URL」
/// 失败，调用方拿到的是一条错误而不是一次崩溃。
public enum ConstantURL {
    public static func make(_ string: String) -> URL {
        guard let url = URL(string: string) else {
            return URL(fileURLWithPath: "/")
        }
        return url
    }
}
