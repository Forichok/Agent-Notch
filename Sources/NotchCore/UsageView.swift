import Foundation

public enum UsageTone: Sendable { case grey, amber, red }

/// Shared thresholds keep the summary and card consistent.
public enum UsageView {
    public static func limitTone(_ percent: Double, warningPercent: Double = 80) -> UsageTone {
        let warning = warningPercent.isFinite ? min(100, max(1, warningPercent)) : 80
        return percent >= min(95, warning + 15) ? .red : percent >= warning ? .amber : .grey
    }
    public static func selectWindows(_ limits: VendorLimits, short: Bool, weekly: Bool) -> VendorLimits {
        var result = limits
        result.windows = limits.windows.filter {
            ($0.label == LimitLabels.label(300) && short) || ($0.label == LimitLabels.label(10080) && weekly)
        }
        return result
    }
    public static func contextTone(_ percent: Double) -> UsageTone {
        percent >= 90 ? .red : percent >= 70 ? .amber : .grey
    }
    public static func tightest(_ limits: VendorLimits) -> Double? {
        limits.windows.map(\.usedPercent).filter(\.isFinite).max()
    }
    public static func fraction(_ percent: Double) -> Double {
        percent.isFinite ? min(1, max(0, percent / 100)) : 0
    }
}

public enum UsageViewText {
    public static var stale: String { Loc.t("no fresh data", "нет свежих данных") }
    public static func vendor(_ vendor: Vendor) -> String { vendor == .claude ? "Claude" : "Codex" }
    public static func percent(_ value: Double) -> String {
        value.isFinite ? String(format: "%.0f%%", value) : "—"
    }
    public static func chip(_ limits: VendorLimits) -> String {
        "\(vendor(limits.vendor)) \(UsageView.tightest(limits).map(percent) ?? "—")"
    }
    public static func context(_ usage: ContextUsage) -> String {
        let window = usage.windowTokens
        let size = window >= 1_000_000 && window % 1_000_000 == 0 ? "\(window / 1_000_000)M" :
            window >= 1000 && window % 1000 == 0 ? "\(window / 1000)K" : "\(window)"
        return Loc.t("context \(percent(usage.percent)) of \(size)", "контекст \(percent(usage.percent)) из \(size)")
    }
    public static func reset(_ date: Date?, now: Date) -> String {
        let unknown = Loc.t("reset time unknown", "время сброса неизвестно")
        guard let date else { return unknown }
        let seconds = date.timeIntervalSince(now)
        guard seconds.isFinite else { return unknown }
        if seconds <= 0 { return Loc.t("resets now", "сброс сейчас") }
        let d = Loc.t("d", "д"), h = Loc.t("h", "ч"), mins = Loc.t("min", "мин")
        let minutes = ceil(seconds / 60)
        let duration: String
        if minutes >= 1440 { duration = String(format: "%.0f ", floor(minutes / 1440)) + d }
        else if minutes >= 60 {
            let hours = floor(minutes / 60), remainder = minutes.truncatingRemainder(dividingBy: 60)
            duration = String(format: "%.0f ", hours) + h + (remainder > 0 ? String(format: " %.0f ", remainder) + mins : "")
        } else { duration = String(format: "%.0f ", minutes) + mins }
        return Loc.t("resets in ", "сброс через ") + duration
    }
    public static func window(_ window: LimitWindow, now: Date) -> String {
        "\(window.label): \(percent(window.usedPercent)) · \(reset(window.resetsAt, now: now))"
    }
}
