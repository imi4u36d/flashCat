// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

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

    /// `flag("json")` 是唯一的 json 判定。组合短选项、带值写法、分开的 true/false
    /// 都必须落到同一处，否则会出现「报错出 JSON、结果出人类文本」的半开状态。
    func testBooleanValueSpellingsAllLandInFlags() throws {
        let combined = try CLIArguments.parse(["-jq"])
        XCTAssertTrue(combined.flag("json"))
        XCTAssertTrue(combined.flag("quiet"))

        let inlineFalse = try CLIArguments.parse(["--json=false"])
        XCTAssertFalse(inlineFalse.flag("json"))
        XCTAssertEqual(inlineFalse.command, "status")

        let inlineTrue = try CLIArguments.parse(["--json=true"])
        XCTAssertTrue(inlineTrue.flag("json"))

        let explicit = try CLIArguments.parse(["--json", "true"])
        XCTAssertTrue(explicit.flag("json"))
        // `true` 是 json 的取值，不该变成命令或参数。
        XCTAssertEqual(explicit.command, "status")
        XCTAssertFalse(explicit.explicitCommand)

        let separated = try CLIArguments.parse(["--json", "--quiet"])
        XCTAssertTrue(separated.flag("json"))
        XCTAssertTrue(separated.flag("quiet"))

        // 关闭的写法同样归一：先开再关，最终是关。
        let disabled = try CLIArguments.parse(["--json", "--json=false"])
        XCTAssertFalse(disabled.flag("json"))
    }

    func testBooleanOptionDoesNotSwallowCommands() throws {
        let invocation = try CLIArguments.parse(["--json", "status"])
        XCTAssertTrue(invocation.flag("json"))
        XCTAssertEqual(invocation.command, "status")
        XCTAssertTrue(invocation.explicitCommand)
    }

    func testBooleanOptionRejectsANonBooleanValue() {
        XCTAssertThrowsError(try CLIArguments.parse(["--json=maybe"])) { error in
            guard case CLIUsageError.badValue(let message) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertTrue(message.contains("--json"))
        }
    }

    /// 宽容解析必须先收集错误再扫完参数：CLI.run 要靠它拿到 --json/--no-color 才能
    /// 让用法错误走同样的输出约定。抛错版本保持原有语义。
    func testTolerantParseReportsTheFirstErrorAndKeepsScanning() {
        let result = CLIArguments.parseTolerant(["--json", "status", "--nope", "--quiet"])
        XCTAssertTrue(result.invocation.flag("json"))
        XCTAssertTrue(result.invocation.flag("quiet"))
        XCTAssertEqual(result.invocation.command, "status")
        guard case CLIUsageError.unknownOption(let option)? = result.error else {
            return XCTFail("wrong error: \(String(describing: result.error))")
        }
        XCTAssertEqual(option, "--nope")
        XCTAssertThrowsError(try CLIArguments.parse(["--nope"]))
    }
}
