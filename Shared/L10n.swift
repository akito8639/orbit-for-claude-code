import Foundation

/// Localized string lookup. Keys are the English source strings in Shared/Localizable.xcstrings,
/// which is compiled into both the app and the widget extension.
@inline(__always) func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: NSLocalizedString(key, comment: ""), locale: Locale.current, arguments: args)
}
