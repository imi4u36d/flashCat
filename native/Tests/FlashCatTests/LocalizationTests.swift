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
        XCTAssertEqual(english.localizedString(forKey: "下载 %lld%%", value: nil, table: nil), "Download %lld%%")
    }

    func testChineseCatalogFallsBackToSourceStrings() throws {
        let path = try XCTUnwrap(L10n.bundle.path(forResource: "zh-Hans", ofType: "lproj"))
        let chinese = try XCTUnwrap(Bundle(path: path))

        XCTAssertEqual(chinese.localizedString(forKey: "概览", value: nil, table: nil), "概览")
        XCTAssertEqual(chinese.localizedString(forKey: "%@ · 端口 %@", value: nil, table: nil), "%@ · 端口 %@")
    }
}
