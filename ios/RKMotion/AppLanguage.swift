import SwiftUI

/// Which way the app's screens read: right to left in Hebrew, left to right
/// in English, following the language iOS chose for the app. Charts and
/// timelines stay left to right in both, as time does.
enum AppLanguage {
    static func direction(for language: String?) -> LayoutDirection {
        guard let language else {return .leftToRight}
        return Locale.Language(identifier: language).characterDirection == .rightToLeft ? .rightToLeft : .leftToRight
    }
    static var direction: LayoutDirection {direction(for: Bundle.main.preferredLocalizations.first)}
}
