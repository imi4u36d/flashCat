// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import FlashCatKit
import Foundation

/// One row of the model download center.
///
/// The Hub keeps partial files inside the destination's `.cache` folder (v1
/// layout), so a paused or interrupted transfer survives a process kill and a
/// later `snapshot_download` continues from the bytes already on disk. That is
/// the resume story: the task row only records where the transfer stood when
/// it stopped, and restarting the downloader picks the partials back up.
package struct ModelDownloadTask: Codable, Identifiable, Equatable {
    package enum Status: String, Codable {
        case downloading
        case paused
        case failed
    }

    package let engine: EngineID
    package let model: String
    package var status: Status
    /// Bytes the Hub says the whole repository needs, printed by the
    /// downloader before the transfer starts. 0 while unknown.
    package var totalBytes: Int = 0
    /// Bytes on disk at the last update; paused rows show this instead of a
    /// live fraction.
    package var downloadedBytes: Int = 0
    package var addedAt: Date = Date()
    /// 下到公共目录的任务：`engine` 只是「谁发起、之后给谁用」的记号，权重
    /// 落盘位置与引擎无关。nil 表示下进 `engine` 自己的模型目录（模型广场的
    /// 默认路径）。
    package var shared: [EngineID]? = nil
    /// 发起下载时选择的 Hub 来源与文件白名单（用于断点续传时沿用同一来源与量化档位）。
    package var source: HubSource? = nil
    package var include: [String]? = nil
    /// 下载完成后是否把它切成当前模型。模型页的「下载」默认切；模型广场只是
    /// 把权重放进目录，默认不动正在跑的模型。Optional 让旧任务行仍能解码。
    package var activateOnFinish: Bool? = nil

    package var id: String { engine.rawValue + "/" + model }

    package var fraction: Double? {
        guard totalBytes > 0, totalBytes >= downloadedBytes, downloadedBytes >= 0 else { return nil }
        return min(max(Double(downloadedBytes) / Double(totalBytes), 0), 1)
    }

    package init(
        engine: EngineID, model: String, status: Status,
        totalBytes: Int = 0, downloadedBytes: Int = 0, addedAt: Date = Date(),
        shared: [EngineID]? = nil, source: HubSource? = nil, include: [String]? = nil,
        activateOnFinish: Bool = true
    ) {
        self.engine = engine
        self.model = model
        self.status = status
        self.totalBytes = totalBytes
        self.downloadedBytes = downloadedBytes
        self.addedAt = addedAt
        self.shared = shared
        self.source = source
        self.include = include
        self.activateOnFinish = activateOnFinish
    }
}

/// The download center list outlives the app: paused transfers should still be
/// offered for resume after a relaunch, so the rows live in a small JSON file
/// next to the other support files.
package enum ModelDownloadStore {
    package static var filePath: String { Paths.supportDirectory + "/model-downloads.json" }

    package static func load(from path: String = filePath) throws -> [ModelDownloadTask] {
        let tasks =
            try JSONDocument.load(
                [ModelDownloadTask].self, from: path, dateDecoding: .iso8601) ?? []
        // A "downloading" row can only be a crash/quit leftover: the child
        // process is gone, but the partial files are still on disk and a
        // resume picks them up.
        return tasks.map { task in
            var task = task
            if task.status == .downloading { task.status = .paused }
            return task
        }
    }

    package static func save(_ tasks: [ModelDownloadTask], to path: String = filePath) throws {
        try JSONDocument.save(
            tasks, to: path, dateEncoding: .iso8601, pretty: true)
    }
}
