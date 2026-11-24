// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import Foundation

/// 生成结果的落盘文件操作。视图需要「在不在、多大、导出到哪」这些事实，但不该
/// 自己握着 `FileManager`；统一从这里取，路径规则与冲突命名只有一份。
package enum MediaFiles {
    package static func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    package static func size(_ path: String) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
            let bytes = attributes[.size] as? NSNumber
        else { return nil }
        return bytes.int64Value
    }

    /// 批量复制到用户选的目录，不移动、不删除。目标已有同名文件时追加 `-2`、
    /// `-3`；返回成功复制的数量。
    @discardableResult
    package static func export(_ paths: [String], to directory: URL) -> Int {
        var exported = 0
        for path in paths {
            let source = URL(fileURLWithPath: path)
            guard exists(path) else { continue }
            var destination = directory.appendingPathComponent(source.lastPathComponent)
            var suffix = 2
            while exists(destination.path) {
                let stem = source.deletingPathExtension().lastPathComponent
                let ext = source.pathExtension
                destination =
                    directory
                    .appendingPathComponent("\(stem)-\(suffix)")
                    .appendingPathExtension(ext)
                suffix += 1
            }
            do {
                try FileManager.default.copyItem(at: source, to: destination)
                exported += 1
            } catch {
                continue
            }
        }
        return exported
    }
}
