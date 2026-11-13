import CryptoKit
import XCTest
@testable import FlashCatKit

final class EngineInstallerTests: XCTestCase {

    // MARK: - Archive links

    /// splash 的真实归档里就带这四条软链（Python 发行包自带的）。它们全部是同
    /// 目录内的相对链接，一条都不能拦——拦了就是「Splash 安装失败」。
    func testSplashPackLinksStayInsideThePack() throws {
        let names = [
            "splash-1.6.1/",
            "splash-1.6.1/python/",
            "splash-1.6.1/python/bin/",
            "splash-1.6.1/python/bin/python3",
            "splash-1.6.1/python/bin/python3.13",
            "splash-1.6.1/python/lib/pkgconfig/python3.pc",
            "splash-1.6.1/python/lib/pkgconfig/python-3.13.pc",
            "splash-1.6.1/python/lib/pkgconfig/python3-embed.pc",
            "splash-1.6.1/python/lib/pkgconfig/python-3.13-embed.pc",
            "splash-1.6.1/python/share/man/man1/python3.1",
            "splash-1.6.1/python/share/man/man1/python3.13.1",
        ]
        let listing = [
            "lrwxr-xr-x 0 wangzhuo staff 0 Nov 11 19:13 splash-1.6.1/python/bin/python3 -> python3.13",
            "lrwxr-xr-x 0 wangzhuo staff 0 Nov 11 19:13 splash-1.6.1/python/lib/pkgconfig/python3.pc -> python-3.13.pc",
            "lrwxr-xr-x 0 wangzhuo staff 0 Nov 11 19:13 splash-1.6.1/python/lib/pkgconfig/python3-embed.pc -> python-3.13-embed.pc",
            "lrwxr-xr-x 0 wangzhuo staff 0 Nov 11 19:13 splash-1.6.1/python/share/man/man1/python3.1 -> python3.13.1",
        ]

        let links = try EngineInstaller.links(inListing: listing, names: names)
        XCTAssertEqual(links, [
            ArchiveLink(kind: .symbolic, path: "splash-1.6.1/python/bin/python3", target: "python3.13"),
            ArchiveLink(kind: .symbolic, path: "splash-1.6.1/python/lib/pkgconfig/python3.pc", target: "python-3.13.pc"),
            ArchiveLink(kind: .symbolic, path: "splash-1.6.1/python/lib/pkgconfig/python3-embed.pc", target: "python-3.13-embed.pc"),
            ArchiveLink(kind: .symbolic, path: "splash-1.6.1/python/share/man/man1/python3.1", target: "python3.13.1"),
        ])
        XCTAssertNoThrow(try EngineInstaller.validate(links: links, stripComponents: 1))
    }

    func testLinksThatLeaveThePackAreRejected() throws {
        let names = ["omlx-0.7.3/run", "omlx-0.7.3/bin/python3", "omlx-0.7.3/link"]
        let rejected = [
            // 绝对路径：就是终审修掉的那条「pack/link -> ~/.ssh/id_rsa」
            "lrwxr-xr-x 0 zhuo staff 0 Nov 11 15:00 omlx-0.7.3/run -> /Users/zhuo/.ssh/id_rsa",
            "lrwxr-xr-x 0 zhuo staff 0 Nov 11 15:00 omlx-0.7.3/run -> ~/.ssh/id_rsa",
            // 相对但爬出根
            "lrwxr-xr-x 0 zhuo staff 0 Nov 11 15:00 omlx-0.7.3/bin/python3 -> ../../../../etc/passwd",
            // 去掉顶层目录之后 `..` 已经无处可退
            "lrwxr-xr-x 0 zhuo staff 0 Nov 11 15:00 omlx-0.7.3/link -> ../outside",
            // 硬链的目标相对归档根，同样不许出包
            "hrw-r--r-- 0 zhuo staff 0 Nov 11 15:00 omlx-0.7.3/bin/python3 link to ../outside",
            "hrw-r--r-- 0 zhuo staff 0 Nov 11 15:00 omlx-0.7.3/bin/python3 link to /etc/passwd",
        ]
        for line in rejected {
            let links = try EngineInstaller.links(inListing: [line], names: names)
            XCTAssertThrowsError(try EngineInstaller.validate(links: links, stripComponents: 1),
                                 "应当拒绝：\(line)") { error in
                guard case EngineInstallError.unsafeArchiveLink = error else {
                    return XCTFail("期望 unsafeArchiveLink，实际 \(error)")
                }
            }
        }

        // 看不懂的链接行按失败处理，不跳过：跳过等于把决定权交给 tar。
        XCTAssertThrowsError(try EngineInstaller.links(
            inListing: ["lrwxr-xr-x 0 zhuo staff 0 Nov 11 15:00 omlx-0.7.3/run"],
            names: names)) { error in
            guard case EngineInstallError.unsafeArchiveLink = error else {
                return XCTFail("期望 unsafeArchiveLink，实际 \(error)")
            }
        }
    }

    func testLinksMayClimbAsLongAsTheyStayInsideThePack() throws {
        let names = [
            "omlx-0.7.3/python/bin/python3",
            "omlx-0.7.3/python/lib/python3.13",
            "omlx-0.7.3/link",
            "omlx-0.7.3/bin/pair",
        ]
        let allowed = [
            "lrwxr-xr-x 0 zhuo staff 0 Nov 11 15:00 omlx-0.7.3/python/bin/python3 -> ../lib/python3.13",
            "lrwxr-xr-x 0 zhuo staff 0 Nov 11 15:00 omlx-0.7.3/link -> python/bin/python3",
            "hrw-r--r-- 0 zhuo staff 0 Nov 11 15:00 omlx-0.7.3/bin/pair link to omlx-0.7.3/bin/pair",
        ]
        for line in allowed {
            let links = try EngineInstaller.links(inListing: [line], names: names)
            XCTAssertNoThrow(try EngineInstaller.validate(links: links, stripComponents: 1),
                             "不应当拒绝：\(line)")
        }
    }

    /// 链接名字里带空格、名字里带 ` -> ` 时，靠归档名字表里最长的后缀认出名字。
    func testLinkNamesWithSpacesOrArrowsStillParse() throws {
        let names = ["omlx-0.7.3/My Dir/python3", "omlx-0.7.3/weird -> name"]
        let links = try EngineInstaller.links(inListing: [
            "lrwxr-xr-x 0 zhuo staff 0 Nov 11 15:00 omlx-0.7.3/My Dir/python3 -> python3.13",
            "lrwxr-xr-x 0 zhuo staff 0 Nov 11 15:00 omlx-0.7.3/weird -> name -> python3.13",
        ], names: names)
        XCTAssertEqual(links.map(\.path), ["omlx-0.7.3/My Dir/python3", "omlx-0.7.3/weird -> name"])
        XCTAssertEqual(links.map(\.target), ["python3.13", "python3.13"])
    }

    /// 解包后的兜底审计：列表解析漏了什么，落盘的链接还要再看一遍。
    func testExtractionAuditRejectsLinksThatLeaveThePack() throws {
        let root = workDirectory.appendingPathComponent("audit", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: bin.appendingPathComponent("python3.13"))
        try FileManager.default.createSymbolicLink(atPath: bin.appendingPathComponent("python3").path,
                                                    withDestinationPath: "python3.13")
        XCTAssertNoThrow(try EngineInstaller.validateExtractedLinks(in: root))

        try FileManager.default.createSymbolicLink(atPath: bin.appendingPathComponent("escape").path,
                                                    withDestinationPath: "../../../../etc/passwd")
        XCTAssertThrowsError(try EngineInstaller.validateExtractedLinks(in: root)) { error in
            guard case EngineInstallError.unsafeArchiveLink(let link) = error else {
                return XCTFail("期望 unsafeArchiveLink，实际 \(error)")
            }
            XCTAssertTrue(link.contains("bin/escape"), link)
        }

        try FileManager.default.removeItem(at: bin.appendingPathComponent("escape"))
        try FileManager.default.createSymbolicLink(atPath: bin.appendingPathComponent("absolute").path,
                                                    withDestinationPath: "/etc/passwd")
        XCTAssertThrowsError(try EngineInstaller.validateExtractedLinks(in: root))
    }


    private var workDirectory: URL!
    private var packsDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        packsDirectory = workDirectory.appendingPathComponent("packs", isDirectory: true)
        try FileManager.default.createDirectory(at: packsDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDirectory {
            try? FileManager.default.removeItem(at: workDirectory)
        }
        workDirectory = nil
        packsDirectory = nil
        try super.tearDownWithError()
    }

    // MARK: - Install

    func testReleaseKnowsWhetherItsSourceExists() throws {
        let missing = EnginePackRelease(version: "0.7.2",
                                        url: "file:///tmp/\(UUID().uuidString).tar.gz",
                                        sha256: String(repeating: "a", count: 64))
        XCTAssertFalse(missing.hasAvailableSource)

        let remote = EnginePackRelease(version: "0.7.2",
                                       url: "https://example.invalid/omlx-0.7.2.tar.gz",
                                       sha256: String(repeating: "a", count: 64))
        XCTAssertTrue(remote.hasAvailableSource)

        let local = workDirectory.appendingPathComponent("omlx-0.7.2.tar.gz")
        XCTAssertTrue(FileManager.default.createFile(atPath: local.path, contents: Data()))
        let present = EnginePackRelease(version: "0.7.2", url: local.absoluteString,
                                        sha256: String(repeating: "a", count: 64))
        XCTAssertTrue(present.hasAvailableSource)
    }

    func testInstallsFromLocalArchive() async throws {
        let archive = try makeArchive(version: "0.7.2", topLevelDirectory: "omlx-0.7.2")
        let checksum = try sha256Hex(of: archive)
        let release = EnginePackRelease(version: "0.7.2",
                                        url: archive.absoluteString,
                                        sha256: checksum,
                                        bytes: nil,
                                        minMacOS: "14.0",
                                        notes: "本地归档")

        let installer = EngineInstaller(environment: makeEnvironment())
        let phases = PhaseBox()
        let installation = try await installer.install(release, for: .omlx) { phases.append($0) }

        XCTAssertEqual(installation.manifest.version, "0.7.2")
        XCTAssertEqual(installation.id, .omlx)
        XCTAssertEqual(installation.root.path, packsDirectory.appendingPathComponent("omlx/0.7.2").path)
        let versions = await installer.installedVersions(.omlx)
        XCTAssertEqual(versions, ["0.7.2"])
        let installedPath = await installer.installedRoot(.omlx, version: "0.7.2")
        XCTAssertEqual(installedPath, packsDirectory.appendingPathComponent("omlx/0.7.2").path)

        // The pack really landed: manifest decodes and the entrypoint is executable.
        let reloaded = EngineInstallation.load(root: installation.root)
        XCTAssertEqual(reloaded?.manifest.version, "0.7.2")
        let entrypoint = installation.root.appendingPathComponent("python/bin/python3")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: entrypoint.path))

        // No staging or partial leftovers anywhere under the packs root.
        XCTAssertTrue(residue(in: downloadsDirectory).isEmpty, "\(residue(in: downloadsDirectory))")
        XCTAssertTrue(residue(in: stagingDirectory).isEmpty, "\(residue(in: stagingDirectory))")
        XCTAssertTrue(allFiles(under: packsDirectory).allSatisfy { !$0.hasSuffix(".partial") })

        let recorded = phases.phases
        XCTAssertEqual(recorded.first, .resolving)
        XCTAssertEqual(recorded.last, .installed(version: "0.7.2"))
        for expected in [EngineInstallPhase.verifying, .unpacking, .validating, .activating] {
            XCTAssertTrue(recorded.contains(expected), "缺少阶段 \(expected.label)")
        }
        XCTAssertTrue(recorded.contains {
            if case .downloading(let value, _, _) = $0 { return value == 1.0 }
            return false
        })
    }

    func testChecksumMismatchLeavesNothingBehind() async throws {
        let archive = try makeArchive(version: "0.7.2", topLevelDirectory: "omlx-0.7.2")
        let release = EnginePackRelease(version: "0.7.2",
                                        url: archive.absoluteString,
                                        sha256: String(repeating: "0", count: 64))

        let installer = EngineInstaller(environment: makeEnvironment())
        let phases = PhaseBox()
        await XCTAssertThrowsErrorAsync {
            _ = try await installer.install(release, for: .omlx) { phases.append($0) }
        } verify: { error in
            guard case EngineInstallError.checksumMismatch(let expected, let actual) = error else {
                return XCTFail("期望 checksumMismatch，实际 \(error)")
            }
            XCTAssertEqual(expected, String(repeating: "0", count: 64))
            XCTAssertEqual(actual.count, 64)
        }

        XCTAssertTrue(residue(in: downloadsDirectory).isEmpty, "\(residue(in: downloadsDirectory))")
        XCTAssertTrue(residue(in: stagingDirectory).isEmpty, "\(residue(in: stagingDirectory))")
        XCTAssertFalse(FileManager.default.fileExists(atPath: packsDirectory.appendingPathComponent("omlx").path))
        let versionsAfterFailure = await installer.installedVersions(.omlx)
        XCTAssertEqual(versionsAfterFailure, [])
        if case .failed(let message)? = phases.phases.last {
            XCTAssertFalse(message.isEmpty)
        } else {
            XCTFail("最后一个阶段应是 failed")
        }
    }

    func testRejectsUnsupportedArchive() async throws {
        let installer = EngineInstaller(environment: makeEnvironment())
        let release = EnginePackRelease(version: "0.7.2",
                                        url: "file:///tmp/omlx-0.7.2.zip",
                                        sha256: String(repeating: "a", count: 64))
        await XCTAssertThrowsErrorAsync {
            _ = try await installer.install(release, for: .omlx) { _ in }
        } verify: { error in
            guard case EngineInstallError.unsupportedArchive(let url) = error else {
                return XCTFail("期望 unsupportedArchive，实际 \(error)")
            }
            XCTAssertTrue(url.hasSuffix(".zip"))
        }

        let tgz = EnginePackRelease(version: "0.7.2",
                                    url: "file:///tmp/omlx-0.7.2.tgz",
                                    sha256: String(repeating: "a", count: 64))
        await XCTAssertThrowsErrorAsync {
            _ = try await installer.install(tgz, for: .omlx) { _ in }
        } verify: { error in
            // .tgz is accepted as a format; it only fails because the file is absent.
            XCTAssertEqual(error as? EngineInstallError,
                           .downloadFailed("找不到下载源文件：/tmp/omlx-0.7.2.tgz"))
        }
    }

    func testInstallsFromFlatArchiveWithoutStripping() async throws {
        // No single top-level folder: stripping a component here would throw
        // the manifest away, so the detector must choose 0 for this layout.
        let archive = try makeArchive(version: "0.7.4", topLevelDirectory: nil)
        let release = EnginePackRelease(version: "0.7.4",
                                        url: archive.absoluteString,
                                        sha256: try sha256Hex(of: archive))

        let installer = EngineInstaller(environment: makeEnvironment())
        let installation = try await installer.install(release, for: .omlx) { _ in }
        XCTAssertEqual(installation.manifest.version, "0.7.4")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: installation.root.appendingPathComponent("manifest.json").path))
    }

    /// 回归：1.5.6 把软链一律拒了，splash 的 Python 发行包装不上。同包内的相对
    /// 软链必须能装，而且装完还是软链（不是被 tar 解成副本）。
    func testInstallsArchiveWithRelativeSymlinks() async throws {
        let archive = try makeArchive(version: "1.6.1",
                                      topLevelDirectory: "splash-1.6.1",
                                      engineID: "splash",
                                      links: [
                                        ("python/lib/pkgconfig/python3.pc", "python-3.13.pc"),
                                        ("python/share/man/man1/python3.1", "python3.13.1"),
                                      ])
        let release = EnginePackRelease(version: "1.6.1",
                                        url: archive.absoluteString,
                                        sha256: try sha256Hex(of: archive))

        let installer = EngineInstaller(environment: makeEnvironment())
        let installation = try await installer.install(release, for: .splash) { _ in }
        XCTAssertEqual(installation.manifest.version, "1.6.1")

        let fm = FileManager.default
        let pc = installation.root.appendingPathComponent("python/lib/pkgconfig/python3.pc")
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: pc.path), "python-3.13.pc")
        let man = installation.root.appendingPathComponent("python/share/man/man1/python3.1")
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: man.path), "python3.13.1")
        let entrypoint = installation.root.appendingPathComponent("python/bin/python3")
        XCTAssertTrue(fm.isExecutableFile(atPath: entrypoint.path))
        XCTAssertTrue(residue(in: stagingDirectory).isEmpty, "\(residue(in: stagingDirectory))")
    }

    /// 指向包外的链接在 tar 写盘之前就被拒，暂存目录与下载残留都要清干净。
    func testInstallRejectsLinkThatLeavesThePack() async throws {
        let archive = try makeArchive(version: "1.6.1",
                                      topLevelDirectory: "splash-1.6.1",
                                      engineID: "splash",
                                      links: [("python/lib/escape", "../../../../etc/passwd")])
        let release = EnginePackRelease(version: "1.6.1",
                                        url: archive.absoluteString,
                                        sha256: try sha256Hex(of: archive))

        let installer = EngineInstaller(environment: makeEnvironment())
        let phases = PhaseBox()
        await XCTAssertThrowsErrorAsync {
            _ = try await installer.install(release, for: .splash) { phases.append($0) }
        } verify: { error in
            guard case EngineInstallError.unsafeArchiveLink(let link) = error else {
                return XCTFail("期望 unsafeArchiveLink，实际 \(error)")
            }
            XCTAssertTrue(link.contains("python/lib/escape"), link)
        }

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: packsDirectory.appendingPathComponent("splash").path))
        XCTAssertTrue(residue(in: downloadsDirectory).isEmpty, "\(residue(in: downloadsDirectory))")
        XCTAssertTrue(residue(in: stagingDirectory).isEmpty, "\(residue(in: stagingDirectory))")
        if case .failed(let message)? = phases.phases.last {
            XCTAssertTrue(message.contains("指向包外"), message)
        } else {
            XCTFail("最后一个阶段应是 failed")
        }
    }

    // MARK: - Index

    func testLoadIndexFromLocalFile() async throws {
        let indexURL = workDirectory.appendingPathComponent("pack-index.json")
        let json = """
        {
          "schemaVersion": 1,
          "engines": {
            "omlx": [
              { "version": "0.7.2", "url": "https://example.invalid/omlx-0.7.2.tar.gz", "sha256": "aa" },
              { "version": "0.7.3", "url": "https://example.invalid/omlx-0.7.3.tar.gz", "sha256": "bb" }
            ],
            "teleportation": [
              { "version": "9.9.9", "url": "https://example.invalid/x.tar.gz", "sha256": "cc" }
            ]
          }
        }
        """
        try Data(json.utf8).write(to: indexURL, options: .atomic)

        var environment = makeEnvironment()
        environment.indexURL = URL(fileURLWithPath: indexURL.path)
        let installer = EngineInstaller(environment: environment)

        let index = try await installer.loadIndex()
        XCTAssertEqual(index.schemaVersion, 1)
        XCTAssertEqual(index.releases(for: .omlx).map(\.version), ["0.7.3", "0.7.2"])
        XCTAssertEqual(index.latest(for: .omlx)?.sha256, "bb")
        XCTAssertTrue(index.releases(for: .mtplx).isEmpty)
        // Keys that are not engine identifiers are dropped, not surfaced.
        XCTAssertNil(index.engines["teleportation"])
    }

    /// A relative `url` belongs to the index it arrived on: the same index has
    /// to work served over https and read from a local file, so nothing in it may
    /// name one machine's absolute path. Entries that already are absolute pass
    /// through untouched.
    func testLoadIndexResolvesRelativeURLsAgainstTheIndexLocation() async throws {
        let indexURL = workDirectory.appendingPathComponent("pack-index.json")
        let json = """
        {
          "schemaVersion": 1,
          "engines": {
            "omlx": [
              { "version": "0.7.3", "url": "omlx-0.7.3-arm64-macos26.0.tar.gz", "sha256": "bb" },
              { "version": "0.7.2", "url": "https://example.invalid/omlx-0.7.2.tar.gz", "sha256": "aa" }
            ]
          }
        }
        """
        try Data(json.utf8).write(to: indexURL, options: .atomic)

        var environment = makeEnvironment()
        environment.indexURL = URL(fileURLWithPath: indexURL.path)
        let index = try await EngineInstaller(environment: environment).loadIndex()

        XCTAssertEqual(index.latest(for: .omlx)?.url,
                       workDirectory.appendingPathComponent("omlx-0.7.3-arm64-macos26.0.tar.gz").absoluteString)
        XCTAssertEqual(index.releases(for: .omlx).last?.url, "https://example.invalid/omlx-0.7.2.tar.gz")
    }

    /// Same rule with an index served over the network: the base is the index's
    /// own address, never a local path.
    func testRelativeURLResolvesAgainstAnHTTPSIndex() {
        let release = EnginePackRelease(version: "0.7.3",
                                       url: "omlx-0.7.3-arm64-macos26.0.tar.gz",
                                       sha256: "bb")
        let index = URL(string: "https://example.invalid/packs/pack-index.json")!

        XCTAssertEqual(release.resolvedAgainst(index: index).url,
                       "https://example.invalid/packs/omlx-0.7.3-arm64-macos26.0.tar.gz")
    }

    /// A relative address must fail before the network call, not inside it.
    func testInstallRejectsARelativeAddress() async throws {
        let release = EnginePackRelease(version: "0.7.2", url: "omlx-0.7.2.tar.gz", sha256: "aa")
        let installer = EngineInstaller(environment: makeEnvironment())

        await XCTAssertThrowsErrorAsync {
            _ = try await installer.install(release, for: .omlx) { _ in }
        } verify: { error in
            guard case EngineInstallError.downloadFailed(let message) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("不是绝对地址"), message)
        }
    }

    /// An index behind a redirect: the archives sit beside the copy that was
    /// actually served, so `/latest/pack-index.json` must not send entries to
    /// `/latest/`.
    func testRelativeURLResolvesAgainstThePostRedirectIndexAddress() async throws {
        let body = """
        {"schemaVersion":1,"engines":{"omlx":[
          {"version":"0.7.3","url":"omlx-0.7.3-arm64-macos26.0.tar.gz","sha256":"bb"}
        ]}}
        """
        let server = GatewayHTTPServer { request in
            switch request.path {
            case "/latest/pack-index.json":
                var redirect = GatewayResponse()
                redirect.status = 302
                redirect.headers["Location"] = "/v1.4.1/pack-index.json"
                return redirect
            case "/v1.4.1/pack-index.json":
                var response = GatewayResponse()
                response.body = Data(body.utf8)
                return response
            default:
                return .json(["error": "nope"], status: 404)
            }
        }
        var port: UInt16 = 0
        for candidate in UInt16(39200)...UInt16(39240) where await server.start(port: candidate) {
            port = candidate
            break
        }
        guard port != 0 else {
            server.stop()
            return XCTFail("没有可用的测试端口")
        }
        defer { server.stop() }

        var environment = makeEnvironment()
        environment.indexURL = URL(string: "http://127.0.0.1:\(port)/latest/pack-index.json")!
        let index = try await EngineInstaller(environment: environment).loadIndex()

        XCTAssertEqual(index.latest(for: .omlx)?.url,
                       "http://127.0.0.1:\(port)/v1.4.1/omlx-0.7.3-arm64-macos26.0.tar.gz")
    }

    func testLoadIndexWithoutAnySourceThrows() async throws {
        var environment = makeEnvironment()
        environment.indexURL = nil
        environment.bundledIndexPath = nil
        let installer = EngineInstaller(environment: environment)
        await XCTAssertThrowsErrorAsync {
            _ = try await installer.loadIndex()
        } verify: { error in
            XCTAssertEqual(error as? EngineInstallError, .indexUnavailable)
        }
    }

    // MARK: - Uninstall

    func testUninstallRemovesVersion() async throws {
        let installer = EngineInstaller(environment: makeEnvironment())
        let release = try makeRelease(version: "0.7.2")
        _ = try await installer.install(release, for: .omlx) { _ in }

        let root = packsDirectory.appendingPathComponent("omlx/0.7.2")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))

        try await installer.uninstall(.omlx, version: "0.7.2")
        let remaining = await installer.installedVersions(.omlx)
        XCTAssertEqual(remaining, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertTrue(residue(in: packsDirectory.appendingPathComponent(".trash")).isEmpty)

        // Removing something that is already gone must not throw.
        try await installer.uninstall(.omlx, version: "0.7.2")
    }

    func testInstallFailureKeepsExistingVersion() async throws {
        let installer = EngineInstaller(environment: makeEnvironment())
        let good = try makeRelease(version: "0.7.2")
        _ = try await installer.install(good, for: .omlx) { _ in }
        let afterInstall = await installer.installedVersions(.omlx)
        XCTAssertEqual(afterInstall, ["0.7.2"])

        let archive = try makeArchive(version: "0.7.3", topLevelDirectory: "omlx-0.7.3")
        let broken = EnginePackRelease(version: "0.7.3",
                                       url: archive.absoluteString,
                                       sha256: String(repeating: "f", count: 64))
        await XCTAssertThrowsErrorAsync {
            _ = try await installer.install(broken, for: .omlx) { _ in }
        } verify: { error in
            guard case EngineInstallError.checksumMismatch = error else {
                return XCTFail("期望 checksumMismatch，实际 \(error)")
            }
        }

        let survivors = await installer.installedVersions(.omlx)
        XCTAssertEqual(survivors, ["0.7.2"])
        let surviving = EngineInstallation.load(root: packsDirectory.appendingPathComponent("omlx/0.7.2"))
        XCTAssertEqual(surviving?.manifest.version, "0.7.2")
        XCTAssertFalse(FileManager.default.fileExists(atPath: packsDirectory.appendingPathComponent("omlx/0.7.3").path))
        XCTAssertTrue(residue(in: downloadsDirectory).isEmpty)
        XCTAssertTrue(residue(in: stagingDirectory).isEmpty)
    }

    // MARK: - Phases

    func testPhaseLabelsAndFraction() {
        let downloading = EngineInstallPhase.downloading(progress: 0.42,
                                                         receivedBytes: 420,
                                                         totalBytes: 1000)
        XCTAssertTrue(downloading.label.contains("42"), downloading.label)
        XCTAssertEqual(downloading.fraction, 0.42)
        XCTAssertTrue(downloading.isBusy)

        XCTAssertNil(EngineInstallPhase.idle.fraction)
        XCTAssertNil(EngineInstallPhase.resolving.fraction)
        XCTAssertNil(EngineInstallPhase.verifying.fraction)
        XCTAssertNil(EngineInstallPhase.unpacking.fraction)
        XCTAssertNil(EngineInstallPhase.validating.fraction)
        XCTAssertNil(EngineInstallPhase.activating.fraction)
        XCTAssertNil(EngineInstallPhase.installed(version: "0.7.2").fraction)
        XCTAssertNil(EngineInstallPhase.failed(message: "坏了").fraction)

        XCTAssertEqual(EngineInstallPhase.idle.label, "待安装")
        XCTAssertEqual(EngineInstallPhase.resolving.label, "解析版本")
        XCTAssertEqual(EngineInstallPhase.verifying.label, "校验 SHA256")
        XCTAssertEqual(EngineInstallPhase.unpacking.label, "解包")
        XCTAssertEqual(EngineInstallPhase.validating.label, "校验包")
        XCTAssertEqual(EngineInstallPhase.activating.label, "激活")
        XCTAssertEqual(EngineInstallPhase.installed(version: "0.7.2").label, "已安装")
        XCTAssertEqual(EngineInstallPhase.failed(message: "网络中断").label, "失败：网络中断")

        XCTAssertFalse(EngineInstallPhase.idle.isBusy)
        XCTAssertFalse(EngineInstallPhase.installed(version: "0.7.2").isBusy)
        XCTAssertFalse(EngineInstallPhase.failed(message: "x").isBusy)
    }

    // MARK: - Fixtures

    private func makeEnvironment() -> EngineInstallEnvironment {
        EngineInstallEnvironment(packsDirectory: packsDirectory.path,
                                 indexURL: nil,
                                 bundledIndexPath: nil,
                                 tarPath: "/usr/bin/tar",
                                 xattrPath: "/usr/bin/xattr")
    }

    private func makeRelease(version: String) throws -> EnginePackRelease {
        let archive = try makeArchive(version: version, topLevelDirectory: "omlx-\(version)")
        return EnginePackRelease(version: version,
                                 url: archive.absoluteString,
                                 sha256: try sha256Hex(of: archive))
    }

    /// Builds a real `.tar.gz` on disk: either wrapped in one top-level folder
    /// (the layout the installer must strip) or flat.
    private func makeArchive(version: String,
                             topLevelDirectory: String?,
                             engineID: String = "omlx",
                             links: [(path: String, target: String)] = []) throws -> URL {
        let fm = FileManager.default
        let buildRoot = workDirectory.appendingPathComponent("build-\(UUID().uuidString)", isDirectory: true)
        let contentRoot = topLevelDirectory.map { buildRoot.appendingPathComponent($0, isDirectory: true) } ?? buildRoot
        let binDirectory = contentRoot.appendingPathComponent("python/bin", isDirectory: true)
        try fm.createDirectory(at: binDirectory, withIntermediateDirectories: true)

        let manifest = """
        {
          "schemaVersion": 1,
          "id": "\(engineID)",
          "name": "oMLX",
          "version": "\(version)",
          "kind": "bundled",
          "arch": "arm64",
          "minMacOS": "14.0",
          "entrypoint": "python/bin/python3",
          "workingDirectory": ".",
          "modelsSubdirectory": "models",
          "launchProfiles": {
            "default": { "args": ["-m", "omlx.cli", "serve", "--port", "{port}"] }
          },
          "health": { "path": "/health", "readyStatus": 200, "loadingStatus": 503 },
          "defaultPort": 8100,
          "modelSwitch": "hot",
          "capabilities": ["chat", "streaming"],
          "license": "Apache-2.0"
        }
        """
        try Data(manifest.utf8).write(to: contentRoot.appendingPathComponent("manifest.json"), options: .atomic)

        let entrypoint = binDirectory.appendingPathComponent("python3")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: entrypoint, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: entrypoint.path)

        for link in links {
            let url = contentRoot.appendingPathComponent(link.path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: url)
            try fm.createSymbolicLink(atPath: url.path, withDestinationPath: link.target)
        }

        let archive = workDirectory.appendingPathComponent("\(engineID)-\(version)-\(UUID().uuidString).tar.gz")
        var arguments = ["-czf", archive.path, "-C", buildRoot.path]
        if let topLevelDirectory {
            arguments.append(topLevelDirectory)
        } else {
            arguments.append(contentsOf: ["manifest.json", "python"])
        }
        let result = try runProcess("/usr/bin/tar", arguments)
        XCTAssertEqual(result.status, 0, "tar 打包失败：\(result.stderrText)")
        return archive
    }

    private func sha256Hex(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Helpers

    private var downloadsDirectory: URL {
        packsDirectory.appendingPathComponent(".downloads", isDirectory: true)
    }

    private var stagingDirectory: URL {
        packsDirectory.appendingPathComponent(".staging", isDirectory: true)
    }

    private func residue(in directory: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    }

    private func allFiles(under directory: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(at: directory,
                                                             includingPropertiesForKeys: nil) else {
            return []
        }
        var paths: [String] = []
        for case let url as URL in enumerator {
            paths.append(url.path)
        }
        return paths
    }

    private struct ProcessResult {
        var status: Int32
        var stdout: String
        var stderr: String
        var stderrText: String { stderr.isEmpty ? "无输出" : stderr }
    }

    private func runProcess(_ executable: String, _ arguments: [String]) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ProcessResult(status: process.terminationStatus,
                             stdout: String(decoding: outData, as: UTF8.self),
                             stderr: String(decoding: errData, as: UTF8.self)
                                 .trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

// MARK: - Test plumbing

/// Progress arrives from inside the installer actor; the box keeps the
/// collection thread-safe without leaking a mutable capture.
private final class PhaseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [EngineInstallPhase] = []

    func append(_ phase: EngineInstallPhase) {
        lock.lock()
        storage.append(phase)
        lock.unlock()
    }

    var phases: [EngineInstallPhase] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// `XCTAssertThrowsError` has no async variant.
private func XCTAssertThrowsErrorAsync(_ expression: () async throws -> Void,
                                       verify: (Error) -> Void = { _ in },
                                       file: StaticString = #filePath,
                                       line: UInt = #line) async {
    do {
        try await expression()
        XCTFail("期望抛出错误，但调用成功返回", file: file, line: line)
    } catch {
        verify(error)
    }
}
