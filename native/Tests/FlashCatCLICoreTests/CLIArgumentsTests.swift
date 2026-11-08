import XCTest
@testable import FlashCatCLICore

final class CLIArgumentsTests: XCTestCase {
    func testBareInvocationDefaultsToStatus() throws {
        let invocation = try CLIArguments.parse([])
        XCTAssertEqual(invocation.command, "status")
        XCTAssertFalse(invocation.explicitCommand)
    }

    func testGroupAndSubcommandAreSplit() throws {
        let invocation = try CLIArguments.parse(["engines", "start", "omlx", "--json"])
        XCTAssertEqual(invocation.command, "engines")
        XCTAssertEqual(invocation.subcommand, "start")
        XCTAssertEqual(invocation.arguments, ["omlx"])
        XCTAssertTrue(invocation.flag("json"))
        XCTAssertTrue(invocation.explicitCommand)
    }

    func testOptionsAcceptBothSpellings() throws {
        let spaced = try CLIArguments.parse(["models", "download", "org/repo", "--engine", "omlx"])
        XCTAssertEqual(spaced.option("engine"), "omlx")
        let joined = try CLIArguments.parse(["models", "download", "org/repo", "--engine=omlx"])
        XCTAssertEqual(joined.option("engine"), "omlx")
    }

    func testShortFlagsAndValues() throws {
        let invocation = try CLIArguments.parse(["chat", "hi", "-j", "-m", "Qwen"])
        XCTAssertTrue(invocation.flag("json"))
        XCTAssertEqual(invocation.option("model"), "Qwen")
        XCTAssertEqual(invocation.arguments, ["hi"])
    }

    func testUnknownOptionFails() {
        XCTAssertThrowsError(try CLIArguments.parse(["status", "--nope"])) { error in
            guard case CLIUsageError.unknownOption(let option) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(option, "--nope")
        }
    }

    func testMissingValueFails() {
        XCTAssertThrowsError(try CLIArguments.parse(["chat", "--model"])) { error in
            guard case CLIUsageError.missingValue(let option) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(option, "--model")
        }
    }

    func testDoubleDashStopsOptionParsing() throws {
        let invocation = try CLIArguments.parse(["chat", "--", "--not-a-flag"])
        XCTAssertEqual(invocation.arguments, ["--not-a-flag"])
    }

    func testAliases() throws {
        XCTAssertEqual(try CLIArguments.parse(["ls"]).subcommand, "list")
        XCTAssertEqual(try CLIArguments.parse(["ask", "hi"]).command, "chat")
        XCTAssertEqual(try CLIArguments.parse(["ps"]).command, "status")
        let start = try CLIArguments.parse(["start", "omlx"])
        XCTAssertEqual(start.command, "engines")
        XCTAssertEqual(start.subcommand, "start")
    }

    func testVersionIsAFlagNotAValueOption() throws {
        let invocation = try CLIArguments.parse(["status", "--version"])
        XCTAssertTrue(invocation.flag("version"))
    }

    func testListOptionSplitsCommas() throws {
        let invocation = try CLIArguments.parse(["models", "download", "repo", "--for", "omlx,mtplx"])
        XCTAssertEqual(invocation.listOption("for"), ["omlx", "mtplx"])
    }

    func testRepeatedListOptionAccumulates() throws {
        let invocation = try CLIArguments.parse([
            "models", "download", "repo", "--for", "omlx", "--for", "mtplx",
        ])
        XCTAssertEqual(invocation.listOption("for"), ["omlx", "mtplx"])
        XCTAssertEqual(invocation.option("for"), "omlx,mtplx")
    }

    func testNumericOptionRejectsATypo() {
        XCTAssertThrowsError(try CLIArguments.parse(["status", "--timeout", "soon"])) { error in
            guard case CLIUsageError.badValue(let message) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertTrue(message.contains("--timeout"))
        }
        XCTAssertThrowsError(try CLIArguments.parse(["chat", "hi", "-t", "abc"]))
    }

    func testLastScalarOptionWins() throws {
        let invocation = try CLIArguments.parse(["chat", "hi", "--model", "A", "--model", "B"])
        XCTAssertEqual(invocation.option("model"), "B")
    }
}
