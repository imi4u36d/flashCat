import XCTest
@testable import FlashCatCLICore

final class CLIOutputTests: XCTestCase {
    func testJSONOutputStaysCleanAndColorless() {
        var stdout = ""
        let output = CLIOutput(json: true, color: true, stdout: { stdout += $0; return true })
        output.line(output.red("boom"))
        XCTAssertEqual(stdout, "boom\n")
    }

    func testQuietSuppressesNotesButNotResults() {
        var stdout = ""
        var stderr = ""
        let output = CLIOutput(quiet: true, stdout: { stdout += $0; return true }, stderr: { stderr += $0; return true })
        output.line("result")
        output.note("progress")
        output.success("done")
        XCTAssertEqual(stdout, "result\n")
        XCTAssertEqual(stderr, "")
    }

    func testTablePadsAndPrintsHeader() {
        var stdout = ""
        let output = CLIOutput(json: false, color: false, stdout: { stdout += $0; return true })
        output.table(headers: ["A", "B"], rows: [["x", "yy"], ["long", "z"]])
        XCTAssertTrue(stdout.contains("A"))
        XCTAssertTrue(stdout.contains("──"))
        XCTAssertTrue(stdout.contains("long"))
    }

    func testTableMeasuresCJKHeadersByDisplayWidth() {
        var stdout = ""
        let output = CLIOutput(json: false, color: false, stdout: { stdout += $0; return true })
        output.table(headers: ["命令", "说明"], rows: [["状态", "引擎与网关"]])
        let lines = stdout.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3)
        // Header and body start their second column at the same column.
        XCTAssertEqual(lines[0].firstIndex(of: "说"), lines[2].firstIndex(of: "引"))
    }

    func testTableToleratesRaggedRows() {
        var stdout = ""
        let output = CLIOutput(json: false, color: false, stdout: { stdout += $0; return true })
        output.table(headers: ["A"], rows: [["x", "extra"]])
        XCTAssertTrue(stdout.contains("extra"))
    }

    func testErrorsAndHintsAreSeparate() {
        var stderr = ""
        let output = CLIOutput(json: true, stdout: { _ in true }, stderr: { stderr += $0; return true })
        output.jsonError(CLIError("bad", exit: .usage, hint: "try --help"))
        XCTAssertTrue(stderr.contains("\"ok\" : false"))
        XCTAssertTrue(stderr.contains("try --help"))
    }

    /// 下游提前关掉 stdout（`flashcat chat … | head -1`）之后 EPIPE 不会自愈：
    /// 第一次失败就要置位 brokenPipe 并停止再写，否则每条 token 都会白撞一次。
    func testBrokenPipeStopsFurtherWrites() {
        var attempts = 0
        let output = CLIOutput(json: false,
                               color: false,
                               stdout: { _ in
                                   attempts += 1
                                   return false
                               },
                               stderr: { _ in true })
        output.line("first")
        output.line("second")
        output.table(headers: ["A"], rows: [["x"]])
        XCTAssertTrue(output.brokenPipe)
        XCTAssertEqual(attempts, 1)
    }

    /// SIGPIPE 忽略后写失败只是一个返回值：CLI 按 coreutils 约定仍然退出 0，
    /// 也不该因为 FileHandle 的 ObjC 异常把进程带走。
    func testBrokenPipeStillExitsZero() async {
        let code = await CLI.run(arguments: ["version"],
                                 environment: ["FLASHCAT_VERSION": "9.9.9"],
                                 stdout: { _ in false },
                                 stderr: { _ in true },
                                 isTTY: false,
                                 stdinIsTTY: false)
        XCTAssertEqual(code, 0)
    }

    /// 用法错误也要遵守成功路径的输出约定：`--json` 时 stdout 保持干净、错误走 stderr。
    /// 以前这条路径另建了一个 CLIOutput，json 是预扫描猜的。
    func testUsageErrorHonorsJSON() async {
        var stdout = ""
        var stderr = ""
        let code = await CLI.run(arguments: ["status", "--json", "--nope"],
                                 environment: [:],
                                 stdout: { stdout += $0; return true },
                                 stderr: { stderr += $0; return true },
                                 isTTY: false,
                                 stdinIsTTY: false)
        XCTAssertEqual(code, CLIExit.usage.rawValue)
        XCTAssertEqual(stdout, "")
        XCTAssertTrue(stderr.contains("\"ok\" : false"))
        XCTAssertTrue(stderr.contains("--nope"))
    }

    /// `--no-color` 在参数错误时同样生效，而不是只在解析成功后才被读到。
    func testUsageErrorHonorsNoColor() async {
        var stderr = ""
        _ = await CLI.run(arguments: ["status", "--no-color", "--nope"],
                          environment: [:],
                          stdout: { _ in true },
                          stderr: { stderr += $0; return true },
                          isTTY: true,
                          stdinIsTTY: false)
        XCTAssertFalse(stderr.contains("\u{001B}["))
        XCTAssertTrue(stderr.contains("--nope"))
    }
}
