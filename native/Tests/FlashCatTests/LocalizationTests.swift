import XCTest
@testable import FlashCat

/// The String Catalog is the only source of UI copy. These checks make sure a
/// packaging regression cannot silently drop either language.
final class LocalizationTests: XCTestCase {
    func testResourceBundleShipsBothLanguages() {
        let bundle = L10n.bundle
        XCTAssertTrue(bundle.localizations.contains("zh-Hans"))
        XCTAssertTrue(bundle.localizations.contains("en"))
    }

    func testEnglishCatalogTranslatesCoreStrings() throws {
        let path = try XCTUnwrap(L10n.bundle.path(forResource: "en", ofType: "lproj"))
        let english = try XCTUnwrap(Bundle(path: path))

        XCTAssertEqual(english.localizedString(forKey: "概览", value: nil, table: nil), "Overview")
        XCTAssertEqual(english.localizedString(forKey: "设置", value: nil, table: nil), "Settings")
        XCTAssertEqual(english.localizedString(forKey: "%@ · 端口 %@", value: nil, table: nil), "%@ · Port %@")
        XCTAssertEqual(english.localizedString(forKey: "下载", value: nil, table: nil), "Download")
    }

    func testChineseCatalogFallsBackToSourceStrings() throws {
        let path = try XCTUnwrap(L10n.bundle.path(forResource: "zh-Hans", ofType: "lproj"))
        let chinese = try XCTUnwrap(Bundle(path: path))

        XCTAssertEqual(chinese.localizedString(forKey: "概览", value: nil, table: nil), "概览")
        XCTAssertEqual(chinese.localizedString(forKey: "%@ · 端口 %@", value: nil, table: nil), "%@ · 端口 %@")
    }

    /// 快捷键已全部移除：应用内不再注册键盘快捷键，也不接管回车、方向键或
    /// esc。这条测试扫源码，防止某次改动把 `.keyboardShortcut` 或按键监听
    /// 悄悄加回来——那会同时推翻「鼠标可达 + CLI 键盘可达」的产品决定。
    func testNoInAppKeyboardShortcutsRemain() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/FlashCatTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // native/
            .appendingPathComponent("Sources/FlashCat")
        let enumerator = FileManager.default.enumerator(at: root,
                                                        includingPropertiesForKeys: nil,
                                                        options: [.skipsHiddenFiles])
        let files: [URL] = try XCTUnwrap(enumerator).compactMap { item in
            guard let url = item as? URL, url.pathExtension == "swift" else { return nil }
            return url
        }
        XCTAssertGreaterThan(files.count, 30, "源码目录扫描异常")

        let banned = [
            #"\.keyboardShortcut\s*\("#,
            #"\.onKeyPress\s*[({]"#,
            #"\.onExitCommand\b"#,
            #"\.onSubmit\s*[({]"#,
            #"NSEvent\.addLocalMonitorForEvents"#,
            #"addGlobalMonitorForEvents"#,
        ]
        var offenders: [String] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(source.startIndex..., in: source)
            for pattern in banned {
                let expression = try NSRegularExpression(pattern: pattern)
                if expression.firstMatch(in: source, range: range) != nil {
                    offenders.append(file.lastPathComponent + " ← " + pattern)
                }
            }
        }
        XCTAssertTrue(offenders.isEmpty,
                      "应用内不应再有键盘快捷键/按键监听：\(offenders.joined(separator: " | "))")
    }

    /// 控制接口的设置项标题不只出现在 `title:` 字面量里：`text("key", "标题", …)`
    /// 这类帮助函数把标题作为位置参数传进去。通用扫描抓不到，单独补一条，
    /// 免得 `flashcat config list` 在英文界面里露出中文。
    func testControlConfigTitlesAreLocalized() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "Sources/FlashCat/ControlServer+Documents.swift"), encoding: .utf8)
        let english = try XCTUnwrap(Bundle(path: try XCTUnwrap(
            L10n.bundle.path(forResource: "en", ofType: "lproj"))))
        let patterns = [
            #"\b(?:bool|int|double|text)\(\s*"[^"]+"\s*,\s*"([^"]+)""#,
            #"title:\s*"([^"]+)""#,
        ]
        let cjk = CharacterSet(charactersIn: "\u{4e00}"..."\u{9fff}")
        var missing: [String] = []
        for pattern in patterns {
            let expression = try NSRegularExpression(pattern: pattern)
            let range = NSRange(source.startIndex..., in: source)
            for match in expression.matches(in: source, range: range) {
                guard let group = Range(match.range(at: 1), in: source) else { continue }
                let key = String(source[group])
                guard key.rangeOfCharacter(from: cjk) != nil else { continue }
                if english.localizedString(forKey: key, value: nil, table: nil) == key {
                    missing.append(key)
                }
            }
        }
        XCTAssertTrue(missing.isEmpty, "控制接口设置标题缺少英文：\(missing.joined(separator: " | "))")
    }

    func testCLISettingsCopyIsLocalized() throws {
        let path = try XCTUnwrap(L10n.bundle.path(forResource: "en", ofType: "lproj"))
        let english = try XCTUnwrap(Bundle(path: path))
        XCTAssertEqual(english.localizedString(forKey: "命令行接口", value: nil, table: nil),
                       "Command-line Interface")
        XCTAssertEqual(english.localizedString(forKey: "控制端口", value: nil, table: nil),
                       "Control Port")
        XCTAssertEqual(english.localizedString(forKey: "点击一行运行命令", value: nil, table: nil),
                       "Click a row to run the command")
        XCTAssertEqual(english.localizedString(forKey: "显示 / 隐藏玻璃导航列", value: nil, table: nil),
                       "Show / hide the glass navigation column")
    }

    /// 每个中文词条都得有英文译文：漏一条，英文界面就会露出中文源文案。
    ///
    /// 读仓库里的 String Catalog 源文件而不是构建产物——`xcodebuild` 会把目录编译成
    /// 两份 `.lproj/Localizable.strings`，原始 `.xcstrings` 不进 bundle，测试跑在
    /// SwiftPM 的构建目录里，只能沿着 `#filePath` 回到源码树。
    func testEverySourceKeyHasAnEnglishTranslation() throws {
        let repoRoot = try XCTUnwrap(
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()   // Tests/FlashCatTests/
                .deletingLastPathComponent()   // Tests/
                .deletingLastPathComponent()   // native/
                .deletingLastPathComponent()   // repo root
        )
        let catalog = repoRoot
            .appendingPathComponent("native/Sources/FlashCat/Resources/Localizable.xcstrings")
        let data = try Data(contentsOf: catalog)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(root["strings"] as? [String: Any])
        XCTAssertEqual(root["sourceLanguage"] as? String, "zh-Hans")

        let untranslated = strings.compactMap { key, entry -> String? in
            let localizations = (entry as? [String: Any])?["localizations"] as? [String: Any]
            let unit = ((localizations?["en"] as? [String: Any])?["stringUnit"] as? [String: Any])
            let value = unit?["value"] as? String
            guard value == nil || value!.isEmpty else { return nil }
            return key
        }
        XCTAssertTrue(untranslated.isEmpty,
                      "词条缺少英文译文：\(untranslated.prefix(10).joined(separator: ", "))")
    }

    /// 界面文案的两条契约，都由 `L10n.bundle` 的实际查找结果判定，不依赖源码树路径：
    /// 1. 中文（源语言）下每条文案回显自身——英文漏译时 `zh-Hans` 是兜底；
    /// 2. 英文下必须翻成另一种写法，不能原样露出中文。
    ///
    /// 站点集合从源码里扫（`title:` / `detail:` / `subtitle:` / `L10n.t(...)` 的
    /// 中文字面量），因此新加一行界面文案就会自动进这条检查。
    func testUICopyResolvesInBothLanguages() throws {
        let sites = try localizedCopyLiterals()
        XCTAssertGreaterThan(sites.count, 100, "扫描到的文案站点过少，可能正则失效")

        let english = try XCTUnwrap(Bundle(path: try XCTUnwrap(
            L10n.bundle.path(forResource: "en", ofType: "lproj"))))
        let chinese = try XCTUnwrap(Bundle(path: try XCTUnwrap(
            L10n.bundle.path(forResource: "zh-Hans", ofType: "lproj"))))

        var notEnglishTranslated: [String] = []
        var notEchoedInChinese: [String] = []
        for key in sites {
            // 源码里的插值标题（带 `\(...)`）在展示前就是拼好的中文句子，
            // Catalog 里对应的是同样句子的 `%@` 形式，查找前先做这层映射。
            let lookupKey = key.replacingOccurrences(of: "\\(", with: "\u{0}")
                .split(separator: "\u{0}", omittingEmptySubsequences: false)
                .enumerated()
                .map { index, part in index == 0 ? String(part) : "%@\(part)" }
                .joined()
                .replacingOccurrences(of: "\u{0}", with: "")
            let en = english.localizedString(forKey: lookupKey, value: nil, table: nil)
            if en == lookupKey && lookupKey.rangeOfCharacter(from: CharacterSet(charactersIn: "一-鿿")) != nil {
                notEnglishTranslated.append(lookupKey)
            }
            let zh = chinese.localizedString(forKey: lookupKey, value: nil, table: nil)
            if zh != lookupKey { notEchoedInChinese.append(lookupKey) }
        }

        XCTAssertTrue(notEnglishTranslated.isEmpty,
                      "英文界面会露出中文（缺译文）：\(notEnglishTranslated.sorted().prefix(15).joined(separator: " | "))")
        XCTAssertTrue(notEchoedInChinese.isEmpty,
                      "中文界面被改写（源文案必须是 key）：\(notEchoedInChinese.sorted().prefix(15).joined(separator: " | "))")
    }

    // MARK: Helpers

    /// 扫 `FlashCat` 壳的源码，收集真正走 `L10n` 的中文字面量。
    /// 刻意不扫 `FlashCatKit`：那里的 `EngineDescriptor` / `EnginePackBuilder`
    /// 把中文写进 shell 脚本与构建步骤，那些是脚本正文，不是界面文案
    /// （构建步骤在展示处过 `L10n.t`，由上面第二条契约覆盖）。
    private func localizedCopyLiterals() throws -> Set<String> {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/FlashCatTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // native/
            .appendingPathComponent("Sources/FlashCat")

        let labelled = try NSRegularExpression(
            pattern: #"(?:title|detail|subtitle):\s*"((?:[^"\\]|\\.)+)""#)
        let lookup = try NSRegularExpression(
            pattern: #"L10n\.(?:t|format)\(\s*"((?:[^"\\]|\\.)+)""#)
        // `L10n.format` 的 key 必须是 Catalog 词条；`String(format:)` 直接吃源码里的
        // 裸格式串（如 `%.1f GB · 上限 %lld`）不算文案，不在这条契约范围内。
        let formatKeys = try NSRegularExpression(
            pattern: #"String\(format:\s*"((?:[^"\\]|\\.)+)""#)
        let cjk = CharacterSet(charactersIn: "\u{4e00}"..."\u{9fff}")

        var out = Set<String>()
        let enumerator = FileManager.default.enumerator(at: root,
                                                        includingPropertiesForKeys: nil,
                                                        options: [.skipsHiddenFiles])
        let files: [URL] = try XCTUnwrap(enumerator).compactMap { item in
            guard let url = item as? URL, url.pathExtension == "swift" else { return nil }
            return url
        }
        XCTAssertGreaterThan(files.count, 30, "源码目录扫描异常")

        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(source.startIndex..., in: source)
            // 裸格式串先剔除：它们不经过 Catalog，源码里出现的中文字面量也不算文案站点。
            let rawKeys = Set(formatKeys.matches(in: source, range: range).compactMap { match -> String? in
                guard let r = Range(match.range(at: 1), in: source) else { return nil }
                return String(source[r])
            })
            for regex in [labelled, lookup] {
                for match in regex.matches(in: source, range: range) {
                    guard let group = Range(match.range(at: 1), in: source) else { continue }
                    let raw = String(source[group])
                    if rawKeys.contains(raw) { continue }
                    let unescaped = raw.replacingOccurrences(of: "\\\"", with: "\"")
                        .replacingOccurrences(of: "\\\\", with: "\\")
                    // 只收含中文的文案：纯 ASCII 的键（图标名、端口号）不参与这条契约。
                    if unescaped.rangeOfCharacter(from: cjk) == nil { continue }
                    out.insert(unescaped)
                }
            }
        }
        return out
    }
}
