// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import XCTest

@testable import FlashCatKit

/// descriptor 是引擎差异的唯一落点，但「差异」具体落在两张表里：
/// `EngineTuningProfile.byAdapter`（参数拼写）与 `EngineStatusDialects.byFormat`
/// （遥测解析）。两张表对未登记的键都是**查不到就兜底**：少一行不会编译失败，
/// 运行时也不报错——只会静默少下发一个参数、少显示一个读数。
///
/// 这组测试把「新增引擎」的隐含契约变成硬失败：只要 `EngineCatalog.allIDs` 里
/// 出现一个没配齐 descriptor / 调优表 / 解析表的 id，测试当场红。
final class EngineDescriptorConformanceTests: XCTestCase {

    /// 五个内置引擎都必须有 descriptor，且 id 与 catalog 一致。
    func testEveryCatalogEngineResolvesToADescriptor() {
        for id in EngineCatalog.allIDs {
            let descriptor = EngineCatalog.descriptor(for: id)
            XCTAssertEqual(descriptor.id, id, "\(id.rawValue) 的 descriptor.id 与查询键不一致")
            XCTAssertFalse(descriptor.displayName.isEmpty, "\(id.rawValue) 缺 displayName")
            XCTAssertFalse(descriptor.minMacOS.isEmpty, "\(id.rawValue) 缺 minMacOS")
            XCTAssertGreaterThan(descriptor.startupTimeout, 0, "\(id.rawValue) 的启动超时必须为正")
        }
    }

    /// 每个内置引擎都要有参数拼写表项。缺失时 `EngineTuningProfile.resolved(for:)`
    /// 会退到 `generic`，也就是「所有 knob 都下不出去」——用户改了设置却不生效，
    /// 这是最难查的一类 bug，所以必须在这里挡住。
    func testEveryEngineHasATuningProfile() {
        for id in EngineCatalog.allIDs {
            let descriptor = EngineCatalog.descriptor(for: id)
            XCTAssertNotNil(
                EngineTuningProfile.registered(for: descriptor.adapter),
                "\(id.rawValue) 的 adapter \(descriptor.adapter.rawValue) 没有 EngineTuningProfile 表项")
        }
    }

    /// 每个内置引擎都要有解析入口：要么有「只有一份状态文档」的主格式，要么
    /// descriptor 声明了 telemetry。否则界面永远拿不到读数。
    func testEveryEngineHasAStatusDialect() {
        for id in EngineCatalog.allIDs {
            let descriptor = EngineCatalog.descriptor(for: id)
            let hasPrimary = EngineStatusDialects.primaryStatusFormat[descriptor.adapter] != nil
            XCTAssertTrue(
                hasPrimary || !descriptor.telemetry.isEmpty,
                "\(id.rawValue) 既没有主状态格式，也没有 telemetry 声明")
            for source in descriptor.telemetry {
                XCTAssertNotNil(
                    EngineStatusDialects.dialect(for: source.format),
                    "\(id.rawValue) 声明了 \(source.format.rawValue)，但没有对应方言")
            }
            if let format = EngineStatusDialects.primaryStatusFormat[descriptor.adapter] {
                XCTAssertNotNil(
                    EngineStatusDialects.dialect(for: format),
                    "\(id.rawValue) 的主格式 \(format.rawValue) 没有对应方言")
            }
        }
    }

    /// 能力位、端口、端口区间必须自洽：端点是界面「打开引擎页面」的入口，端口
    /// 撞车会让两个引擎抢同一个监听位。
    func testEveryEngineHasCapabilitiesAndAUniquePort() {
        var ports: [Int: EngineID] = [:]
        for id in EngineCatalog.allIDs {
            let descriptor = EngineCatalog.descriptor(for: id)
            XCTAssertFalse(descriptor.capabilities.isEmpty, "\(id.rawValue) 没有能力位")
            // 内置引擎的端口都在 8000 段：默认值取 8000/8100/8200/8300/8400。
            XCTAssertTrue(
                (8_000..<9_000).contains(descriptor.defaultPort),
                "\(id.rawValue) 的默认端口 \(descriptor.defaultPort) 不在 8000 段")
            XCTAssertGreaterThan(descriptor.portRangeSize, 0)
            XCTAssertFalse(descriptor.portRange.isEmpty, "\(id.rawValue) 的端口区间为空")
            if let existing = ports[descriptor.defaultPort] {
                XCTFail("\(id.rawValue) 与 \(existing.rawValue) 抢同一个默认端口 \(descriptor.defaultPort)")
            }
            ports[descriptor.defaultPort] = id
        }
    }

    /// `allIDs` 是这张契约表的入口，重复登记会让上面每条断言跑两遍而掩盖问题。
    func testCatalogIDsAreUnique() {
        let ids = EngineCatalog.allIDs
        XCTAssertEqual(Set(ids).count, ids.count, "EngineCatalog.allIDs 有重复项")
    }

    /// 「新装默认版本」不是 Kit 里的常量，而是随包索引里的最新发布：这里断言每个
    /// 内置引擎都有一条可用的、版本号非空的下载记录。
    func testEveryEngineHasANonEmptyDefaultVersionInPackIndex() throws {
        let indexURL = try repositoryFile(named: "pack-index.json")
        let index: EnginePackIndex
        do {
            index = try JSONDecoder().decode(EnginePackIndex.self, from: Data(contentsOf: indexURL))
        } catch {
            return XCTFail("无法解码 \(indexURL.path)：\(error.localizedDescription)")
        }
        for id in EngineCatalog.allIDs {
            guard let release = index.latest(for: id) else {
                XCTFail("\(id.rawValue) 在 pack-index.json 里没有发布记录")
                continue
            }
            XCTAssertFalse(release.version.isEmpty, "\(id.rawValue) 的最新版本号为空")
            XCTAssertFalse(release.sha256.isEmpty, "\(id.rawValue) 的最新发布缺 sha256")
            XCTAssertTrue(
                release.url.hasSuffix(".tar.gz"),
                "\(id.rawValue) 的下载地址不是 tar.gz：\(release.url)")
        }
    }

    /// 负向断言：假装新增了一个引擎 id，两张表都不会替它兜底——也就是说「新增
    /// 引擎但忘了加表项」会被上面那组正向断言当场抓住。
    ///
    /// 打开封堵的办法只有一个：像内置引擎一样补上 descriptor + 调优表 + 解析表。
    func testUnknownEngineIDIsCaughtByTheSameAssertions() throws {
        let fake = EngineAdapterID("teleportation")
        XCTAssertNil(
            EngineTuningProfile.registered(for: fake),
            "假 adapter 竟然能查到参数表项：表里混进了非 descriptor 的键？")
        XCTAssertNil(
            EngineStatusDialects.primaryStatusFormat[fake],
            "假 adapter 竟然有主状态格式")

        guard let fakeID = EngineID(rawValue: "teleport") else {
            return XCTFail("EngineID 接受不了合法的小写 id")
        }
        let descriptor = EngineCatalog.descriptor(for: fakeID)
        // 兜底 descriptor 必须能用（运行时装进来的 pack 不该让界面崩），
        // 但它没有表项——这正是「漏加表项」的信号。
        XCTAssertFalse(descriptor.capabilities.isEmpty)
        XCTAssertNil(EngineTuningProfile.registered(for: descriptor.adapter))
        XCTAssertNil(EngineStatusDialects.primaryStatusFormat[descriptor.adapter])
        // 兜底路径本身不能崩：解析一份空文档得到的是「只有状态」的空快照。
        let status = EngineStatusDialects.fold(.llamaProps, json: [:], fallbackState: .stopped)
        XCTAssertEqual(status.state, .stopped)
        XCTAssertNil(status.memoryBytes)
    }

    // MARK: - 辅助

    /// 仓库根下的文件。测试跑在检出目录里时才有；DerivedData / 打包环境里
    /// 直接跳过，而不是让 CI 因为找不到文件失败。
    private func repositoryFile(named name: String) throws -> URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { root.deleteLastPathComponent() }
        let candidate = root.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: candidate.path) else {
            throw XCTSkip("仓库根没有 \(name)：跳过依赖带外文件的检查")
        }
        return candidate
    }
}
