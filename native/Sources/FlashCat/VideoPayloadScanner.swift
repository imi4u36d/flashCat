import Foundation

/// 视频响应的字节级解析。
///
/// 生成完成的那一条 SSE 事件是**单行**的帧载荷：1280×704×175 帧的 rgb8 有
/// 451 MB，base64 之后 632 MB。旧路径为它依次复制了
/// `String`（trim）→ `Data`（utf8）→ JSON 里再建一份 632 MB 的 `String`
/// → `replacingOccurrences` 又复制一份换行 → `Data(base64Encoded:)` 一次性解出
/// 451 MB。实测这条链路峰值 4.1 GB、单线程 9.5 秒，正好砸在「视频刚生成完」
/// 的那一下：用户看到的是整个 App 卡死几秒，小内存机器上还会直接被系统杀掉。
///
/// 这里不再建中间副本：在 UTF-8 字节上扫出 `format/frames/width/height/fps/data`，
/// 把 base64 直接解进一块预分配的帧缓冲。峰值只剩下「原始行 + 帧数据」。
/// 一条视频载荷的解析结果。体积超限要和格式错误分开：前者能直接告诉用户
/// 把尺寸或帧数调小，后者才说明协议或数据坏了。
enum VideoPayloadParseResult {
    case frames(VideoFrames)
    case tooLarge(requiredBytes: Int)
    case invalid
}

enum VideoPayloadScanner {
    /// 超过这个体积才值得走字节级解析。progress 事件只有几十字节。
    static let threshold = 256 * 1024

    /// 解码后帧数据的上限。1280×704×260 帧约 670 MiB（H3 会把 249 补到 260），
    /// 1 GiB 留出余量；再大就说明参数组合不该被接受，直接报体积，
    /// 不再落回「引擎没有返回视频数据」。
    static let maxFrameBytes = 1024 * 1024 * 1024

    /// 把 `data: {...}` 形式的整行解析成帧载荷；不是这个形状就返回 `.invalid`，
    /// 调用方会退回通用 JSON 路径。体积超限单独返回 `.tooLarge`。
    static func parse(inLine line: String,
                      limit: Int = maxFrameBytes) -> VideoPayloadParseResult {
        withBytes(line) { decode($0, limit: limit) } ?? .invalid
    }

    /// 只要帧的兼容入口；需要区分「太大」和「坏数据」时用 `parse`。
    static func frames(inLine line: String) -> VideoFrames? {
        if case .frames(let frames) = parse(inLine: line) { return frames }
        return nil
    }

    /// 解一段 base64，输出长度已知时直接用（省掉一次长度探测）。
    static func base64(_ text: String, expecting count: Int) -> Data? {
        withBytes(text) { bytes in
            decodeBase64(bytes, bytes.indices, expecting: count)
        } ?? nil
    }

    /// Swift 的 `String` 只有原生表示才有连续 UTF-8 存储；`JSONSerialization`
    /// 产出的字符串可能带一层桥接，这时才退化成一次拷贝。
    private static func withBytes<R>(_ text: String,
                                     _ body: (UnsafeBufferPointer<UInt8>) -> R) -> R? {
        if let value = text.utf8.withContiguousStorageIfAvailable({ body($0) }) {
            return value
        }
        let copy = Array(text.utf8)
        return copy.withUnsafeBufferPointer { body($0) }
    }

    // MARK: - 字段扫描

    private struct Fields {
        var format: String?
        var frames: Int?
        var width: Int?
        var height: Int?
        var fps: Int?
        var rgb: Range<Int>?
        var audio: Range<Int>?
        var audioFormat: String?
        var audioRate: Int?
        var audioChannels: Int?
    }

    private static func decode(_ bytes: UnsafeBufferPointer<UInt8>,
                               limit: Int) -> VideoPayloadParseResult {
        guard let start = objectStart(bytes),
              let fields = scanFields(bytes, from: start),
              (fields.format ?? "").lowercased() == "rgb8",
              let frames = fields.frames, frames > 0, frames <= 10_000,
              let width = fields.width, width > 0, width <= 4_096,
              let height = fields.height, height > 0, height <= 4_096,
              let range = fields.rgb
        else { return .invalid }

        // 尺寸先算准，帧缓冲一次分配到位：解码时不再扩容、不再整块复制。
        let expected = frames * height * width * 3
        guard expected > 0 else { return .invalid }
        guard expected <= limit else { return .tooLarge(requiredBytes: expected) }
        guard let rgb = decodeBase64(bytes, range, expecting: expected) else {
            return .invalid
        }

        var audio: VideoFrames.Audio?
        if let range = fields.audio, let pcm = decodeBase64(bytes, range, expecting: nil) {
            // 坏音轨不该拖垮整段视频：H3 的音频是附赠的，静音也能播。
            audio = VideoPayload.makeAudio(pcm: pcm,
                                           format: fields.audioFormat,
                                           sampleRate: fields.audioRate,
                                           channels: fields.audioChannels)
        }

        let fps = max(1, min(120, fields.fps ?? 24))
        return .frames(VideoFrames(rgb: rgb, frames: frames, width: width, height: height,
                                   fps: fps, audio: audio))
    }

    /// 跳过空白与 `data:` 前缀，返回 JSON 对象开头的位置。
    private static func objectStart(_ bytes: UnsafeBufferPointer<UInt8>) -> Int? {
        var index = 0
        skipSpaces(bytes, &index)
        // SSE 的字段名区分大小写；这里和旧的 `hasPrefix("data:")` 保持一致。
        guard index + 5 <= bytes.count,
              bytes[index] == 0x64, bytes[index + 1] == 0x61,
              bytes[index + 2] == 0x74, bytes[index + 3] == 0x61,
              bytes[index + 4] == 0x3A
        else { return nil }
        index += 5
        skipSpaces(bytes, &index)
        guard index < bytes.count, bytes[index] == 0x7B else { return nil }
        return index + 1
    }

    /// 只认扁平对象：认识的键就地取值，其它值整段跳过（含嵌套对象与数组）。
    private static func scanFields(_ bytes: UnsafeBufferPointer<UInt8>,
                                   from start: Int) -> Fields? {
        var fields = Fields()
        var index = start
        while index < bytes.count {
            skipSpaces(bytes, &index)
            guard index < bytes.count else { return nil }
            switch bytes[index] {
            case 0x7D:                                   // '}'
                return fields
            case 0x2C:                                   // ','
                index += 1
                continue
            case 0x22:                                   // '"'
                break
            default:
                return nil
            }

            guard let keyEnd = findQuote(bytes, from: index + 1) else { return nil }
            let key = String(decoding: bytes[(index + 1)..<keyEnd], as: UTF8.self)
            index = keyEnd + 1
            skipSpaces(bytes, &index)
            guard index < bytes.count, bytes[index] == 0x3A else { return nil }   // ':'
            index += 1
            skipSpaces(bytes, &index)
            guard index < bytes.count else { return nil }

            switch key {
            case "format":
                guard let value = stringValue(bytes, &index) else { return nil }
                fields.format = value
            case "frames", "width", "height", "fps",
                 "audio_sample_rate", "audio_channels":
                guard let value = intValue(bytes, &index) else { return nil }
                switch key {
                case "frames": fields.frames = value
                case "width": fields.width = value
                case "height": fields.height = value
                case "fps": fields.fps = value
                case "audio_sample_rate": fields.audioRate = value
                default: fields.audioChannels = value
                }
            case "data":
                guard let range = stringRange(bytes, &index) else { return nil }
                fields.rgb = range
            case "audio_data":
                guard let range = stringRange(bytes, &index) else { return nil }
                fields.audio = range
            case "audio_format":
                guard let value = stringValue(bytes, &index) else { return nil }
                fields.audioFormat = value
            default:
                guard skipValue(bytes, &index) else { return nil }
            }
        }
        return nil
    }

    // MARK: - 标量

    @inline(__always)
    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    @inline(__always)
    private static func skipSpaces(_ bytes: UnsafeBufferPointer<UInt8>, _ index: inout Int) {
        while index < bytes.count, isSpace(bytes[index]) { index += 1 }
    }

    /// 下一个**未被转义**的引号位置。转义引号属于字符串内容。
    private static func findQuote(_ bytes: UnsafeBufferPointer<UInt8>, from start: Int) -> Int? {
        guard start >= 0, start <= bytes.count, let base = bytes.baseAddress else { return nil }
        var index = start
        while index < bytes.count {
            guard let hit = memchr(base + index, 0x22, bytes.count - index) else { return nil }
            let found = UnsafeRawPointer(hit) - UnsafeRawPointer(base)
            if found > start, bytes[found - 1] == 0x5C {   // '\\'
                index = found + 1
                continue
            }
            return found
        }
        return nil
    }

    private static func stringValue(_ bytes: UnsafeBufferPointer<UInt8>,
                                    _ index: inout Int) -> String? {
        guard let range = stringRange(bytes, &index) else { return nil }
        return String(decoding: bytes[range], as: UTF8.self)
    }

    private static func stringRange(_ bytes: UnsafeBufferPointer<UInt8>,
                                    _ index: inout Int) -> Range<Int>? {
        guard index < bytes.count, bytes[index] == 0x22,
              let end = findQuote(bytes, from: index + 1) else { return nil }
        let range = (index + 1)..<end
        index = end + 1
        return range
    }

    private static func intValue(_ bytes: UnsafeBufferPointer<UInt8>,
                                 _ index: inout Int) -> Int? {
        var value = 0
        var digits = 0
        while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 {
            value = value * 10 + Int(bytes[index] - 0x30)
            digits += 1
            index += 1
            if digits > 9 { return nil }
        }
        return digits > 0 ? value : nil
    }

    private static func skipValue(_ bytes: UnsafeBufferPointer<UInt8>,
                                  _ index: inout Int) -> Bool {
        guard index < bytes.count else { return false }
        switch bytes[index] {
        case 0x22:                                       // '"'
            return stringRange(bytes, &index) != nil
        case 0x7B, 0x5B:                                 // '{' '['
            var depth = 0
            var insideString = false
            while index < bytes.count {
                let byte = bytes[index]
                if insideString {
                    if byte == 0x5C { index += 2; continue }
                    if byte == 0x22 { insideString = false }
                } else if byte == 0x22 {
                    insideString = true
                } else if byte == 0x7B || byte == 0x5B {
                    depth += 1
                } else if byte == 0x7D || byte == 0x5D {
                    depth -= 1
                    if depth == 0 {
                        index += 1
                        return true
                    }
                }
                index += 1
            }
            return false
        default:
            while index < bytes.count, bytes[index] != 0x2C, bytes[index] != 0x7D,
                  !isSpace(bytes[index]) {
                index += 1
            }
            return true
        }
    }

    // MARK: - base64

    /// 直接解进目标缓冲。空白、JSON 里的 `\n` 转义、`=` 补位都在扫描时跳过，
    /// 所以不需要先复制一份去掉换行的字符串。
    private static func decodeBase64(_ bytes: UnsafeBufferPointer<UInt8>,
                                     _ range: Range<Int>,
                                     expecting expected: Int?) -> Data? {
        guard range.lowerBound >= 0, range.upperBound <= bytes.count else { return nil }
        let slice = UnsafeBufferPointer(rebasing: bytes[range])

        if let expected = expected {
            guard expected > 0 else { return nil }
            var data = Data(count: expected)
            let written = data.withUnsafeMutableBytes { destination in
                decode(slice, into: destination)
            }
            guard let written = written, written == expected else { return nil }
            return data
        }

        // 体积未知（音轨）：先数有效字符估上限，解完再收口。
        var valid = 0
        for byte in slice {
            if isSpace(byte) || byte == 0x5C { continue }
            if byte == 0x3D { break }
            valid += 1
        }
        guard valid > 0 else { return nil }
        var data = Data(count: valid * 3 / 4 + 3)
        let written = data.withUnsafeMutableBytes { destination in
            decode(slice, into: destination)
        }
        guard let written = written, written > 0 else { return nil }
        return Data(data[0..<written])
    }

    private static func decode(_ source: UnsafeBufferPointer<UInt8>,
                               into destination: UnsafeMutableRawBufferPointer) -> Int? {
        var accumulator: UInt32 = 0
        var bits = 0
        var written = 0
        var index = source.startIndex
        let end = source.endIndex
        while index < end {
            var byte = source[index]
            index += 1
            if byte == 0x5C {
                // JSON 转义：`\/` 就是 base64 里的 `/`（Foundation 会把斜杠转义掉），
                // `\n` / `\r` / `\t` 是折行留下的空白，都不能当成字符丢掉。
                guard index < end else { return nil }
                let escaped = source[index]
                index += 1
                switch escaped {
                case 0x2F: byte = 0x2F                  // `\/` 就是 `/`，还原后参与解码
                case 0x6E, 0x72, 0x74: continue         // 折行留下的空白，直接跳过
                default: return nil
                }
            }
            if isSpace(byte) { continue }
            if byte == 0x3D { break }                    // '=' 补位之后不再有数据
            let sextet = sextet(of: byte)
            guard sextet != 0xFF else { return nil }
            accumulator = (accumulator << 6) | UInt32(sextet)
            bits += 6
            if bits >= 8 {
                bits -= 8
                guard written < destination.count else { return nil }
                destination[written] = UInt8(truncatingIfNeeded: accumulator >> UInt32(bits))
                written += 1
                accumulator &= (1 << UInt32(bits)) - 1
            }
        }
        return written
    }

    /// base64 字母表查表。写成算术分支而不是 256 字节的表，省掉每次下标的
    /// 边界检查；解码是纯内存带宽活，这点差别在 600 MB 上很可观。
    @inline(__always)
    private static func sextet(of byte: UInt8) -> UInt8 {
        switch byte {
        case 0x41...0x5A: return byte &- 0x41                       // A-Z
        case 0x61...0x7A: return byte &- 0x61 &+ 26                 // a-z
        case 0x30...0x39: return byte &- 0x30 &+ 52                 // 0-9
        case 0x2B: return 62                                        // +
        case 0x2F: return 63                                        // /
        default: return 0xFF
        }
    }
}
