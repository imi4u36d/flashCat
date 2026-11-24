// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import Foundation
import OSLog

/// 应用统一的日志入口：一条记录同时进 `os.Logger`（系统日志、Console.app 可查）
/// 和可注入的 handler（测试、壳层日志页）。
///
/// 以前各处的失败分别走 `NSLog`、`print`、引擎日志或静默 `try?`，同一个错误在
/// 不同入口有不同去向。这里只保留一个写入口，分类与级别由调用方声明，落盘/展示
/// 由 handler 决定；Core 不依赖 App 的 `LogStore`。
package enum AppLog {
    package enum Category: String, CaseIterable, Sendable {
        case app
        case engine
        case chat
        case gateway
        case control
        case download
        case persistence
        case media
    }

    package enum Level: String, Sendable {
        case debug
        case info
        case warning
        case error
    }

    package struct Entry: Equatable, Sendable {
        package let date: Date
        package let level: Level
        package let category: Category
        package let message: String

        package init(date: Date = Date(), level: Level, category: Category, message: String) {
            self.date = date
            self.level = level
            self.category = category
            self.message = message
        }
    }

    private static let subsystem = "com.zhuo.flashCat"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [UUID: @Sendable (Entry) -> Void] = [:]

    /// 注册一个接收器；返回的 id 用于 `removeHandler`。
    @discardableResult
    package static func addHandler(_ handler: @escaping @Sendable (Entry) -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        handlers[id] = handler
        lock.unlock()
        return id
    }

    package static func removeHandler(_ id: UUID) {
        lock.lock()
        handlers.removeValue(forKey: id)
        lock.unlock()
    }

    package static func debug(
        _ category: Category, _ message: @autoclosure () -> String,
        file: String = #fileID, line: Int = #line
    ) {
        log(.debug, category, message(), file: file, line: line)
    }

    package static func info(
        _ category: Category, _ message: @autoclosure () -> String,
        file: String = #fileID, line: Int = #line
    ) {
        log(.info, category, message(), file: file, line: line)
    }

    package static func warning(
        _ category: Category, _ message: @autoclosure () -> String,
        file: String = #fileID, line: Int = #line
    ) {
        log(.warning, category, message(), file: file, line: line)
    }

    package static func error(
        _ category: Category, _ message: @autoclosure () -> String,
        file: String = #fileID, line: Int = #line
    ) {
        log(.error, category, message(), file: file, line: line)
    }

    package static func log(
        _ level: Level, _ category: Category, _ message: String,
        file: String = #fileID, line: Int = #line
    ) {
        let logger = Logger(subsystem: subsystem, category: category.rawValue)
        switch level {
        case .debug: logger.debug("\(message, privacy: .public)")
        case .info: logger.info("\(message, privacy: .public)")
        case .warning: logger.warning("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        }

        let entry = Entry(level: level, category: category, message: "\(file):\(line) \(message)")
        lock.lock()
        let current = Array(handlers.values)
        lock.unlock()
        for handler in current { handler(entry) }
    }
}
