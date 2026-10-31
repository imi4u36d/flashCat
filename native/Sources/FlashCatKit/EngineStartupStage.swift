import Foundation

/// The phase an engine is in between `start()` and its first ready answer.
///
/// Engines report readiness, not progress. Splash answers `503` on `/ready`
/// until its weights are resident *and* its warmup passed, and it prints
/// nothing at all in between: a large MoE target can sit there for minutes.
/// The console therefore reads the stage off the engine's own log lines — and
/// only off phrases that name a real phase.
///
/// The earlier version matched the bare words `kv` and `context`, which the
/// memory-plan line every splash start prints ("Long requests keep their KV on
/// the SSD cache: 262144 tokens of context …") contains. Every start therefore
/// reported a 「准备上下文」 stage that no engine has; what actually ran behind
/// it was the warmup — arena assembly, the expert table streaming in, the
/// maximum-prefill and decode warmup, the memory audit — and, when macOS had
/// not released enough memory yet, the wait for it.
public enum EngineStartupStage: String, Sendable, Equatable, CaseIterable {
    /// Nothing the engine has said yet names a phase.
    case starting = "启动中"
    /// flashCat's serve script is preparing the assembly / linking the files.
    case preparing = "准备模型文件"
    case downloading = "下载模型"
    /// Weights are being read into memory.
    case loadingWeights = "加载权重"
    /// Weights are resident and the engine is warming up: memory plan, expert
    /// table, prefill and decode cycles, kernel (and ANE) setup.
    case warmingUp = "预热"
    /// The engine is blocked until macOS hands memory back.
    case waitingForMemory = "等待内存"
    case ready = "就绪"

    /// The stage implied by the newest log line that names one.
    ///
    /// - Parameter lines: the engine's own lines from the current run, newest
    ///   first. The app's own banner lines must be left out: they echo the whole
    ///   command line, `--max-context` included, and describe nothing.
    public static func derive(from lines: [String]) -> EngineStartupStage {
        for line in lines {
            if let stage = classify(line) { return stage }
        }
        return .starting
    }

    /// One line's stage, or nil when it names none.
    static func classify(_ line: String) -> EngineStartupStage? {
        let text = line.lowercased()
        guard !text.isEmpty else { return nil }
        for rule in rules where rule.matches(text) { return rule.stage }
        return nil
    }

    private struct Rule {
        let needles: [String]
        let stage: EngineStartupStage

        func matches(_ text: String) -> Bool {
            needles.contains { needle in
                // "ready" has to be a word of its own: oMLX prints "methods
                // already present upstream" on every start, and "already" is
                // not readiness.
                needle == "ready" ? EngineStartupStage.containsWord("ready", in: text) : text.contains(needle)
            }
        }
    }

    /// Most specific first: the same line often names two phases ("Weights
    /// loaded in 16.64 s." holds both "loaded" and "weights loaded").
    private static let rules: [Rule] = [
        Rule(needles: ["ready"], stage: .ready),
        Rule(needles: ["growth paused",
                       "waiting for sufficient available memory",
                       "out of memory",
                       "insufficient memory",
                       "memory pressure"],
             stage: .waitingForMemory),
        Rule(needles: ["weights loaded",
                       "warmup",
                       "warm-up",
                       "warming",
                       "ssd cache",
                       "kernel policy",
                       "keep their kv",
                       "decode cycles",
                       "neural engine",
                       "routed experts",
                       "ple table",
                       "calibrat"],
             stage: .warmingUp),
        Rule(needles: ["downloading", "download", "fetching", "下载"], stage: .downloading),
        Rule(needles: ["preparing", "prepare", "准备"], stage: .preparing),
        Rule(needles: ["loading", "loaded", "chat template", "load model"], stage: .loadingWeights),
    ]

    private static func containsWord(_ word: String, in text: String) -> Bool {
        var start = text.startIndex
        while let range = text.range(of: word, range: start..<text.endIndex) {
            let before = range.lowerBound > text.startIndex ? text[text.index(before: range.lowerBound)] : " "
            let after = range.upperBound < text.endIndex ? text[range.upperBound] : " "
            if !before.isLetter && !after.isLetter { return true }
            start = range.upperBound
        }
        return false
    }
}
