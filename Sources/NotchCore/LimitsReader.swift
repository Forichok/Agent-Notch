import Foundation

public struct LimitWindow: Equatable, Sendable {
    public var label: String
    public var usedPercent: Double
    public var resetsAt: Date?
    public init(label: String, usedPercent: Double, resetsAt: Date? = nil) {
        self.label = label; self.usedPercent = usedPercent; self.resetsAt = resetsAt
    }
}

public struct VendorLimits: Equatable, Sendable {
    public var vendor: Vendor
    public var windows: [LimitWindow]
    public var plan: String?
    public var updatedAt: Date
    public init(vendor: Vendor, windows: [LimitWindow], plan: String? = nil, updatedAt: Date) {
        self.vendor = vendor; self.windows = windows; self.plan = plan; self.updatedAt = updatedAt
    }
}

public enum LimitsReader {
    private static let lock = NSLock()
    private struct Snapshot {
        var limits: VendorLimits
        var minutes: [Int]
    }
    private static let snapshots = FileReadCache<[Snapshot]>()

    static var codexReadCount: Int {
        lock.lock(); defer { lock.unlock() }
        return snapshots.readCount
    }

    /// Accept an inventory from the spend poll so both readers share the directory walk.
    public static func read(home: URL, now: Date, codexFiles: [URL]? = nil) -> [VendorLimits] {
        lock.lock(); defer { lock.unlock() }
        var result = ClaudeLimits.read(home: home, now: now).map { [$0] } ?? []
        var newest: VendorLimits?
        let files = (codexFiles ?? UsageLog.files(home: home, vendor: .codex)).map { ($0, UsageLog.modified($0)) }
            .sorted { $0.1 > $1.1 }
        snapshots.retain(paths: Set(files.map { $0.0.path }))
        for (file, modified) in files.prefix(32) {
            // A log modified before the chosen snapshot cannot contain a newer sample.
            if let newest, !newest.windows.isEmpty, modified <= newest.updatedAt { break }
            let candidates = snapshots.read(path: file.path) { snapshot(file: file, modified: modified, now: now) }
            guard let sample = candidates.first(where: { $0.limits.updatedAt <= now }) else { continue }
            let raw = sample.limits
            var current = raw
            current.windows = zip(raw.windows, sample.minutes).compactMap { window, minutes in
                var window = window
                if let reset = window.resetsAt, reset <= now { window.usedPercent = 0 }
                else if window.resetsAt == nil && now.timeIntervalSince(raw.updatedAt) >= Double(minutes) * 60 { return nil }
                return window
            }
            if newest.map({ current.updatedAt > $0.updatedAt }) ?? true { newest = current }
        }
        if let newest { result.append(newest) }
        return result
    }

    private static func snapshot(file: URL, modified: Date, now: Date) -> [Snapshot] {
        var result: [Snapshot] = []
        for record in UsageLog.tail(file.path).reversed() {
            guard record["type"] as? String == "event_msg", let payload = record["payload"] as? Rec,
                  payload["type"] as? String == "token_count", let limits = payload["rate_limits"] as? Rec else { continue }
            let values = ["primary", "secondary"].compactMap { key -> (LimitWindow, Int)? in
                guard let w = limits[key] as? Rec, let percent = w["used_percent"] as? Double,
                      percent.isFinite, percent >= 0 else { return nil }
                let minutes = UsageLog.count(w["window_minutes"])
                guard minutes > 0 else { return nil }
                let reset = (w["resets_at"] as? Double).flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0) : nil }
                return (LimitWindow(label: LimitLabels.label(minutes), usedPercent: percent, resetsAt: reset), minutes)
            }
            guard !values.isEmpty else { continue }
            let updated = LogText.time(record["timestamp"]).map { Date(timeIntervalSince1970: $0) } ?? modified
            let vendorLimits = VendorLimits(vendor: .codex, windows: values.map { $0.0 },
                                      plan: limits["plan_type"] as? String, updatedAt: updated)
            result.append(Snapshot(limits: vendorLimits, minutes: values.map { $0.1 }))
            // Preserve future samples so they can become valid without another read.
            if updated <= now { break }
        }
        return result
    }
}

enum LimitLabels {
    static func label(_ minutes: Int) -> String {
        switch minutes {
        case 300: return Loc.t("5 h", "5 ч")
        case 10080: return Loc.t("week", "неделя")
        default: return minutes % 60 == 0 ? "\(minutes / 60) " + Loc.t("h", "ч") : "\(minutes) " + Loc.t("min", "мин")
        }
    }
}
