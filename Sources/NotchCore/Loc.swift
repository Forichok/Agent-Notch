import Foundation

/// UI language: English by default, Russian when the system's first preferred language is Russian.
/// No .lproj bundles: the app is built with plain swiftc, so each text enum keeps both strings side by side.
public enum Loc {
    public enum Language: String, Sendable { case en, ru }

    /// Set by checks and `--snapshot` runs; nil follows `AGENT_NOTCH_LANG`, then the system.
    nonisolated(unsafe) public static var forced: Language?

    public static let system: Language = {
        if let env = ProcessInfo.processInfo.environment["AGENT_NOTCH_LANG"], let lang = Language(rawValue: env.lowercased()) {
            return lang
        }
        return detect(Locale.preferredLanguages)
    }()

    public static func detect(_ preferred: [String]) -> Language {
        preferred.first.map { $0.lowercased().hasPrefix("ru") } == true ? .ru : .en
    }

    public static var language: Language { forced ?? system }
    public static var isRussian: Bool { language == .ru }

    /// The string for the current language.
    public static func t(_ en: String, _ ru: String) -> String { isRussian ? ru : en }
}
