import XCTest
@testable import FlashCat

/// 用户点「停止」后的收尾：这一轮必须留在对话里，哪怕一个字都没来。
final class ChatStopTests: XCTestCase {
    func testStoppingEmptyReplyKeepsTheTurn() {
        var messages = [
            ChatMessage(role: "user", content: "介绍一下这个模型"),
            ChatMessage(role: "assistant", content: "", streaming: true),
        ]

        XCTAssertTrue(settleStreamingOnStop(&messages))

        XCTAssertEqual(messages.count, 2, "空回复被删掉的话，界面上就只剩用户那句")
        XCTAssertFalse(messages[1].streaming)
        XCTAssertTrue(messages[1].interrupted)
        XCTAssertEqual(messages[1].content, "")
    }

    func testStoppingPartialReplyKeepsWhatWasWritten() {
        var messages = [
            ChatMessage(role: "user", content: "写一段话"),
            ChatMessage(role: "assistant", content: "写到一半", streaming: true),
        ]

        settleStreamingOnStop(&messages)

        XCTAssertEqual(messages.last?.content, "写到一半")
        XCTAssertTrue(messages.last?.interrupted == true)
        XCTAssertFalse(messages.last?.streaming == true)
    }

    func testStoppingReasoningOnlyReplyKeepsTheThinkingBlock() {
        var messages = [
            ChatMessage(role: "user", content: "先想再答"),
            ChatMessage(role: "assistant", content: "", reasoning: "想了一半", streaming: true),
        ]

        settleStreamingOnStop(&messages)

        XCTAssertEqual(messages.last?.reasoning, "想了一半", "正文没来也不该把思考一起丢掉")
        XCTAssertEqual(messages.last?.content, "")
        XCTAssertTrue(messages.last?.interrupted == true)
    }

    func testSettleWithoutStreamingChangesNothing() {
        var messages = [
            ChatMessage(role: "user", content: "你好"),
            ChatMessage(role: "assistant", content: "你好，有什么可以帮你？"),
        ]

        XCTAssertFalse(settleStreamingOnStop(&messages))
        XCTAssertEqual(messages.count, 2)
        XCTAssertFalse(messages.contains(where: { $0.interrupted }))
    }

    func testHistoryKeepsInterruptedEmptyReply() {
        let messages = [
            ChatMessage(role: "user", content: "你好"),
            ChatMessage(role: "assistant", content: "", streaming: true),
            ChatMessage(role: "assistant", content: "", interrupted: true),
            ChatMessage(role: "assistant", content: ""),
        ]

        let savable = ChatHistory.savable(messages)

        XCTAssertEqual(savable.count, 2)
        XCTAssertEqual(savable.first?.role, "user")
        XCTAssertTrue(savable.last?.interrupted == true)
    }
}
