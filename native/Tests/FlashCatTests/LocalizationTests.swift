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

    /// 快捷键文案是「代码里的 keyboardShortcut」与「界面提示」两处的唯一契约。
    /// 改了 `App.swift` 的按键就要在这里同步，否则提示会指向一个不存在的手势。
    func testKeyboardShortcutCopyMatchesTheMenu() throws {
        let path = try XCTUnwrap(L10n.bundle.path(forResource: "en", ofType: "lproj"))
        let english = try XCTUnwrap(Bundle(path: path))

        // 先确认这些词条在**源码** Catalog 里：构建产物可能带着上一次编译的
        // 旧词条，只查 bundle 会让「删了词条」这种回归在本地误判为通过。
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf:
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("native/Sources/FlashCat/Resources/Localizable.xcstrings")
        )) as? [String: Any])
        let entries = try XCTUnwrap(catalog["strings"] as? [String: Any])

        // ⌘\ 折叠边栏、⌘⇧A 切外观——两处都带着按键本身。
        XCTAssertEqual(english.localizedString(forKey: "隐藏边栏（⌘\\）", value: nil, table: nil),
                       "Hide Sidebar (⌘\\)")
        XCTAssertEqual(english.localizedString(forKey: "显示边栏（⌘\\）", value: nil, table: nil),
                       "Show Sidebar (⌘\\)")
        XCTAssertEqual(english.localizedString(forKey: "切换浅色 / 深色", value: nil, table: nil),
                       "Toggle Light / Dark")
        // 命令面板里的动作说明也带着按键。
        XCTAssertEqual(english.localizedString(forKey: "显示 / 隐藏玻璃导航列（⌘\\）", value: nil, table: nil),
                       "Show / hide the glass navigation column (⌘\\)")
        XCTAssertEqual(english.localizedString(forKey: "当前：%@", value: nil, table: nil),
                       "Current: %@")

        for key in ["隐藏边栏（⌘\\）", "显示边栏（⌘\\）", "切换浅色 / 深色",
                    "显示 / 隐藏玻璃导航列（⌘\\）", "当前：%@"] {
            XCTAssertNotNil(entries[key], "快捷键文案缺少词条：\(key)")
        }
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
