// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import XCTest

@testable import FlashCat
@testable import FlashCatCore

final class GalleryDeleteTests: XCTestCase {
    private var root: URL!
    private var images: URL!
    private var videos: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("flashcat-gallery-\(UUID().uuidString)", isDirectory: true)
        images = root.appendingPathComponent("images", isDirectory: true)
        videos = root.appendingPathComponent("videos", isDirectory: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: videos, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testImageDeleteRemovesIndexAndFile() throws {
        let keep = images.appendingPathComponent("keep.png")
        let drop = images.appendingPathComponent("drop.png")
        try Data([0x01]).write(to: keep)
        try Data([0x02]).write(to: drop)

        let store = ImageGalleryStore(
            fileURL: root.appendingPathComponent("image-gallery.json"),
            mediaDirectory: images.path)
        store.record(image(drop))
        store.record(image(keep))

        XCTAssertEqual(store.delete(paths: [drop.path]), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: drop.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: keep.path))
        XCTAssertEqual(store.images().map(\.path), [keep.path])
    }

    func testImageDeleteLeavesFilesOutsideGalleryDirectory() throws {
        let outside = root.appendingPathComponent("outside.png")
        try Data([0x03]).write(to: outside)

        let store = ImageGalleryStore(
            fileURL: root.appendingPathComponent("image-gallery.json"),
            mediaDirectory: images.path)
        store.record(image(outside))

        XCTAssertEqual(store.delete(paths: [outside.path]), 0)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: outside.path),
            "索引被手改时，图库不能变成任意文件删除器")
        XCTAssertTrue(store.images().isEmpty, "条目仍要从索引移除")
    }

    func testVideoDeleteRemovesIndexAndFile() throws {
        let clip = videos.appendingPathComponent("clip.mp4")
        try Data([0x04]).write(to: clip)

        let store = VideoGalleryStore(
            fileURL: root.appendingPathComponent("video-gallery.json"),
            mediaDirectory: videos.path)
        store.record(video(clip))

        XCTAssertEqual(store.delete(paths: [clip.path]), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: clip.path))
        XCTAssertTrue(store.videos().isEmpty)
    }

    func testDeletingMissingFileStillClearsIndex() throws {
        let missing = images.appendingPathComponent("missing.png")
        let store = ImageGalleryStore(
            fileURL: root.appendingPathComponent("image-gallery.json"),
            mediaDirectory: images.path)
        store.record(image(missing))

        XCTAssertEqual(store.delete(paths: [missing.path]), 0)
        XCTAssertTrue(store.images().isEmpty)
    }

    private func image(_ url: URL) -> GalleryImage {
        GalleryImage(
            path: url.path, prompt: "p", model: "m",
            createdAt: Date(), note: nil, seed: nil)
    }

    private func video(_ url: URL) -> GalleryVideo {
        GalleryVideo(
            path: url.path, prompt: "p", model: "m",
            createdAt: Date(), note: nil, seed: nil)
    }
}
