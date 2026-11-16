import Foundation
import XCTest
@testable import FlashCatCLICore
import FlashCatKit

/// 控制接口「发现」阶段的错误以前被 `try? context.control` 折叠：`--control-port abc`
/// 这种用法错误会静默退回离线视图并 exit 0，`config set` 还会真的把值写进本地偏好。
/// 降级判据只有 `.notRunning`（没有 control.json / 没有令牌），与 `ControlFallback`
/// 同源；这几个测试把「不该降级的分支」钉住，免得下次又被 `try?` 折叠回去。
final class ControlDiscoveryFallbackTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var configurationFile = ""

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "flashcat-control-discovery-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let directory = NSTemporaryDirectory() + "/flashcat-control-discovery-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        configurationFile = directory + "/engines.json"
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        let directory = (configurationFile as NSString).deletingLastPathComponent
        if FileManager.default.fileExists(atPath: directory) {
            try FileManager.default.removeItem(atPath: directory)
        }
        try super.tearDownWithError()
    }

    private func makeContext(command: String = "config",
                             subcommand: String? = nil,
                             arguments: [String] = [],
                             options: [String: String] = [:]) -> CLIContext {
        let local = LocalState(environment: [:], defaults: defaults,
                               engineConfigurationFile: configurationFile)
        return CLIContext(invocation: CLIInvocation(command: command, subcommand: subcommand,
                                                    arguments: arguments, options: options),
                          environment: [:],
                          output: CLIOutput(),
                          local: local,
                          isTTY: false,
                          stdinIsTTY: false,
                          executable: "/usr/local/bin/flashcat")
    }

    private func expectUsageError(_ operation: () async throws -> Int32,
                                  _ message: String) async {
        do {
            let code = try await operation()
            XCTFail("\(message)：命令居然成功了（exit \(code)）")
        } catch let error as CLIError {
            XCTAssertEqual(error.exit, .usage, "\(message)：退出码应是用法错误，实际 \(error.exit)")
        } catch {
            XCTFail("\(message)：错误类型不对：\(error)")
        }
    }

    // MARK: 不该降级的分支

    func testConfigSetWithInvalidControlPortFailsInsteadOfWritingOffline() async {
        // `try?` 时代这里会先吞掉用法错误，再落到 OfflineConfig 把 appearance 写进偏好。
        let context = makeContext(subcommand: "set",
                                  arguments: ["appearance", "dark"],
                                  options: ["control-port": "abc"])
        await expectUsageError({ try await ConfigCommand.run(context) },
                               "无效的 --control-port")
        XCTAssertNil(defaults.object(forKey: "appearance"),
                     "命令失败时不应已经把设置写进本地偏好")
    }

    func testConfigListWithNonLocalControlURLFailsInsteadOfPrintingDiskValues() async {
        // 非本机地址会被 `ControlLocation.discover` 拒绝：这是参数问题，不是「应用没在跑」。
        let context = makeContext(subcommand: "list",
                                  options: ["control-url": "ftp://127.0.0.1:9100"])
        await expectUsageError({ try await ConfigCommand.run(context) },
                               "非 http(s) 的 --control-url")
    }

    func testConfigUnsetWithInvalidControlPortFailsInsteadOfTouchingDisk() async {
        let context = makeContext(subcommand: "unset",
                                  arguments: ["systemPrompt"],
                                  options: ["control-port": "abc"])
        await expectUsageError({ try await ConfigCommand.run(context) },
                               "无效的 --control-port")
        XCTAssertNil(defaults.object(forKey: "chat.system"),
                     "命令失败时不应清空本地偏好")
    }

    func testEnginesPortWithInvalidControlPortFailsInsteadOfReadingLocalConfig() async {
        // 读端口以前是 `try? context.control` + `try? get`，两处都能把用法错误和 401
        // 折成「本地旧值 + exit 0」，用户会误以为在线值就是本地那个。
        let context = makeContext(command: "engines", subcommand: "port",
                                  arguments: ["omlx"],
                                  options: ["control-port": "abc"])
        await expectUsageError({ try await EnginesCommand.run(context) },
                               "无效的 --control-port")
    }

    // MARK: 该降级的分支

    func testConfigSetStillWritesOfflineWhenTheAppIsNotRunning() async throws {
        // 空令牌等价于「控制接口找不到」：discover 抛 .notRunning，这时离线写入才是对的。
        let context = makeContext(subcommand: "set",
                                  arguments: ["appearance", "dark"],
                                  options: ["control-port": "9100", "control-token": ""])
        let code = try await ConfigCommand.run(context)
        XCTAssertEqual(code, CLIExit.success.rawValue)
        XCTAssertEqual(defaults.integer(forKey: "appearance"), 2,
                       "应用没在运行时应当写入离线偏好（dark = 2）")
    }

    func testEnginesListFallsBackToDiskOnlyWhenTheAppIsNotRunning() async throws {
        let context = makeContext(command: "engines", subcommand: "list",
                                  options: ["control-port": "9100", "control-token": ""])
        let code = try await EnginesCommand.run(context)
        XCTAssertEqual(code, CLIExit.success.rawValue)
    }
}
