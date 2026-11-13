import XCTest
@testable import FlashCat

/// 「一屏一页」的排版只取决于可用区域，所以可以脱离 UI 直接断言：
/// 页面必须正好落在一屏里、封面保持原始比例、窗口变小也不会把半行卡片切出去。
final class LabGridLayoutTests: XCTestCase {
    /// 1280×820 默认窗口去掉侧栏、留白和标题后的典型网格区域。
    private let defaultGrid = CGSize(width: 1032, height: 598)

    func testImagesFillOneScreen() {
        let layout = LabGridLayout.make(size: defaultGrid, kind: .images)

        XCTAssertEqual(layout.columns, 4)
        XCTAssertEqual(layout.rows, 2)
        XCTAssertEqual(layout.pageSize, 8)
        XCTAssertLessThanOrEqual(layout.requiredHeight, defaultGrid.height)
        XCTAssertEqual(layout.gridWidth, defaultGrid.width, accuracy: 0.5)
    }

    func testVideosFillOneScreen() {
        let layout = LabGridLayout.make(size: defaultGrid, kind: .videos)

        XCTAssertEqual(layout.columns, 3)
        XCTAssertEqual(layout.rows, 2)
        XCTAssertEqual(layout.pageSize, 6)
        XCTAssertLessThanOrEqual(layout.requiredHeight, defaultGrid.height)
    }

    func testCoversKeepTheirAspect() {
        let images = LabGridLayout.make(size: defaultGrid, kind: .images)
        XCTAssertEqual(images.coverWidth, images.coverHeight, accuracy: 0.5,
                       "图片是方图，封面不该被拉成别的比例")

        let videos = LabGridLayout.make(size: defaultGrid, kind: .videos)
        XCTAssertEqual(videos.coverWidth / videos.coverHeight, 16.0 / 9.0, accuracy: 0.01)
    }

    func testShortWindowKeepsOneRowInsideTheScreen() {
        let size = CGSize(width: 1032, height: 260)
        let layout = LabGridLayout.make(size: size, kind: .images)

        XCTAssertEqual(layout.rows, 1)
        XCTAssertLessThanOrEqual(layout.requiredHeight, size.height,
                                 "放不下两行时宁可只排一行，也不能让卡片被切掉")
    }

    func testTinyWindowClampsCoverInsteadOfClippingHalfACard() {
        let layout = LabGridLayout.make(size: CGSize(width: 1032, height: 120), kind: .images)

        XCTAssertEqual(layout.rows, 1)
        XCTAssertEqual(layout.coverHeight, LabGridLayout.minCoverHeight,
                       "矮到连最小封面都放不下时，封面停在最小高度")
    }

    func testNarrowWindowDropsToSingleColumn() {
        let size = CGSize(width: 432, height: 500)
        let layout = LabGridLayout.make(size: size, kind: .images)

        XCTAssertEqual(layout.columns, 1)
        XCTAssertGreaterThanOrEqual(layout.pageSize, 1)
        XCTAssertLessThanOrEqual(layout.gridWidth, size.width)
        XCTAssertLessThanOrEqual(layout.requiredHeight, size.height)
    }

    func testLayoutAlwaysHasAtLeastOneCell() {
        for size in [CGSize(width: 1, height: 1), CGSize(width: 40, height: 40)] {
            for kind in [LabGridKind.images, .videos] {
                let layout = LabGridLayout.make(size: size, kind: kind)
                XCTAssertGreaterThanOrEqual(layout.columns, 1)
                XCTAssertGreaterThanOrEqual(layout.rows, 1)
                XCTAssertGreaterThan(layout.pageSize, 0)
                XCTAssertGreaterThan(layout.cellWidth, 0)
                XCTAssertGreaterThan(layout.coverHeight, 0)
            }
        }
    }

    func testRowCountNeverExceedsCap() {
        let layout = LabGridLayout.make(size: CGSize(width: 1600, height: 2000), kind: .images)
        XCTAssertLessThanOrEqual(layout.rows, LabGridLayout.maxRows)
    }

    /// 常见窗口尺寸下，页面都要恰好放进可视区，一行不多一行不少。
    func testEveryReasonableWindowFitsOneScreen() {
        let sizes = [
            CGSize(width: 432, height: 480),
            CGSize(width: 780, height: 520),
            CGSize(width: 1032, height: 598),
            CGSize(width: 1032, height: 900),
            CGSize(width: 1400, height: 700),
        ]
        for size in sizes {
            for kind in [LabGridKind.images, .videos] {
                let layout = LabGridLayout.make(size: size, kind: kind)
                XCTAssertLessThanOrEqual(layout.requiredHeight, size.height,
                                         "\(kind) @ \(size) 排出来的页面高过可视区")
                XCTAssertLessThanOrEqual(layout.gridWidth, size.width,
                                         "\(kind) @ \(size) 排出来的页面宽过可视区")
            }
        }
    }
}
