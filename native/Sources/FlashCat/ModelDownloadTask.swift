import Foundation
import FlashCatKit

/// One row of the model download center.
///
/// The Hub keeps partial files inside the destination's `.cache` folder (v1
/// layout), so a paused or interrupted transfer survives a process kill and a
/// later `snapshot_download` continues from the bytes already on disk. That is
/// the resume story: the task row only records where the transfer stood when
/// it stopped, and restarting the downloader picks the partials back up.
struct ModelDownloadTask: Codable, Identifiable, Equatable {
    enum Status: String, Codable {
        case downloading
        case paused
        case failed
    }

    let engine: EngineID
    let model: String
    var status: Status
    /// Bytes the Hub says the whole repository needs, printed by the
    /// downloader before the transfer starts. 0 while unknown.
    var totalBytes: Int = 0
    /// Bytes on disk at the last update; paused rows show this instead of a
    /// live fraction.
    var downloadedBytes: Int = 0
    var addedAt: Date = Date()

    var id: String { engine.rawValue + "/" + model }

    var fraction: Double? {
        guard totalBytes > 0, totalBytes >= downloadedBytes, downloadedBytes >= 0 else { return nil }
        return min(max(Double(downloadedBytes) / Double(totalBytes), 0), 1)
    }
}

/// The download center list outlives the app: paused transfers should still be
/// offered for resume after a relaunch, so the rows live in a small JSON file
/// next to the other support files.
enum ModelDownloadStore {
    static var filePath: String { Paths.supportDirectory + "/model-downloads.json" }

    static func load() -> [ModelDownloadTask] {
        guard let data = FileManager.default.contents(atPath: filePath) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let tasks = try? decoder.decode([ModelDownloadTask].self, from: data) else { return [] }
        // A "downloading" row can only be a crash/quit leftover: the child
        // process is gone, but the partial files are still on disk and a
        // resume picks them up.
        return tasks.map { task in
            var task = task
            if task.status == .downloading { task.status = .paused }
            return task
        }
    }

    static func save(_ tasks: [ModelDownloadTask]) {
        Paths.ensureDirectory(Paths.supportDirectory)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(tasks) else { return }
        try? data.write(to: URL(fileURLWithPath: filePath), options: .atomic)
    }
}
