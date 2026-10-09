import Foundation

@MainActor
enum BreweryLocalization {
    static func string(_ key: String) -> String {
        let language = AppPreferences.shared.values.language
        let selected = language == "system" ? (AppPreferences.isTesting ? "en" : Locale.preferredLanguages.first ?? "en") : language
        let code = selected.hasPrefix("ko") ? "ko" : "en"
        let bundle = Bundle.main.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }
    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(key), arguments: arguments)
    }
}
