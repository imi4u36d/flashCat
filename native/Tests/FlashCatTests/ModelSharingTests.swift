// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import FlashCatKit
import XCTest

@testable import FlashCat
@testable import FlashCatCore

/// 公共目录是共享池：从模型卡下载的权重默认授权给全部引擎，而不是下载时
/// 点开的那一个。`lead` 只决定下载任务归谁记账，不缩小可见范围。
final class ModelSharingTests: XCTestCase {
    func testDownloadTargetsGrantEveryEngineWithTheLeadFirst() {
        for lead in EngineCatalog.allIDs {
            let targets = ModelSharing.downloadTargets(lead: lead)
            XCTAssertEqual(targets.first, lead)
            XCTAssertEqual(Set(targets), Set(EngineCatalog.allIDs))
            XCTAssertEqual(targets.count, EngineCatalog.allIDs.count, "同一个引擎只应出现一次")
        }
    }
}
