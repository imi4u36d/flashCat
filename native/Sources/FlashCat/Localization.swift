import Foundation

/// Runtime localization for strings that are not literal keys in a SwiftUI view.
///
/// The app ships one String Catalog (`Resources/Localizable.xcstrings`) with
/// Simplified Chinese as the source language and English translations. Views
/// whose text comes from a variable look it up here so model names, URLs and
/// other user data simply fall back to themselves.
enum L10n {
    /// The SwiftPM resource bundle that carries the compiled String Catalog.
    /// It lives in the app's Resources folder, so this works both for the
    /// packaged app and for `swift run`.
    static let bundle: Bundle = .module

    /// Looks up a runtime key in the current app language.
    static func t(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }

    /// Looks up a format string and substitutes the given arguments.
    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: t(key), arguments: arguments)
    }
}
