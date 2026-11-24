// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import XCTest

@testable import FlashCatCore

final class AppLogTests: XCTestCase {
    func testHandlerReceivesLevelsCategoriesAndMessages() {
        let recorder = Recorder()
        let token = AppLog.addHandler { recorder.append($0) }
        defer { AppLog.removeHandler(token) }

        AppLog.debug(.chat, "debug-line")
        AppLog.info(.engine, "info-line")
        AppLog.warning(.gateway, "warning-line")
        AppLog.error(.persistence, "error-line")

        let entries = recorder.snapshot()
        XCTAssertEqual(entries.map(\.level), [.debug, .info, .warning, .error])
        XCTAssertEqual(entries.map(\.category), [.chat, .engine, .gateway, .persistence])
        XCTAssertTrue(entries[0].message.hasSuffix("debug-line"))
        XCTAssertTrue(entries[3].message.hasSuffix("error-line"))
    }

    func testRemovingHandlerStopsDelivery() {
        let recorder = Recorder()
        let token = AppLog.addHandler { recorder.append($0) }
        AppLog.info(.app, "before")
        AppLog.removeHandler(token)
        AppLog.info(.app, "after")

        XCTAssertEqual(recorder.snapshot().count, 1)
    }

    func testMultipleHandlersEachReceiveOnce() {
        let first = Recorder()
        let second = Recorder()
        let a = AppLog.addHandler { first.append($0) }
        let b = AppLog.addHandler { second.append($0) }
        defer {
            AppLog.removeHandler(a)
            AppLog.removeHandler(b)
        }

        AppLog.error(.media, "shared")

        XCTAssertEqual(first.snapshot().count, 1)
        XCTAssertEqual(second.snapshot().count, 1)
        XCTAssertEqual(first.snapshot().first?.message, second.snapshot().first?.message)
    }
}

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [AppLog.Entry] = []

    func append(_ entry: AppLog.Entry) {
        lock.lock()
        entries.append(entry)
        lock.unlock()
    }

    func snapshot() -> [AppLog.Entry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}
