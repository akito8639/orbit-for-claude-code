import Foundation

enum L10n {
    /// When true, lookups return the English source string and dates use en_US.
    /// Set by the widget extension from the "Widgets always in English" setting.
    nonisolated(unsafe) static var forceEnglish = false

    static var locale: Locale { forceEnglish ? Locale(identifier: "en_US") : .current }
}

/// Localized string lookup. Keys are the English source strings in Shared/Localizable.xcstrings,
/// which is compiled into both the app and the widget extension.
@inline(__always) func L(_ key: String) -> String {
    L10n.forceEnglish ? key : NSLocalizedString(key, comment: "")
}

func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), locale: L10n.locale, arguments: args)
}
