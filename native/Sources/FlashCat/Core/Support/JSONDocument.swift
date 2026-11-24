// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import Foundation

/// 支持目录里那些 JSON 文档的统一读写入口：原子写、目录自动创建、错误带路径。
///
/// 以前每个 store 各写一遍 `try? encoder.encode(...)` + `try? data.write(...)`，
/// 磁盘满、权限错、文件损坏都被折叠成「什么也没发生」。这里把失败变成可上报的
/// `Failure`，调用方至少能写进日志或提示用户。
enum JSONDocument {
    enum Operation: String, Equatable {
        case read
        case decode
        case encode
        case write
        case remove
    }

    struct Failure: Error, CustomStringConvertible {
        let path: String
        let operation: Operation
        let underlying: Error

        var description: String {
            "\(operation.rawValue) \(path): \(underlying.localizedDescription)"
        }
    }

    /// 文件不存在返回 nil；存在但读不出来 / 解不出来就抛错，不把「损坏」当成「空」。
    static func load<T: Decodable>(
        _ type: T.Type,
        from path: String,
        dateDecoding: JSONDecoder.DateDecodingStrategy = .deferredToDate
    ) throws -> T? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw Failure(path: path, operation: .read, underlying: error)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = dateDecoding
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw Failure(path: path, operation: .decode, underlying: error)
        }
    }

    static func save<T: Encodable>(
        _ value: T,
        to path: String,
        dateEncoding: JSONEncoder.DateEncodingStrategy = .deferredToDate,
        pretty: Bool = true
    ) throws {
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        do {
            try FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true)
        } catch {
            throw Failure(path: directory, operation: .write, underlying: error)
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = dateEncoding
        if pretty {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        }
        let data: Data
        do {
            data = try encoder.encode(value)
        } catch {
            throw Failure(path: path, operation: .encode, underlying: error)
        }
        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            throw Failure(path: path, operation: .write, underlying: error)
        }
    }

    static func remove(at path: String) throws {
        guard FileManager.default.fileExists(atPath: path) else { return }
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch {
            throw Failure(path: path, operation: .remove, underlying: error)
        }
    }
}
