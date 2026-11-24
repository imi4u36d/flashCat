// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import Darwin
import FlashCatKit
import XCTest

@testable import FlashCat
@testable import FlashCatCore

/// `EngineController` 的生命周期测试。
///
/// 这个类原来零测试，而它的状态散在 `state`、`isStopping`、`busySince`、
/// `terminating`、`preparing` 五个互相牵制的值里，谁都能改，改错了只有界面
/// 能看出来。这里用一个真进程（临时目录里的 sh 脚本）走完整条生产路径：
/// 拉进程、读管道、启动看门狗、等退出回调，一个都不打桩；只有「引擎什么时候
/// 自报就绪、什么时候退出」由脚本 + 闸门文件控制 —— 断言因此不靠 `sleep`
/// 猜时序，也就不会在慢机器上偶发失败。
final class EngineControllerPhaseTests: XCTestCase {
    // MARK: - 夹具

    @MainActor
    private final class Fixture {
        /// 自造的引擎 id：`EngineCatalog` 对未知 id 返回默认描述符（standard
        /// 适配器、restart 换模型），正好绕开 splash/oMLX 那些专属分支。
        static let probeID = EngineID("phase-probe")
        static let probeModel = "phase-probe-model"

        let controller: EngineController
        let root: URL
        let packRoot: URL
        /// 闸门文件：脚本要等它出现才打印 `Ready ·`。
        let gate: URL
        private let support: URL
        private let settings: AppSettings
        private let previousModel: String
        private let previousEnvironment: [(key: String, value: String?)]

        /// - Parameters:
        ///   - script: 假引擎脚本正文。`{root}` 会替换成 pack 目录、`{gate}`
        ///     替换成闸门文件路径。传 nil 表示入口文件根本不存在，用来测
        ///     「进程拉不起来」那条失败路径。
        ///   - gateOpen: 闸门文件是否一开始就存在（存在 = 脚本一启动就自报就绪）。
        init(script: String?, gateOpen: Bool = false) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("flashcat-phase-\(UUID().uuidString)", isDirectory: true)
            packRoot = root.appendingPathComponent("pack", isDirectory: true)
            gate = root.appendingPathComponent("ready.gate")
            support = root.appendingPathComponent("support", isDirectory: true)
            let logs = root.appendingPathComponent("logs", isDirectory: true)
            try FileManager.default.createDirectory(at: packRoot, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            if gateOpen { try Data().write(to: gate) }

            // 路径每次都是现算的（`FlashCatPaths` 读环境变量），所以在进程内
            // 改这两个变量就足以把日志、pid 文件关进临时目录：测试不该往
            // 读者真实的 ~/Library 里写东西。
            previousEnvironment = ["FLASHCAT_SUPPORT_DIR", "FLASHCAT_LOGS_DIR"].map {
                ($0, ProcessInfo.processInfo.environment[$0])
            }
            setenv("FLASHCAT_SUPPORT_DIR", support.path, 1)
            setenv("FLASHCAT_LOGS_DIR", logs.path, 1)

            let port = try Fixture.freePort()

            if let script {
                let body =
                    script
                    .replacingOccurrences(of: "{root}", with: packRoot.path)
                    .replacingOccurrences(of: "{gate}", with: gate.path)
                let url = packRoot.appendingPathComponent("serve.sh")
                try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
                // 可执行位是 `Process.run()` 能起它的前提。
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: url.path)
            }

            let manifest = EngineManifest(
                id: Fixture.probeID,
                name: "Phase Probe",
                version: "0.0.1",
                kind: .bundled,
                entrypoint: "serve.sh",
                launchProfiles: [
                    "default": EngineLaunchProfile(
                        args: ["--port", "{port}", "--model", "{model}"])
                ],
                health: EngineHealthSpec(path: "/health"),
                defaultPort: port,
                modelSwitch: .restart,
                capabilities: [.chat])
            let installation = EngineInstallation(
                id: Fixture.probeID,
                manifest: manifest,
                root: packRoot)
            let settings = AppSettings()
            previousModel = settings.model
            // `restart()` 不传 requestedModel，`launchPlan` 会退回设置里的模型
            // （引擎配置里没有 lastModel），所以这里得先喂一个。
            settings.setModel(Fixture.probeModel)
            self.settings = settings
            controller = EngineController(
                id: Fixture.probeID,
                installation: installation,
                settings: settings,
                catalog: ModelCatalog(),
                port: port)
        }

        /// 停掉可能还活着的引擎，还原进程环境与设置，删掉临时目录。
        func dispose() {
            controller.prepareForTermination()
            controller.finishTermination()
            // pid 文件是最后一道保险：看门狗或强杀都可能还没落地。
            let pidFile = support.appendingPathComponent(Fixture.probeID.rawValue + ".pid")
            do {
                let raw = try String(contentsOfFile: pidFile.path, encoding: .utf8)
                if let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    kill(pid, SIGKILL)
                }
            } catch {
                // 没有 pid 文件说明进程早就没了，这正是期望的结果。
            }
            for entry in previousEnvironment {
                if let value = entry.value {
                    setenv(entry.key, value, 1)
                } else {
                    unsetenv(entry.key)
                }
            }
            settings.setModel(previousModel)
            do {
                try FileManager.default.removeItem(at: root)
            } catch {
                // 临时目录删不掉不影响断言，交给系统清理。
            }
        }

        /// 拿一个此刻空闲的回环端口再立刻还回去：`claimPort` 看到端口空闲就
        /// 直接用，不会去写全局的 engines.json，测试因此不碰读者的真实配置。
        private static func freePort() throws -> Int {
            let descriptor = socket(AF_INET, SOCK_STREAM, 0)
            guard descriptor >= 0 else { throw FixtureError(message: "socket() 失败") }
            defer { close(descriptor) }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = 0
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            // 限定 `Darwin.`：不限定的话闭包里这个名字会被解析成别处的实例
            // 方法（Darwin 的 C 函数与 Foundation 的同名 API 撞名字）。
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0 else { throw FixtureError(message: "bind() 失败") }
            var result = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let named = withUnsafeMutablePointer(to: &result) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.getsockname(descriptor, $0, &length)
                }
            }
            guard named == 0 else { throw FixtureError(message: "getsockname() 失败") }
            return Int(UInt16(bigEndian: result.sin_port))
        }
    }

    private struct FixtureError: Error {
        let message: String
    }

    // MARK: - 脚本

    /// 等闸门出现 → 自报就绪 → 常驻。`exec` 让进程直接变成 sleep：停止时
    /// SIGINT 打在它身上，不会留下一个孤儿 shell。
    private static let gatedReady = """
        while [ ! -f "{gate}" ]; do sleep 0.1; done
        echo 'Ready ·'
        exec sleep 30
        """

    /// 自报就绪后自己退出（退出码 0），用来测「就绪之后进程退出」。
    private static let readyThenExit = """
        echo 'Ready ·'
        sleep 0.3
        exit 0
        """

    /// 自报错误正文后异常退出，退出码 3。
    private static let errorThenExit = """
        echo 'error: boom'
        sleep 0.4
        exit 3
        """

    /// 连 SIGINT 都不理的引擎：停止只能靠 SIGKILL 升级。
    private static let stubbornReady = """
        trap '' INT
        echo 'Ready ·'
        while true; do sleep 0.2; done
        """

    // MARK: - 用例

    /// 点下启动 → starting → 引擎自报 Ready → ready，且派生属性跟着走。
    @MainActor
    func testStartReachesReadyOnReadyLine() async throws {
        let fixture = try Fixture(script: Self.gatedReady)
        defer { fixture.dispose() }
        let controller = fixture.controller

        await controller.start()
        await awaitPhase(controller, "启动中", matches: isStarting)

        // 点下启动到就绪之间只能有一个状态：原来这一段是 `state == .starting`
        // 加 `preparing` 两个值，现在都该由 `phase` 决定。
        XCTAssertEqual(controller.state, .starting)
        XCTAssertTrue(controller.isRunning)
        XCTAssertFalse(controller.isReady)
        XCTAssertNotNil(controller.busySeconds)

        try Data().write(to: fixture.gate)
        await awaitPhase(controller, "就绪", matches: { $0 == .ready })

        XCTAssertEqual(controller.state, .ready)
        XCTAssertTrue(controller.isReady)
        XCTAssertTrue(controller.isRunning)
        XCTAssertEqual(controller.startupStage, EngineStartupStage.ready.rawValue)
        // 「已等待」是启动阶段的计数器：就绪之后界面上那一段已经被「运行中」
        // 取代，计时不该再涨。
        XCTAssertNil(controller.busySeconds)
    }

    /// 还在做准备（下载 draft、等端口）时点停止：不能再把进程拉起来。
    @MainActor
    func testStopDuringPreparationKeepsStopped() async throws {
        let fixture = try Fixture(script: "exec sleep 30")
        defer { fixture.dispose() }
        let controller = fixture.controller

        controller.prepareForStart = { _ in
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
            } catch {
                return .failed("准备被取消")
            }
            return .ready(nil)
        }

        let launch = Task { await controller.start() }
        await awaitPhase(controller, "启动中", matches: isStarting)
        controller.stop()

        await launch.value
        if case .starting = controller.phase {
            XCTFail("停止之后启动还在继续：phase = \(controller.phase)")
        }
        XCTAssertFalse(controller.isRunning)
        XCTAssertEqual(controller.state, .stopped)
        XCTAssertFalse(
            controller.logs.tail(60).contains { $0.text.contains("flashCat 启动") },
            "准备阶段被打断，进程根本不该被拉起")
    }

    /// 进程已经拉起、还没就绪时点停止：进程要真的停下。
    @MainActor
    func testStopWhileStartingStopsTheProcess() async throws {
        let fixture = try Fixture(script: "exec sleep 30")
        defer { fixture.dispose() }
        let controller = fixture.controller

        await controller.start()
        await awaitPhase(controller, "启动中", matches: isStarting)
        XCTAssertTrue(controller.isRunning)

        controller.stop()
        XCTAssertEqual(controller.state, .stopping)
        await awaitPhase(controller, "已停止", timeout: 10, matches: { $0 == .stopped })
        XCTAssertFalse(controller.isRunning)
        XCTAssertEqual(controller.state, .stopped)
    }

    /// 就绪之后进程自己退出（退出码 0）：回到 stopped，不是 failed。
    @MainActor
    func testProcessExitAfterReadyBecomesStopped() async throws {
        let fixture = try Fixture(script: Self.readyThenExit)
        defer { fixture.dispose() }
        let controller = fixture.controller

        await controller.start()
        await awaitPhase(controller, "就绪", matches: { $0 == .ready })
        await awaitPhase(controller, "已停止", timeout: 10, matches: { $0 == .stopped })

        XCTAssertFalse(controller.isRunning)
        XCTAssertNil(controller.failureMessage)
    }

    /// 进程拉不起来：failed(reason) 带着正文，阶段报「启动失败」。
    @MainActor
    func testStartFailureRecordsReason() async throws {
        let fixture = try Fixture(script: nil)
        defer { fixture.dispose() }
        let controller = fixture.controller

        await controller.start()
        await awaitPhase(controller, "失败", matches: { failureReason($0) != nil })

        let reason = failureReason(controller.phase) ?? ""
        XCTAssertTrue(reason.contains("无法启动服务"), "失败正文应为拉起错误，实际是「\(reason)」")
        XCTAssertEqual(controller.failureMessage, reason)
        XCTAssertEqual(controller.state, .failed)
        XCTAssertEqual(controller.startupStage, "启动失败")
        XCTAssertFalse(controller.isRunning)
    }

    /// 引擎自己报的错误正文要活到失败之后：只报退出码对读者没有用。
    @MainActor
    func testErrorLineBecomesFailureReason() async throws {
        let fixture = try Fixture(script: Self.errorThenExit)
        defer { fixture.dispose() }
        let controller = fixture.controller

        await controller.start()
        await awaitPhase(controller, "失败", timeout: 10, matches: { failureReason($0) != nil })

        XCTAssertEqual(failureReason(controller.phase), "boom")
        XCTAssertEqual(controller.failureMessage, "boom")
    }

    /// 迟到的 Ready 必须在进程已经没了之后被丢弃：否则 `isRunning` 为假、
    /// `isReady` 为真，聊天请求会打到一个已经关掉的回环端口。
    @MainActor
    func testLateReadySignalIsDropped() async throws {
        let fixture = try Fixture(script: "exit 0")
        defer { fixture.dispose() }
        let controller = fixture.controller

        await controller.start()
        await awaitPhase(controller, "已停止", timeout: 10, matches: { $0 == .stopped })
        XCTAssertFalse(controller.isRunning)

        // 读线程晚到的那行 `Ready ·` 走的就是 markReady()：日志入库路径发现
        // 就绪信号后只调这一个入口，守卫与迁移表都在它里面。
        controller.markReady()
        XCTAssertEqual(controller.phase, .stopped)
        XCTAssertFalse(controller.isReady)
        XCTAssertTrue(
            controller.logs.tail(20).contains {
                $0.text.contains("忽略迟到的就绪信号")
            }, "迟到的就绪信号应留下一条告警：日志页是这套系统唯一的排查入口")
    }

    /// 停止过程中到达的 Ready 不能把状态推回 ready：那是「已点退出、界面又亮
    /// 起可聊天」的来源。迁移表拦住它，并且要留下告警。
    @MainActor
    func testReadyWhileStoppingIsRejected() async throws {
        let fixture = try Fixture(script: Self.stubbornReady)
        defer { fixture.dispose() }
        let controller = fixture.controller

        await controller.start()
        await awaitPhase(controller, "就绪", matches: { $0 == .ready })

        controller.stop()
        await awaitPhase(controller, "停止中", matches: isStopping)
        // 引擎忽略了 SIGINT，进程还在；这时它再喊一次就绪。
        controller.markReady()

        if case .stopping = controller.phase {
            // 期望：被拒。
        } else {
            XCTFail("停止中不应被推回就绪：phase = \(controller.phase)")
        }
        XCTAssertEqual(controller.state, .stopping)
        XCTAssertTrue(
            controller.logs.tail(20).contains {
                $0.text.contains("忽略非法的状态迁移")
            }, "被拒绝的迁移应留下告警，而不是悄悄接受")

        // 收尾：SIGINT 没用，靠 1 秒后的 SIGKILL 升级把它杀掉。
        let stopped = await controller.stopAndWait(grace: 1, timeout: 15)
        XCTAssertTrue(stopped, "强制结束之后进程应已退出")
        await awaitPhase(controller, "已停止", timeout: 5, matches: { $0 == .stopped })
    }

    /// 连续 restart：每一次都要真的回到 ready，而不是停在中间态。
    @MainActor
    func testRepeatedRestartReachesReadyEachTime() async throws {
        let fixture = try Fixture(script: Self.gatedReady, gateOpen: true)
        defer { fixture.dispose() }
        let controller = fixture.controller

        await controller.restart()
        await awaitPhase(controller, "第一次就绪", timeout: 10, matches: { $0 == .ready })

        await controller.restart()
        await awaitPhase(controller, "第二次就绪", timeout: 15, matches: { $0 == .ready })

        XCTAssertEqual(controller.state, .ready)
        XCTAssertTrue(controller.isRunning)
        // 拉起横幅是「这一次启动真的走完了」的证据，两次就该有两条。
        let banners = controller.logs.tail(200).filter { $0.text.contains("flashCat 启动") }
        XCTAssertEqual(banners.count, 2, "两次启动应各留一条横幅：\(banners.map(\.text))")
    }

    /// 停止之后再启动：同一个控制器要能重来一次。
    @MainActor
    func testStopThenStartAgainReachesReady() async throws {
        let fixture = try Fixture(script: Self.gatedReady, gateOpen: true)
        defer { fixture.dispose() }
        let controller = fixture.controller

        await controller.start()
        await awaitPhase(controller, "第一次就绪", timeout: 10, matches: { $0 == .ready })

        controller.stop()
        await awaitPhase(controller, "已停止", timeout: 10, matches: { $0 == .stopped })

        await controller.start()
        await awaitPhase(controller, "第二次就绪", timeout: 10, matches: { $0 == .ready })
        XCTAssertTrue(controller.isRunning)
        XCTAssertEqual(controller.state, .ready)
    }
}

// MARK: - 断言工具

/// 引擎自报的错误正文。`lastError` 要能活到失败之后，测试因此得从 phase 里读。
private func failureReason(_ phase: EngineController.Phase) -> String? {
    if case .failed(let reason) = phase { return reason }
    return nil
}

/// 启动进行中（含做准备工作的那一段）。
private func isStarting(_ phase: EngineController.Phase) -> Bool {
    if case .starting = phase { return true }
    return false
}

/// 已经发过停止信号、等进程退干净。
private func isStopping(_ phase: EngineController.Phase) -> Bool {
    if case .stopping = phase { return true }
    return false
}

/// 等控制器到达期望状态。轮询而不是等通知：`onChange` 只说「有东西变了」，
/// 测试要断言的是「变成了什么」。超时把当前状态和日志尾巴一起报出来，
/// 免得失败信息只有一句「超时」。
@MainActor
private func awaitPhase(
    _ controller: EngineController,
    _ description: String,
    timeout: TimeInterval = 5,
    matches: (EngineController.Phase) -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if matches(controller.phase) { return }
        do {
            try await Task.sleep(nanoseconds: 20_000_000)
        } catch {
            XCTFail("等待「\(description)」时测试被取消", file: file, line: line)
            return
        }
    }
    let tail = controller.logs.tail(20).map(\.text).joined(separator: "\n")
    XCTFail(
        "等待「\(description)」超时：当前 phase = \(controller.phase)\n最近的日志：\n\(tail)",
        file: file, line: line)
}
