import XCTest
@testable import FlashCatCLICore
import FlashCatKit

final class ControlProtocolTests: XCTestCase {
    func testRouteParsing() {
        XCTAssertEqual(ControlRoute.parse(method: "GET", path: "/v1/status"), .status)
        XCTAssertEqual(ControlRoute.parse(method: "GET", path: "/v1/engines"), .engines)
        XCTAssertEqual(ControlRoute.parse(method: "POST", path: "/v1/engines/omlx/start"),
                       .engineStart("omlx"))
        XCTAssertEqual(ControlRoute.parse(method: "POST", path: "/v1/engines/omlx/use"),
                       .engineUse("omlx"))
        XCTAssertEqual(ControlRoute.parse(method: "POST", path: "/v1/engines/reload"),
                       .enginesReload)
        XCTAssertEqual(ControlRoute.parse(method: "POST", path: "/v1/models/download"),
                       .modelDownload)
        XCTAssertEqual(ControlRoute.parse(method: "GET", path: "/v1/models"), .models)
        XCTAssertEqual(ControlRoute.parse(method: "POST", path: "/v1/downloads/pause"),
                       .downloadPause)
        XCTAssertEqual(ControlRoute.parse(method: "POST", path: "/v1/app/quit"), .appQuit)
        XCTAssertNil(ControlRoute.parse(method: "GET", path: "/v1/nope"))
        XCTAssertNil(ControlRoute.parse(method: "POST", path: "/v1/engines/omlx/explode"))
    }

    func testRouteDecodesPercentEncodedEngineID() {
        XCTAssertEqual(ControlRoute.parse(method: "POST", path: "/v1/engines/mlx-serve/stop"),
                       .engineStop("mlx-serve"))
        XCTAssertEqual(ControlRoute.parse(method: "POST", path: "/v1/engines/omlx%2Dplus/start"),
                       .engineStart("omlx-plus"))
    }

    func testRuntimeRoundTripsThroughTheFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("flashcat-control-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("control.json").path
        let runtime = ControlRuntime(pid: 42, port: 9100, token: "abc",
                                     appVersion: "1.5.3", appPath: "/Applications/flashCat.app",
                                     startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try runtime.write(to: path)
        let loaded = try XCTUnwrap(ControlRuntime.load(from: path))
        XCTAssertEqual(loaded.port, 9100)
        XCTAssertEqual(loaded.token, "abc")
        XCTAssertEqual(loaded.pid, 42)
        XCTAssertEqual(try permissions(of: path), 0o600)

        // A stale world-readable file from an older build must be tightened on
        // the next write, not merely for new files.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
        try runtime.write(to: path)
        XCTAssertEqual(try permissions(of: path), 0o600)
    }

    private func permissions(of path: String) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777
    }

    func testControlLocationRefusesPlainHTTPToNonLoopback() {
        let runtime = ControlRuntime(pid: 42, port: 9100, token: "abc",
                                     appVersion: "1.5.3", appPath: nil,
                                     startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        func invocation(_ url: String) -> CLIInvocation {
            CLIInvocation(command: "status", options: ["control-url": url])
        }
        XCTAssertThrowsError(try ControlLocation.discover(
            invocation: invocation("http://example.com:9100"), environment: [:], runtime: runtime))
        XCTAssertThrowsError(try ControlLocation.discover(
            invocation: invocation("not a url"), environment: [:], runtime: runtime))
        XCTAssertNoThrow(try ControlLocation.discover(
            invocation: invocation("http://127.0.0.1:9100"), environment: [:], runtime: runtime))
        XCTAssertNoThrow(try ControlLocation.discover(
            invocation: invocation("https://example.com"), environment: [:], runtime: runtime))
    }

    func testStatusDocumentDecodesFromTheWireShape() throws {
        let json = """
        {
          "app": {"version":"1.5.3","pid":7,"startedAt":"2026-11-08T09:00:00Z","controlPort":9100},
          "engine": {"id":"omlx","name":"oMLX","version":"0.7.3","installedVersions":["0.7.3"],
                     "isActive":true,"isInstalled":true,"state":"ready","port":8100,
                     "model":"Jundot--Qwen3.8-27B-oQ4e-mtp","stage":"","capabilities":["chat"]},
          "engines": [],
          "gateway": {"enabled":true,"running":true,"port":9000,"baseURL":"http://127.0.0.1:9000"},
          "downloads": [{"engine":"omlx","model":"repo","status":"downloading",
                         "downloadedBytes":10,"totalBytes":100,"fraction":0.1}]
        }
        """
        let status = try ControlJSON.decoder().decode(ControlStatus.self, from: Data(json.utf8))
        XCTAssertEqual(status.engine?.port, 8100)
        XCTAssertEqual(status.gateway.baseURL, "http://127.0.0.1:9000")
        XCTAssertEqual(status.downloads.first?.fraction, 0.1)
    }

    func testConfigAndDoctorDocumentsEncode() throws {
        let config = ControlConfigDocument(entries: [
            ControlConfigEntry(kind: "enum", key: "appearance", title: "外观", value: "dark")
        ])
        let data = try ControlJSON.encoder(pretty: false).encode(config)
        XCTAssertTrue(String(data: data, encoding: .utf8)?.contains("appearance") == true)

        let report = ControlDoctorReport(checks: [
            ControlDoctorCheck(status: "ok", id: "app", title: "应用", detail: "ok")
        ])
        XCTAssertFalse(report.failed)
        XCTAssertTrue(ControlDoctorReport(checks: [
            ControlDoctorCheck(status: "fail", id: "x", title: "x", detail: "x")
        ]).failed)
    }
}
