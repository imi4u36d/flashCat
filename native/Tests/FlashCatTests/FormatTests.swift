// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import XCTest

@testable import FlashCat
@testable import FlashCatCore

/// 面板上的数字只有一套口径：磁盘用十进制（和 Finder 一致），内存用二进制
/// （和活动监视器一致），速度跟磁盘同口径。这几条断言就是口径的看门狗。
final class FormatTests: XCTestCase {
    func testDiskSizeIsDecimalSoItMatchesTheFinder() {
        XCTAssertEqual(Format.size(4_300_000_000), "4.3 GB")
        XCTAssertEqual(Format.size(1_000_000_000), "1.0 GB")
        XCTAssertEqual(Format.size(999_000_000), "999 MB")
        XCTAssertEqual(Format.size(4_294_967_296), "4.3 GB")
        // 低于 1 MB 不能读成「0 MB」。
        XCTAssertEqual(Format.size(524_288), "524 KB")
    }

    func testMemoryIsBinary() {
        XCTAssertEqual(Format.memory(8_589_934_592), "8.0 GB")
        XCTAssertEqual(Format.memory(1_073_741_824), "1.0 GB")
        XCTAssertEqual(Format.memory(1_048_576), "1.0 MB")
        XCTAssertEqual(Format.memory(1024), "1.0 KB")
    }

    func testTheSameByteCountReadsTheSameOnEveryPanel() {
        // 这个值在模型卡片、Hub 列表和下载中心三处出现，早先卡片用十进制、
        // 下载中心用二进制，同一份权重写成 4.3 GB / 4.0 GB 两个数。
        let bytes = 4_294_967_296
        XCTAssertEqual(Format.size(bytes), Format.size(bytes))
        XCTAssertEqual(Format.size(bytes), "4.3 GB")
        XCTAssertNotEqual(Format.memory(bytes), Format.size(bytes))
    }

    func testTransferRateUsesTheSameDecimalBase() {
        XCTAssertEqual(Format.rate(10_000_000), "10.0 MB/s")
        XCTAssertEqual(Format.rate(2_000_000), "2.0 MB/s")
        XCTAssertEqual(Format.rate(1500), "2 KB/s")
        XCTAssertEqual(Format.rate(0), "—")
    }

    func testTokenReadings() {
        XCTAssertEqual(Format.tokens(999), "999")
        XCTAssertEqual(Format.tokens(1000), "1.0K")
        XCTAssertEqual(Format.tokens(12_345), "12.3K")
        XCTAssertEqual(Format.tokensShort(131_072), "131K")
        XCTAssertEqual(Format.tokensShort(999), "999")
    }

    func testCompactKeepsThreeSignificantShapes() {
        XCTAssertEqual(Format.compact(123.4), "123")
        XCTAssertEqual(Format.compact(12.34), "12.3")
        XCTAssertEqual(Format.compact(1.234), "1.23")
    }

    /// 侧栏时间按分组换精度：今天给相对量、昨天给时刻、更早给日期。
    /// 口径必须和 `ChatThreadSections` 的 `startOfDay` 一致，跨天但不足
    /// 24 小时的会话不能被读成「20h」。
    func testSidebarTimeUsesTheRightPrecisionForEachGroup() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let now = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 15, minute: 30)))
        func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }

        XCTAssertEqual(Format.sidebarTime(ago(20), now: now, calendar: calendar), "刚刚")
        XCTAssertEqual(Format.sidebarTime(ago(12 * 60), now: now, calendar: calendar), "12m")
        XCTAssertEqual(Format.sidebarTime(ago(3 * 3600), now: now, calendar: calendar), "3h")
        // 跨过零点就是昨天：给时刻，不给「19h」。
        XCTAssertEqual(Format.sidebarTime(ago(20 * 3600), now: now, calendar: calendar), "19:30")

        let yesterday = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 11, day: 24, hour: 14, minute: 20)))
        XCTAssertEqual(
            Format.sidebarTime(yesterday, now: now, calendar: calendar), "14:20")

        let older = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 9, minute: 15)))
        XCTAssertEqual(Format.sidebarTime(older, now: now, calendar: calendar), "11-18")

        // 时钟回拨产生的未来时间不能读成负数，也不应该退到日期。
        XCTAssertEqual(Format.sidebarTime(ago(-30), now: now, calendar: calendar), "刚刚")
    }
}
