// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import FlashCatKit
import XCTest

@testable import FlashCatCore

final class MediaFilesTests: XCTestCase {
    private var root: URL!
    private var source: URL!
    private var destination: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("flashcat-media-\(UUID().uuidString)", isDirectory: true)
        source = root.appendingPathComponent("source", isDirectory: true)
        destination = root.appendingPathComponent("export", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testExistsAndSize() throws {
        let file = source.appendingPathComponent("image.png")
        try Data("hello".utf8).write(to: file)

        XCTAssertTrue(MediaFiles.exists(file.path))
        XCTAssertEqual(MediaFiles.size(file.path), 5)
        XCTAssertFalse(MediaFiles.exists(source.appendingPathComponent("missing.png").path))
        XCTAssertNil(MediaFiles.size(source.appendingPathComponent("missing.png").path))
    }

    func testExportCopiesAndAvoidsNameCollisions() throws {
        let file = source.appendingPathComponent("shot.png")
        try Data("image".utf8).write(to: file)

        XCTAssertEqual(MediaFiles.export([file.path], to: destination), 1)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("shot.png").path))

        XCTAssertEqual(MediaFiles.export([file.path], to: destination), 1)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("shot-2.png").path))
    }

    func testExportSkipsMissingSources() {
        let missing = source.appendingPathComponent("gone.png").path
        XCTAssertEqual(MediaFiles.export([missing], to: destination), 0)
    }
}
