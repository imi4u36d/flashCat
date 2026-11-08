import XCTest
@testable import FlashCatCLICore

final class CLIOutputTests: XCTestCase {
    func testJSONOutputStaysCleanAndColorless() {
        var stdout = ""
        let output = CLIOutput(json: true, color: true, stdout: { stdout += $0 })
        output.line(output.red("boom"))
        XCTAssertEqual(stdout, "boom\n")
    }

    func testQuietSuppressesNotesButNotResults() {
        var stdout = ""
        var stderr = ""
        let output = CLIOutput(quiet: true, stdout: { stdout += $0 }, stderr: { stderr += $0 })
        output.line("result")
        output.note("progress")
        output.success("done")
        XCTAssertEqual(stdout, "result\n")
        XCTAssertEqual(stderr, "")
    }

    func testTablePadsAndPrintsHeader() {
        var stdout = ""
        let output = CLIOutput(json: false, color: false, stdout: { stdout += $0 })
        output.table(headers: ["A", "B"], rows: [["x", "yy"], ["long", "z"]])
        XCTAssertTrue(stdout.contains("A"))
        XCTAssertTrue(stdout.contains("──"))
        XCTAssertTrue(stdout.contains("long"))
    }

    func testTableMeasuresCJKHeadersByDisplayWidth() {
        var stdout = ""
        let output = CLIOutput(json: false, color: false, stdout: { stdout += $0 })
        output.table(headers: ["命令", "说明"], rows: [["状态", "引擎与网关"]])
        let lines = stdout.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3)
        // Header and body start their second column at the same column.
        XCTAssertEqual(lines[0].firstIndex(of: "说"), lines[2].firstIndex(of: "引"))
    }

    func testTableToleratesRaggedRows() {
        var stdout = ""
        let output = CLIOutput(json: false, color: false, stdout: { stdout += $0 })
        output.table(headers: ["A"], rows: [["x", "extra"]])
        XCTAssertTrue(stdout.contains("extra"))
    }

    func testErrorsAndHintsAreSeparate() {
        var stderr = ""
        let output = CLIOutput(json: true, stdout: { _ in }, stderr: { stderr += $0 })
        output.jsonError(CLIError("bad", exit: .usage, hint: "try --help"))
        XCTAssertTrue(stderr.contains("\"ok\" : false"))
        XCTAssertTrue(stderr.contains("try --help"))
    }
}
