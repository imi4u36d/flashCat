import XCTest
@testable import FlashCatKit

final class StatusParserTests: XCTestCase {

    // MARK: helpers

    private func fixture(_ name: String, in folder: String) throws -> Data {
        let bundle = Bundle.module
        guard let base = bundle.url(forResource: "Fixtures", withExtension: nil) else {
            throw XCTSkip("Fixtures directory missing from test bundle")
        }
        let url = base.appendingPathComponent(folder).appendingPathComponent(name)
        return try Data(contentsOf: url)
    }

    /// Samples captured with `curl -i` start with response headers; strip them.
    private func json(_ data: Data) throws -> [String: Any] {
        var body = data
        if let text = String(data: data, encoding: .utf8), text.hasPrefix("HTTP/") {
            guard let range = data.range(of: Data("\r\n\r\n".utf8)) else {
                throw XCTSkip("malformed header block")
            }
            body = data.subdata(in: range.upperBound..<data.count)
        }
        let object = try JSONSerialization.jsonObject(with: body)
        return try XCTUnwrap(object as? [String: Any])
    }

    private func load(_ name: String, _ folder: String) throws -> [String: Any] {
        try json(try fixture(name, in: folder))
    }

    // MARK: oMLX

    func testOMLXStatusMapsCountersAndMemory() throws {
        let status = EngineStatusParser.parse(engine: .omlx,
                                              status: try load("api-status.json", "omlx"),
                                              health: try load("health.txt", "omlx"))
        XCTAssertEqual(status.state, .ready)
        XCTAssertEqual(status.detail, "v0.7.2")
        XCTAssertEqual(status.uptimeSeconds.map { $0 > 0 }, true)
        XCTAssertEqual(status.activeRequests, 0)
        XCTAssertEqual(status.requestsCompleted, 0)
        // `loaded_models` is empty on an idle server, so the default model is the
        // only hint about what would run.
        XCTAssertEqual(status.model, "Qwen3.8-27B-oQ4e-mtp")
        XCTAssertEqual(status.maximumContextTokens, nil)
    }

    func testOMLXModelInventoryKeepsOptionalFieldsOptional() throws {
        let payload = try load("models-status.json", "omlx")
        let parsed = EngineStatusParser.omlxModels(payload)
        XCTAssertEqual(parsed.models.count, 8)
        XCTAssertEqual(parsed.loadedCount, 1)

        let markitdown = try XCTUnwrap(parsed.models.first { $0.id == "MarkItDown" })
        // Built-in tools have no path and no context window; every field the
        // regular models carry must survive their absence.
        XCTAssertEqual(markitdown.path, "builtin://markitdown")
        XCTAssertNil(markitdown.maximumContextTokens)
        XCTAssertFalse(markitdown.helper)

        // The only entry `loaded` in this capture is the built-in converter, so
        // `loaded_count` is 1 even though no weights are resident.
        XCTAssertTrue(markitdown.loaded)

        let qwen = try XCTUnwrap(parsed.models.first { $0.id == "Qwen3.8-27B-oQ4e-mtp" })
        XCTAssertEqual(qwen.maximumContextTokens, 262144)
        XCTAssertEqual(qwen.path, "/Users/example/.omlx/models/Jundot/Qwen3.8-27B-oQ4e-mtp")
        XCTAssertGreaterThan(qwen.bytes ?? 0, 0)
        XCTAssertFalse(qwen.loaded)

        let helper = try XCTUnwrap(parsed.models.first { $0.id == "Qwen3.8-27B-DFlash2" })
        XCTAssertTrue(helper.helper)
        XCTAssertTrue(helper.hidden)
    }

    func testOMLXLoadingStateWhileModelIsWarmingUp() {
        let status = EngineStatusParser.parse(engine: .omlx, status: [
            "models_loading": 1,
            "models_loaded": 0,
            "loaded_models": [String](),
        ], health: nil)
        XCTAssertEqual(status.state, .loading)
    }

    // MARK: MTPLX

    func testMTPLXSnapshotMapsRollingRates() throws {
        let health = try load("health.json", "mtplx")
        let snapshot = try load("snapshot-after.json", "mtplx")
        let status = EngineStatusParser.parse(engine: .mtplx, status: snapshot, health: health)

        XCTAssertEqual(status.state, .ready)
        XCTAssertEqual(status.model, "youssofal-qwen3.5-4b-mtplx-optimized-speed")
        XCTAssertEqual(status.maximumContextTokens, 262144)
        XCTAssertEqual(status.processIdentifier.map { $0 > 0 }, true)
        XCTAssertNotNil(status.uptimeSeconds)
        XCTAssertGreaterThan(status.decodeTokensPerSecond ?? 0, 0)
        XCTAssertGreaterThan(status.uptimeSeconds ?? 0, 0)
    }

    func testMTPLXIdleSnapshotHasNoLatestBlock() throws {
        let health = try load("health.json", "mtplx")
        let snapshot = try load("snapshot.json", "mtplx")
        // Before any request `latest` is null; the parser must fall back rather
        // than report a decode rate of zero-ish garbage.
        XCTAssertTrue(snapshot["latest"] is NSNull)
        let status = EngineStatusParser.parse(engine: .mtplx, status: snapshot, health: health)
        XCTAssertEqual(status.state, .ready)
        XCTAssertEqual(status.activeRequests, 0)
        XCTAssertEqual(status.detail, "MTP")
    }

    func testMTPLXModelsExposeContextLength() throws {
        let models = EngineStatusParser.openAIModels(try load("models.json", "mtplx"), engine: .mtplx)
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models[0].id, "youssofal-qwen3.5-4b-mtplx-optimized-speed")
        XCTAssertEqual(models[0].maximumContextTokens, 262144)
        XCTAssertEqual(models[0].engine, .mtplx)
    }

    // MARK: splash

    func testSplashStatusKeepsNestedMetrics() {
        let status = EngineStatusParser.parse(engine: .splash, status: [
            "metrics": [
                "decode_tokens_per_second": 63.5,
                "prefill_tokens_per_second": 410.0,
                "draft_acceptance_rate": 0.82,
                "ttft_ms": ["p50": 120.0],
            ],
            "admission": ["waiting": 2],
            "instance": ["model": "Qwen3.8-27B-DFlash2", "pid": 4711],
            "requests": ["completed": 12, "failed": 1],
            "memory_actual": ["current_bytes": 1_000, "peak_bytes": 2_000],
            "maximum_context_tokens": 65536,
            "kv": ["format": "q8"],
        ], health: nil)

        XCTAssertEqual(status.decodeTokensPerSecond, 63.5)
        XCTAssertEqual(status.prefillTokensPerSecond, 410)
        XCTAssertEqual(status.draftAcceptance, 0.82)
        XCTAssertEqual(status.ttftMilliseconds, 120)
        XCTAssertEqual(status.queuedRequests, 2)
        XCTAssertEqual(status.model, "Qwen3.8-27B-DFlash2")
        XCTAssertEqual(status.loadedModels, ["Qwen3.8-27B-DFlash2"])
        XCTAssertEqual(status.processIdentifier, 4711)
        XCTAssertEqual(status.requestsCompleted, 12)
        XCTAssertEqual(status.requestsFailed, 1)
        XCTAssertEqual(status.memoryBytes, 1_000)
        XCTAssertEqual(status.peakMemoryBytes, 2_000)
        XCTAssertEqual(status.maximumContextTokens, 65_536)
        XCTAssertEqual(status.detail, "kv q8")
    }

    func testSplashActiveRequestsCountsBusySlots() {
        let status = EngineStatusParser.parse(engine: .splash, status: [
            "active_requests": [["id": 1], ["id": 2]],
        ], health: nil)
        XCTAssertEqual(status.activeRequests, 2)
    }
}
