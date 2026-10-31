import XCTest
@testable import FlashCatKit

/// The stage text is the only progress the console has while an engine loads,
/// so it must stay honest: these cases are the real log lines this machine
/// produced, newest first.
final class EngineStartupStageTests: XCTestCase {
    /// A splash start of the Q2 GGUF MoE target: weights in 16 s, then the
    /// silent warmup that takes minutes.
    private let splashWarmup = [
        "Long requests keep their KV on the SSD cache: 262144 tokens of context (bound: model; window 262144, resident 262144, spilled 262144, disk 262144); a request whose KV fits 39881 MiB stays in memory; hot block cache 390 MiB (floor 390 MiB); history staging in 2 buffers; SSD room for active KV 32.0 GiB.",
        "Kernel policy for GPU family 10 with 40 cores.",
        "SSD cache: up to 32.0 GiB of temporary files in /var/folders/qk/… (its automatic quota, while its volume has room beyond the 10.0 GiB it keeps free); KV pages of 416 KiB and states of 113 MiB; --max-cache-disk 0 turns it off.",
        "Decode cycles verify the rows the verify budget chooses (--verify-rows auto, as /Users/wangzhuo/.flashcat/models/ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF/Qwen3.8-Flash-Next-GSQ-RCO-Q2_0-00001-of-00002.gguf is a MoE target)",
        "Routed experts load with their layers: memory holds their 32402 MiB (--expert-memory auto).",
        "The PLE table loads with the weights: memory holds its 27465 MiB (--ple-memory auto).",
        "Weights loaded in 16.64 s.",
        "Chat template · patched to render later system messages in place (the original template rejects them), generation prompt 5-7 tokens",
        "Loading · ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF",
    ]

    /// The whole post-load stretch reports one phase, and it is the warmup.
    func testSplashPostLoadStretchIsWarmupNotAContextStage() {
        XCTAssertEqual(EngineStartupStage.derive(from: splashWarmup), .warmingUp)
        XCTAssertEqual(EngineStartupStage.warmingUp.rawValue, "预热")
        XCTAssertFalse(EngineStartupStage.allCases.contains { $0.rawValue.contains("上下文") })
    }

    /// Every line of that stretch on its own, so a rule that only works because
    /// an older line spoke up cannot hide here.
    func testEachPostLoadLineNamesTheWarmup() {
        for line in splashWarmup.prefix(7) {
            XCTAssertEqual(EngineStartupStage.derive(from: [line]), .warmingUp, line)
        }
    }

    func testWeightLoadLinesNameTheLoad() {
        for line in ["Loading · omlx/Qwen3.8-27B-oQ4e-mtp-e5133ef4",
                     "Chat template · patched to render later system messages in place",
                     "Loaded settings for 36 models"] {
            XCTAssertEqual(EngineStartupStage.derive(from: [line]), .loadingWeights, line)
        }
    }

    /// The engine blocking on macOS memory is its own stage: that is what the
    /// four-minute start on this machine actually was.
    func testWaitingForMemoryIsItsOwnStage() {
        for line in ["Waiting for sufficient available memory to start; the macOS reserve remains protected...",
                     "Memory: growth paused; waiting=0; suspended=0"] {
            XCTAssertEqual(EngineStartupStage.derive(from: [line]), .waitingForMemory, line)
        }
    }

    func testReadyLineWins() {
        XCTAssertEqual(EngineStartupStage.derive(from: ["Ready · ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF · context 256K · http://127.0.0.1:8000"]),
                       .ready)
        var lines = splashWarmup
        lines.insert("Ready · ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF · context 256K · http://127.0.0.1:8000", at: 0)
        XCTAssertEqual(EngineStartupStage.derive(from: lines), .ready)
    }

    /// "already" must not read as "ready": oMLX prints it on every start, and
    /// the engine would show 就绪 while it is still booting.
    func testAlreadyIsNotReady() {
        XCTAssertEqual(EngineStartupStage.derive(from: ["ChunkedKVCache patch: methods already present upstream, skipped: size"]),
                       .starting)
        XCTAssertEqual(EngineStartupStage.derive(from: ["ChunkedKVCache patch: methods already present upstream, skipped: size",
                                                       "Loaded settings for 36 models"]),
                       .loadingWeights)
    }

    func testNothingSaidYet() {
        XCTAssertEqual(EngineStartupStage.derive(from: []), .starting)
        XCTAssertEqual(EngineStartupStage.derive(from: ["", "   "]), .starting)
    }

    /// MTPLX names its warmup in the box it prints before the port opens.
    func testMtplxLines() {
        XCTAssertEqual(EngineStartupStage.derive(from: ["│     Warmup  16 tokens"]), .warmingUp)
        XCTAssertEqual(EngineStartupStage.derive(from: ["│     Warmup  16 tokens",
                                                       "│    Loading  /Users/wangzhuo/Library/Application"]),
                       .warmingUp)
        XCTAssertEqual(EngineStartupStage.derive(from: ["│    Loading  /Users/wangzhuo/Library/Application"]),
                       .loadingWeights)
    }
}
