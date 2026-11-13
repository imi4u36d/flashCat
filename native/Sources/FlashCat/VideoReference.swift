import Foundation
import AVFoundation
import AppKit

/// 一段参考视频的读头结果：时长、显示尺寸与第一帧缩略图。
struct VideoReferenceMetadata {
    let duration: Double
    let pixelSize: CGSize
    let posterJPEG: Data?
}

enum VideoReferenceError: LocalizedError {
    case unreadable
    case noVideoTrack
    case tooShort
    case frameFailed(String)
    case encodeFailed

    var errorDescription: String? {
        switch self {
        case .unreadable:
            return "读不出这段视频的时长，文件可能损坏或格式不受支持。"
        case .noVideoTrack:
            return "这个文件里没有视频轨道，换一段 MP4/MOV 再试。"
        case .tooShort:
            return "参考视频太短：服务端要求至少 5 帧（约 0.2 秒）。"
        case .frameFailed(let message):
            return "参考视频抽帧失败：\(message)"
        case .encodeFailed:
            return "参考帧编码失败，换一段视频再试。"
        }
    }
}

/// REF2VA 的参考视频只收帧，不收整段文件。客户端在发送前把视频均匀抽成
/// 5 + 17k 帧（服务端按这个步长对齐），压成 JPEG 再 base64。
enum VideoReferenceExtractor {
    /// 5 + 17 × 2：服务端允许的最小对齐档之一，39 帧足够表达一段几秒的运镜，
    /// 同时把三段参考视频的请求体压在十几 MB。
    static let frameCount = 39

    private static let minimumDuration = 0.2

    static func metadata(url: URL) async throws -> VideoReferenceMetadata {
        let asset = AVURLAsset(url: url)
        let duration: CMTime
        do {
            duration = try await asset.load(.duration)
        } catch {
            throw VideoReferenceError.unreadable
        }
        let seconds = duration.seconds
        guard seconds.isFinite, seconds > 0 else { throw VideoReferenceError.unreadable }
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { throw VideoReferenceError.noVideoTrack }
        let (naturalSize, transform) = try await track.load(.naturalSize, .preferredTransform)
        let transformed = naturalSize.applying(transform)
        let display = CGSize(width: abs(transformed.width), height: abs(transformed.height))
        guard display.width > 0, display.height > 0 else { throw VideoReferenceError.unreadable }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 160, height: 160)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
        let poster: Data?
        do {
            let (image, _) = try await generator.image(
                at: CMTime(seconds: min(0.1, seconds / 4), preferredTimescale: 600))
            poster = jpegData(image, quality: 0.72)
        } catch {
            // 缩略图读不出来不该挡住用户继续挑文件；发送时还会再抽一次帧。
            poster = nil
        }
        return VideoReferenceMetadata(duration: seconds, pixelSize: display, posterJPEG: poster)
    }

    /// 均匀抽 `frameCount` 帧。`maximumSize` 决定参考帧的清晰度：match 时传
    /// 生成画布，max 时传 1280×1280。
    static func frames(url: URL,
                       maximumSize: CGSize,
                       quality: CGFloat = 0.8,
                       onProgress: (@Sendable (String) -> Void)? = nil) async throws -> [String] {
        let asset = AVURLAsset(url: url)
        let duration: CMTime
        do {
            duration = try await asset.load(.duration)
        } catch {
            throw VideoReferenceError.unreadable
        }
        let seconds = duration.seconds
        guard seconds.isFinite, seconds > 0 else { throw VideoReferenceError.unreadable }
        guard seconds >= minimumDuration else { throw VideoReferenceError.tooShort }
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard !tracks.isEmpty else { throw VideoReferenceError.noVideoTrack }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maximumSize
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)

        var frames: [String] = []
        frames.reserveCapacity(frameCount)
        let step = seconds / Double(frameCount)
        for index in 0..<frameCount {
            try Task.checkCancellation()
            // 取每段的中点，避开片头黑场与片尾最后一帧越界。
            let stamp = min(seconds - 0.001, step * (Double(index) + 0.5))
            let image: CGImage
            do {
                (image, _) = try await generator.image(
                    at: CMTime(seconds: stamp, preferredTimescale: 600))
            } catch {
                throw VideoReferenceError.frameFailed(error.localizedDescription)
            }
            guard let data = jpegData(image, quality: quality) else {
                throw VideoReferenceError.encodeFailed
            }
            frames.append(data.base64EncodedString())
            if index == 0 || (index + 1) % 10 == 0 {
                onProgress?("正在读取参考视频 \(index + 1)/\(frameCount) 帧")
            }
        }
        return frames
    }

    private static func jpegData(_ image: CGImage, quality: CGFloat) -> Data? {
        let bitmap = NSBitmapImageRep(cgImage: image)
        return bitmap.representation(using: .jpeg,
                                     properties: [.compressionFactor: quality])
    }
}
