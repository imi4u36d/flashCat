import XCTest
import AVFoundation
import FlashCatKit
@testable import FlashCat

/// 视频链路里最容易悄悄坏掉的两段：rgb8 载荷校验和 MP4 封装。
/// 前者用纯 JSON 就能测，后者必须让 AVAssetWriter 真写一遍。
final class VideoClientTests: XCTestCase {
    func testVideoOptionsParsesDimensionsAndFallsBack() {
        // 两个参数面板的默认步数都是 20：拖动条和手动输入都从它起步。
        XCTAssertEqual(VideoOptions().steps, 20)
        XCTAssertEqual(ImageOptions().steps, 20)

        var options = VideoOptions()
        options.size = "1024x576"
        XCTAssertEqual(options.dimensions.width, 1024)
        XCTAssertEqual(options.dimensions.height, 576)

        options.size = "garbage"
        XCTAssertEqual(options.dimensions.width, 768)
        XCTAssertEqual(options.dimensions.height, 512)
    }

    func testPayloadAcceptsTightlyPackedRGBFrames() throws {
        let rgb = makeRGB(frames: 9, width: 64, height: 64)
        let decoded = try XCTUnwrap(VideoPayload.frames(in: [
            "frames": 9,
            "width": 64,
            "height": 64,
            "fps": 24,
            "format": "rgb8",
            "data": rgb.base64EncodedString(),
        ]))

        XCTAssertEqual(decoded.rgb, rgb)
        XCTAssertEqual(decoded.frames, 9)
        XCTAssertEqual(decoded.width, 64)
        XCTAssertEqual(decoded.height, 64)
        XCTAssertEqual(decoded.fps, 24)
        XCTAssertNil(decoded.audio)
    }

    func testPayloadRejectsFrameCountMismatch() {
        let rgb = makeRGB(frames: 9, width: 64, height: 64)
        XCTAssertNil(VideoPayload.frames(in: [
            "frames": 10,
            "width": 64,
            "height": 64,
            "format": "rgb8",
            "data": rgb.base64EncodedString(),
        ]), "帧数与 rgb 字节数对不上时不能拿错位的数据去编码")
    }

    func testPayloadKeepsVideoWhenAudioIsMalformed() throws {
        let rgb = makeRGB(frames: 9, width: 64, height: 64)
        let decoded = try XCTUnwrap(VideoPayload.frames(in: [
            "frames": 9,
            "width": 64,
            "height": 64,
            "format": "rgb8",
            "data": rgb.base64EncodedString(),
            "audio_data": Data([0, 1, 2, 3, 4]).base64EncodedString(),
            "audio_sample_rate": 16_000,
            "audio_channels": 2,
            "audio_format": "pcm_s16le",
        ]))

        XCTAssertNil(decoded.audio, "坏音轨只该被丢掉，不能连视频一起失败")
    }

    func testMuxerWritesPlayableVideoAndAudioTracks() async throws {
        let frames = 9
        let width = 64
        let height = 64
        let video = VideoFrames(
            rgb: makeRGB(frames: frames, width: width, height: height),
            frames: frames,
            width: width,
            height: height,
            fps: 24,
            audio: VideoFrames.Audio(pcm: makePCM(seconds: 0.5),
                                     sampleRate: 16_000,
                                     channels: 2))

        let mp4 = try VideoMuxer.makeMP4(video)
        XCTAssertGreaterThan(mp4.count, 1_000)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flashcat-test-\(UUID().uuidString).mp4")
        try mp4.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let asset = AVURLAsset(url: url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(videoTracks.count, 1)
        XCTAssertEqual(audioTracks.count, 1)

        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        XCTAssertEqual(duration, Double(frames) / 24.0, accuracy: 0.15)
    }

    /// 停止按钮在封装阶段也要立刻生效：编码线程每帧查一次开关，
    /// 取消要抛 `CancellationError`，上层才会显示「已取消」而不是编码失败。
    func testMuxerStopsBeforeEncodingWhenCancelled() throws {
        let video = VideoFrames(rgb: makeRGB(frames: 3, width: 64, height: 64),
                                frames: 3,
                                width: 64,
                                height: 64,
                                fps: 24,
                                audio: nil)
        XCTAssertThrowsError(try VideoMuxer.makeMP4(video) { true }) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }


    func testExtractorSamplesFramesAlignedToServerStep() async throws {
        let frames = 49
        let width = 128
        let height = 96
        let video = VideoFrames(rgb: makeRGB(frames: frames, width: width, height: height),
                                frames: frames,
                                width: width,
                                height: height,
                                fps: 24,
                                audio: nil)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flashcat-ref-\(UUID().uuidString).mp4")
        try VideoMuxer.makeMP4(video).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let metadata = try await VideoReferenceExtractor.metadata(url: url)
        XCTAssertEqual(metadata.duration, Double(frames) / 24.0, accuracy: 0.15)
        XCTAssertEqual(metadata.pixelSize.width, CGFloat(width))
        XCTAssertEqual(metadata.pixelSize.height, CGFloat(height))
        XCTAssertNotNil(metadata.posterJPEG)

        let box = ProgressBox()
        let refs = try await VideoReferenceExtractor.frames(
            url: url,
            maximumSize: CGSize(width: width, height: height)
        ) { box.values.append($0) }

        // 39 = 5 + 17 × 2，正好落在服务端允许的 5 + 17k 档位上。
        XCTAssertEqual(refs.count, 39)
        for encoded in refs {
            let data = try XCTUnwrap(Data(base64Encoded: encoded))
            XCTAssertEqual(data.prefix(2), Data([0xFF, 0xD8]), "参考帧必须是 JPEG")
        }
        XCTAssertEqual(box.values.first, "正在读取参考视频 1/39 帧")
    }

    func testStreamingResponseParsesProgressAndMuxesCompleteEvent() async throws {
        let rgb = makeRGB(frames: 9, width: 64, height: 64)
        let payload: [String: Any] = [
            "frames": 9,
            "width": 64,
            "height": 64,
            "fps": 24,
            "format": "rgb8",
            "data": rgb.base64EncodedString(),
        ]
        let complete = try JSONSerialization.data(withJSONObject: payload)
        var body = Data()
        body.append(Data(#"data: {"type":"progress","stage":"denoise","step":1,"total":4}"#.utf8))
        body.append(Data("\n\n".utf8))
        body.append(Data("data: ".utf8))
        body.append(complete)
        body.append(Data("\n\n".utf8))

        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/video/generations")
            let response = HTTPURLResponse(url: request.url!,
                                           statusCode: 200,
                                           httpVersion: nil,
                                           headerFields: ["Content-Type": "text/event-stream"])!
            return (response, body)
        }
        defer { MockURLProtocol.handler = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = VideoClient(session: URLSession(configuration: configuration))
        let box = ProgressBox()
        let request = VideoGenerationRequest(model: "fake-video-model",
                                             prompt: "海浪",
                                             size: "64x64",
                                             frames: 9,
                                             steps: 4,
                                             seed: 42,
                                             firstFrameBase64: nil)
        let outcome = await client.generate(port: 1, request: request) { box.values.append($0) }

        switch outcome {
        case .success(let result):
            XCTAssertEqual(result.frames, 9)
            XCTAssertEqual(result.width, 64)
            XCTAssertEqual(result.fps, 24)
            XCTAssertEqual(result.mp4.dropFirst(4).prefix(4), Data("ftyp".utf8),
                           "MP4 的 ftyp box 应在开头")
            XCTAssertTrue(box.values.contains("去噪 1/4"))
            XCTAssertTrue(box.values.contains("正在封装 MP4"))
        case .failure(let error):
            XCTFail("流式响应解析失败：\(error.message)")
        }
    }

    // MARK: - REF2VA 参考素材

    func testReferenceRequestBodyCarriesImagesVideosAndDetail() throws {
        let request = VideoGenerationRequest(
            model: "ref2va",
            prompt: "把参考视频里的人放进参考图的场景",
            size: "768x512",
            frames: 49,
            steps: 20,
            seed: 7,
            firstFrameBase64: "FIRST",
            lastFrameBase64: "LAST",
            referenceImagesBase64: ["IMG-1", "IMG-2"],
            referenceVideos: [VideoReferencePayload(framesBase64: ["F-1", "F-2"],
                                                    audioBase64: nil)],
            referenceDetail: .max
        )
        let body = VideoClient.requestBody(for: request)

        XCTAssertEqual(body["ref_images"] as? [String], ["IMG-1", "IMG-2"])
        let clips = try XCTUnwrap(body["ref_videos"] as? [[String: Any]])
        XCTAssertEqual(clips.count, 1)
        XCTAssertEqual(clips[0]["frames"] as? [String], ["F-1", "F-2"])
        XCTAssertNil(clips[0]["audio"], "这一版参考视频只抽帧，不带音轨")
        XCTAssertEqual(body["ref_image_size"] as? String, "max")
        XCTAssertEqual(body["num_frames"] as? Int, 49)
        XCTAssertEqual(body["first_frame_image"] as? String, "FIRST")
    }

    func testReferenceDetailMatchOmitsSizeHint() {
        let request = VideoGenerationRequest(
            model: "ref2va", prompt: "p", size: "768x512", frames: 49, steps: 20,
            seed: nil, firstFrameBase64: nil,
            referenceImagesBase64: ["IMG"],
            referenceVideos: [],
            referenceDetail: .match
        )
        let body = VideoClient.requestBody(for: request)
        XCTAssertEqual(body["ref_images"] as? [String], ["IMG"])
        XCTAssertNil(body["ref_image_size"], "match 是服务端默认值，不该显式发送")
        XCTAssertNil(body["ref_videos"], "没有参考视频时不要塞空数组")
    }

    func testReferencesOnlyOfferedForRef2VA() {
        let ref2va = EngineModel(id: "mlx-community/MiniMax-H3-REF2VA-8bit",
                                 capabilities: ["video"], engine: .mlxServe)
        XCTAssertTrue(ref2va.supportsVideoReferences)

        let ltx = EngineModel(id: "mlx-community/LTX-Video-2B",
                              capabilities: ["video"], engine: .mlxServe)
        XCTAssertFalse(ltx.supportsVideoReferences,
                       "LTX 只吃首尾帧，不能给用户开参考素材入口")

        let chat = EngineModel(id: "some-ref2va-chat",
                               capabilities: ["chat"], engine: .mlxServe)
        XCTAssertFalse(chat.supportsVideoReferences)
    }

    /// 真机联调入口：只有显式给出本机 mlx-serve 端口时才跑，普通 `swift test`
    /// 不会去碰网络。视频生成很慢，帧数与步数都压到最小。
    func testLiveVideoGenerationWhenRequested() async throws {
        guard let raw = ProcessInfo.processInfo.environment["FLASHCAT_LIVE_VIDEO_PORT"],
              let port = Int(raw) else {
            throw XCTSkip("未设置 FLASHCAT_LIVE_VIDEO_PORT，跳过真实视频生成")
        }
        let request = VideoGenerationRequest(model: "ddalcu/MiniMax-H3-FL2VA-MLX-Serve-8bit",
                                             prompt: "A calm ocean wave at sunset, cinematic",
                                             size: "384x256",
                                             frames: 9,
                                             steps: 4,
                                             seed: 42,
                                             firstFrameBase64: nil)
        let box = ProgressBox()
        let outcome = await VideoClient().generate(port: port, request: request) {
            box.values.append($0)
        }

        switch outcome {
        case .success(let result):
            // 服务端可能把请求帧数对齐到模型允许的长度（H3 实测 9 → 22），
            // 以响应里的实际值为准，UI 的图注也照它显示。
            XCTAssertGreaterThanOrEqual(result.frames, 9)
            XCTAssertEqual(result.width, 384)
            XCTAssertEqual(result.height, 256)
            XCTAssertFalse(box.values.isEmpty)
            let url = URL(fileURLWithPath: "/tmp/flashcat-live-video.mp4")
            try result.mp4.write(to: url)
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            XCTAssertEqual(tracks.count, 1)
            let duration = try await asset.load(.duration)
            XCTAssertGreaterThan(duration.seconds, 0.2)
        case .failure(let error):
            XCTFail("真实视频生成失败：\(error.message)")
        }
    }

    // MARK: - 字节级快路径

    /// 载荷一旦超过阈值就走字节级扫描；它必须和 JSON 路径解出**一模一样**的帧。
    func testLargePayloadScannerMatchesJSONPath() throws {
        let rgb = makeRGB(frames: 22, width: 128, height: 96)   // 810 KB，稳稳过阈值
        let json: [String: Any] = [
            "format": "rgb8",
            "frames": 22,
            "width": 128,
            "height": 96,
            "fps": 24,
            "data": rgb.base64EncodedString(),
        ]
        let line = "data: " + String(decoding: try JSONSerialization.data(withJSONObject: json),
                                     as: UTF8.self)

        let slow = try XCTUnwrap(VideoPayload.frames(in: json))
        let fast = try XCTUnwrap(VideoPayloadScanner.frames(inLine: line),
                                 "大载荷该走字节级扫描")
        XCTAssertEqual(fast.rgb, slow.rgb)
        XCTAssertEqual(fast.rgb, rgb)
        XCTAssertEqual(fast.frames, 22)
        XCTAssertEqual(fast.width, 128)
        XCTAssertEqual(fast.height, 96)
        XCTAssertEqual(fast.fps, 24)
        XCTAssertNil(fast.audio)
    }

    /// 引擎会按 76 字符折行，JSON 里留下的是 `\n` 转义。旧代码为此整份复制一次
    /// 去换行；新路径在扫描时跳过，结果必须一致。
    func testLargePayloadScannerSkipsWrappedBase64() throws {
        let rgb = makeRGB(frames: 8, width: 128, height: 96)
        let encoded = rgb.base64EncodedString()
        let wrapped = stride(from: 0, to: encoded.count, by: 76).map { offset -> String in
            let start = encoded.index(encoded.startIndex, offsetBy: offset)
            let end = encoded.index(start, offsetBy: min(76, encoded.count - offset))
            return String(encoded[start..<end])
        }.joined(separator: "\n")
        let json: [String: Any] = [
            "format": "rgb8", "frames": 8, "width": 128, "height": 96,
            "fps": 25, "data": wrapped,
        ]
        let line = "data: " + String(decoding: try JSONSerialization.data(withJSONObject: json),
                                     as: UTF8.self)

        let decoded = try XCTUnwrap(VideoPayloadScanner.frames(inLine: line))
        XCTAssertEqual(decoded.rgb, rgb, "折行只是排版，解出来的字节必须和原始一致")
        XCTAssertEqual(decoded.fps, 25)
    }

    /// 字段顺序不能影响解析，字符串值里出现的同名键也不能被当成字段。
    func testLargePayloadScannerIgnoresKeysInsideStrings() throws {
        let rgb = makeRGB(frames: 6, width: 128, height: 96)
        let json = """
        {"note":"\\"frames\\": 1, \\"width\\": 2, \\"format\\": \\"jpeg\\"","format":"rgb8",\
        "data":"\(rgb.base64EncodedString())","height":96,"width":128,"frames":6,"fps":30}
        """
        let decoded = try XCTUnwrap(VideoPayloadScanner.frames(inLine: "data: " + json))
        XCTAssertEqual(decoded.frames, 6)
        XCTAssertEqual(decoded.width, 128)
        XCTAssertEqual(decoded.height, 96)
        XCTAssertEqual(decoded.fps, 30)
        XCTAssertEqual(decoded.rgb, rgb)
    }

    func testLargePayloadScannerRejectsBrokenPayloads() throws {
        let rgb = makeRGB(frames: 6, width: 128, height: 96)
        let good = rgb.base64EncodedString()
        let truncated = String(good.prefix(good.count - 40))
        let json = """
        {"format":"rgb8","frames":6,"width":128,"height":96,"data":"\(truncated)"}
        """
        XCTAssertNil(VideoPayloadScanner.frames(inLine: "data: " + json),
                     "少一截的帧数据不能拿去编码")
        XCTAssertNil(VideoPayloadScanner.frames(inLine: "data: {\"format\":\"rgb8\"}"))
        XCTAssertNil(VideoPayloadScanner.frames(inLine: "{\"format\":\"rgb8\"}"),
                     "没有 data: 前缀的行不属于 SSE 事件")
    }

    func testLargePayloadScannerKeepsAudioContract() throws {
        let rgb = makeRGB(frames: 6, width: 128, height: 96)
        let pcm = Data([0, 1, 2, 3])
        let json = """
        {"format":"rgb8","frames":6,"width":128,"height":96,"fps":24,\
        "data":"\(rgb.base64EncodedString())","audio_data":"\(pcm.base64EncodedString())",\
        "audio_format":"pcm_s16le","audio_sample_rate":16000,"audio_channels":2}
        """
        let decoded = try XCTUnwrap(VideoPayloadScanner.frames(inLine: "data: " + json))
        XCTAssertEqual(decoded.audio?.pcm, pcm)
        XCTAssertEqual(decoded.audio?.sampleRate, 16_000)
        XCTAssertEqual(decoded.audio?.channels, 2)

        // 音轨对不上就只丢音轨，视频照旧。
        let bad = json.replacingOccurrences(of: "\"audio_channels\":2",
                                            with: "\"audio_channels\":3")
        XCTAssertNil(try XCTUnwrap(VideoPayloadScanner.frames(inLine: "data: " + bad)).audio)
    }

    /// 真的走一遍流式客户端：大载荷不经过 JSONSerialization 也要能封出可播的 MP4。
    func testStreamingLargePayloadBypassesJSONPath() async throws {
        let rgb = makeRGB(frames: 10, width: 128, height: 96)
        let payload: [String: Any] = [
            "frames": 10, "width": 128, "height": 96, "fps": 24,
            "format": "rgb8", "data": rgb.base64EncodedString(),
        ]
        XCTAssertGreaterThan(rgb.count, 256 * 1024, "这个用例必须触发字节级快路径")

        var body = Data("data: {\"type\":\"progress\",\"stage\":\"denoise\",\"step\":1,\"total\":2}\n\n".utf8)
        body.append(Data("data: ".utf8))
        body.append(try JSONSerialization.data(withJSONObject: payload))
        body.append(Data("\n\n".utf8))

        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: nil,
                                           headerFields: ["Content-Type": "text/event-stream"])!
            return (response, body)
        }
        defer { MockURLProtocol.handler = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = VideoClient(session: URLSession(configuration: configuration))
        let request = VideoGenerationRequest(model: "fake-video-model", prompt: "海浪",
                                             size: "128x96", frames: 10, steps: 2,
                                             seed: 1, firstFrameBase64: nil)
        let outcome = await client.generate(port: 1, request: request) { _ in }

        switch outcome {
        case .success(let result):
            XCTAssertEqual(result.frames, 10)
            XCTAssertEqual(result.width, 128)
            XCTAssertEqual(result.mp4.dropFirst(4).prefix(4), Data("ftyp".utf8))
        case .failure(let error):
            XCTFail("大载荷流式解析失败：\(error.message)")
        }
    }

    /// 1280×704 是面板允许的最大尺寸；H3 实测会把 249 帧补到 260。
    /// 预算必须覆盖这条组合，否则引擎生成完也会被客户端整包丢掉。
    func testFrameBudgetCoversLargestUIOption() {
        let requested = 1280 * 704 * 249 * 3
        let padded = 1280 * 704 * 260 * 3
        XCTAssertGreaterThan(padded, requested)
        XCTAssertGreaterThanOrEqual(VideoPayloadScanner.maxFrameBytes, padded)
    }

    /// 体积超限要报 `.tooLarge`，不能和「格式坏了」一起变成 nil：
    /// 前者可以告诉用户调小参数，后者只能报解析失败。
    func testPayloadReportsSizeLimitBeforeDecoding() {
        let rgb = makeRGB(frames: 2, width: 8, height: 8)   // 384 B
        let json: [String: Any] = [
            "frames": 2, "width": 8, "height": 8,
            "format": "rgb8", "data": rgb.base64EncodedString(),
        ]

        switch VideoPayload.parse(json, limit: 383) {
        case .tooLarge(let required):
            XCTAssertEqual(required, 384)
        default:
            XCTFail("超过预算时应返回 tooLarge")
        }

        switch VideoPayload.parse(json, limit: 384) {
        case .frames(let decoded):
            XCTAssertEqual(decoded.rgb, rgb)
        default:
            XCTFail("刚好等于预算时应能正常解出")
        }
    }

    func testScannerReportsSizeLimit() {
        let rgb = makeRGB(frames: 2, width: 8, height: 8)
        let json = "{\"format\":\"rgb8\",\"frames\":2,\"width\":8,\"height\":8,"
            + "\"data\":\"\(rgb.base64EncodedString())\"}"
        switch VideoPayloadScanner.parse(inLine: "data: " + json, limit: 383) {
        case .tooLarge(let required):
            XCTAssertEqual(required, 384)
        default:
            XCTFail("字节级路径也应返回 tooLarge")
        }
    }

    /// 预检必须在发请求之前：一段 1280×704、500 帧的请求要跑很久，
    /// 不能等引擎生成完再报「数据太大」。
    func testPreflightRejectsOversizedRequestBeforeNetwork() async {
        MockURLProtocol.handler = { _ in
            XCTFail("超预算请求不该发到网络")
            throw URLError(.badURL)
        }
        defer { MockURLProtocol.handler = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = VideoClient(session: URLSession(configuration: configuration))
        let request = VideoGenerationRequest(model: "fake-video-model", prompt: "太长",
                                             size: "1280x704", frames: 500, steps: 4,
                                             seed: 1, firstFrameBase64: nil)
        let outcome = await client.generate(port: 1, request: request) { _ in }

        switch outcome {
        case .failure(let error):
            XCTAssertTrue(error.message.contains("视频数据太大"), error.message)
        case .success:
            XCTFail("超过 1 GiB 的请求应在发送前失败")
        }
    }

    private final class ProgressBox: @unchecked Sendable {
        var values: [String] = []
    }

    private func makeRGB(frames: Int, width: Int, height: Int) -> Data {
        var data = Data(count: frames * width * height * 3)
        for index in 0..<data.count {
            data[index] = UInt8((index * 37) % 251)
        }
        return data
    }

    private func makePCM(seconds: Double) -> Data {
        let sampleRate = 16_000
        let channels = 2
        let frameCount = Int(Double(sampleRate) * seconds)
        var data = Data(count: frameCount * channels * 2)
        for frame in 0..<frameCount {
            let sample = sin(Double(frame) * 2 * .pi * 440 / Double(sampleRate)) * 0.2
            let value = Int16(sample * Double(Int16.max))
            for channel in 0..<channels {
                let offset = (frame * channels + channel) * 2
                data[offset] = UInt8(truncatingIfNeeded: value)
                data[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
            }
        }
        return data
    }
}


private final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
