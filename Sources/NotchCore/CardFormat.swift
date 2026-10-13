import Foundation

public enum CardFormat {
    public static func duration(startedAt: Double?, now: Double) -> String? {
        guard let startedAt, startedAt.isFinite, now.isFinite else { return nil }
        let elapsed = max(0, now - startedAt)
        guard elapsed.isFinite, elapsed < Double(Int.max) else { return nil }
        let seconds = Int(elapsed)
        if seconds < 60 { return "\(seconds) \(CardFormatText.seconds)" }
        if seconds < 3600 { return "\(seconds / 60) \(CardFormatText.minutes)" }
        return "\(seconds / 3600) \(CardFormatText.hours) \(seconds % 3600 / 60) \(CardFormatText.minutes)"
    }

    /// Run time for the card: a live agent counts to now, a finished one stops at its last activity.
    /// Over two days is a start time from somewhere else, so nothing is shown (same guard as the list rows).
    public static func runTime(startedAt: Double?, lastAt: Double?, live: Bool, now: Double) -> String? {
        guard let startedAt, let end = live ? now : lastAt, end - startedAt < 2 * 86_400 else { return nil }
        return duration(startedAt: startedAt, now: end)
    }

    public static func path(_ path: String, cwd: String?, home: String) -> String {
        if let cwd, !cwd.isEmpty, let relative = relative(path, to: cwd) { return relative.isEmpty ? "." : relative }
        if !home.isEmpty, let relative = relative(path, to: home) { return relative.isEmpty ? "~" : "~/" + relative }
        return path
    }

    private static func relative(_ path: String, to base: String) -> String? {
        let root = base == "/" ? base : base.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        if path == root { return "" }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }
}

private enum CardFormatText {
    static var seconds: String { Loc.t("s", "с") }
    static var minutes: String { Loc.t("min", "мин") }
    static var hours: String { Loc.t("h", "ч") }
}

extension CardFormat {
    /// "≈ $0.42"; nothing when a price is unknown, so an unknown model never reads as free.
    public static func cost(_ cost: SessionCost?) -> String? {
        guard let usd = cost?.usd, usd.isFinite else { return nil }
        return usd < 0.01 ? "< $0.01" : String(format: "≈ $%.2f", usd)
    }
}
