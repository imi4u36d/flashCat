// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import FlashCatKit
import XCTest

@testable import FlashCatCore

final class JSONDocumentTests: XCTestCase {
    private struct Payload: Codable, Equatable {
        let name: String
        let at: Date
        let values: [Int]
    }

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("flashcat-json-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testRoundTripCreatesDirectoriesAndPreservesISODates() throws {
        let path = directory.appendingPathComponent("nested/deeper/payload.json").path
        let at = Date(timeIntervalSince1970: 1_764_000_000)
        let payload = Payload(name: "对话", at: at, values: [1, 2, 3])

        try JSONDocument.save(payload, to: path, dateEncoding: .iso8601)
        let loaded = try JSONDocument.load(Payload.self, from: path, dateDecoding: .iso8601)

        XCTAssertEqual(loaded, payload)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    func testMissingFileIsNotAnError() throws {
        let path = directory.appendingPathComponent("absent.json").path
        XCTAssertNil(try JSONDocument.load(Payload.self, from: path))
    }

    func testCorruptFileThrowsDecodeFailureWithPath() throws {
        let path = directory.appendingPathComponent("broken.json").path
        try Data("{\"name\": 42}".utf8).write(to: URL(fileURLWithPath: path))

        XCTAssertThrowsError(try JSONDocument.load(Payload.self, from: path)) { error in
            guard let failure = error as? JSONDocument.Failure else {
                return XCTFail("应是 JSONDocument.Failure，实际 \(error)")
            }
            XCTAssertEqual(failure.operation, .decode)
            XCTAssertEqual(failure.path, path)
            XCTAssertTrue(failure.description.contains(path))
        }
    }

    func testRemoveIsIdempotent() throws {
        let path = directory.appendingPathComponent("removable.json").path
        try Data("{}".utf8).write(to: URL(fileURLWithPath: path))

        try JSONDocument.remove(at: path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertNoThrow(try JSONDocument.remove(at: path))
    }
}
