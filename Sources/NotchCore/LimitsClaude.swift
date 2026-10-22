import Foundation

/// Desktop Claude persists utilization history, not reset times or plan names.
/// The installed app maps five_hour → fh and seven_day → sd, with epoch milliseconds in t.
enum ClaudeLimits {
    private static let historyCache = FileReadCache<Rec?>()
    static func read(home: URL, now: Date) -> VendorLimits? {
        let root = home.appendingPathComponent("Library/Application Support")
        let directories = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var newest: VendorLimits?
        for directory in directories where directory.lastPathComponent == "Claude" || directory.lastPathComponent.hasPrefix("Claude-") {
            let file = directory.appendingPathComponent("plan-usage-history.json")
            let history = historyCache.read(path: file.path) {
                guard let handle = FileHandle(forReadingAtPath: file.path) else { return nil }
                defer { try? handle.close() }
                guard let data = try? handle.read(upToCount: (1 << 20) + 1), data.count <= 1 << 20 else { return nil }
                return try? JSONSerialization.jsonObject(with: data) as? Rec
            }
            guard let history,
                  let version = history["version"] as? Int, [1, 2].contains(version),
                  let samples = history["samples"] as? [Rec] else { continue }
            let weekly = samples.compactMap { sample -> (Date, Double)? in
                guard let ms = sample["t"] as? Double, ms.isFinite, ms > 0,
                      let sd = (version == 2 ? sample["u"] as? Rec ?? [:] : sample)["sd"] as? Double, sd.isFinite else { return nil }
                return (Date(timeIntervalSince1970: ms / 1000), sd)
            }
            let reset = weeklyReset(weekly.filter { $0.0 <= now })
            for sample in samples {
                guard let milliseconds = sample["t"] as? Double, milliseconds.isFinite, milliseconds > 0 else { continue }
                let updated = Date(timeIntervalSince1970: milliseconds / 1000)
                guard updated <= now, newest.map({ updated > $0.updatedAt }) ?? true else { continue }
                let usage = version == 2 ? sample["u"] as? Rec ?? [:] : sample
                let windows = [("fh", 300), ("sd", 10080)].compactMap { key, minutes -> LimitWindow? in
                    guard now.timeIntervalSince(updated) < Double(minutes * 60),
                          let percent = usage[key] as? Double, percent.isFinite, percent >= 0 else { return nil }
                    // the weekly reset passed since this sample: the week starts over at 0
                    if key == "sd", let reset {
                        let next = nextReset(after: updated, phase: reset)
                        if next <= now { return LimitWindow(label: LimitLabels.label(minutes), usedPercent: 0, resetsAt: nextReset(after: now, phase: reset)) }
                        return LimitWindow(label: LimitLabels.label(minutes), usedPercent: percent, resetsAt: next)
                    }
                    return LimitWindow(label: LimitLabels.label(minutes), usedPercent: percent)
                }
                if ["fh", "sd"].contains(where: { usage[$0] as? Double != nil }) {
                    newest = VendorLimits(vendor: .claude, windows: windows, updatedAt: updated)
                }
            }
        }
        return newest
    }

    private static let week: TimeInterval = 7 * 86400

    /// The history keeps no reset times, so a weekly figure from yesterday outlives the reset that zeroed it.
    /// Where the weekly figure fell to near zero between two samples, the reset lies between them; the week repeats,
    /// so those gaps, folded onto one week, overlap at the reset. Returns that moment (seconds into the week, from the epoch)
    /// when at least two such drops agree to within six hours.
    static func weeklyReset(_ samples: [(Date, Double)]) -> TimeInterval? {
        let sorted = samples.sorted { $0.0 < $1.0 }
        let gaps = zip(sorted, sorted.dropFirst()).compactMap { a, b -> (TimeInterval, TimeInterval)? in
            guard b.1 <= 20, a.1 - b.1 >= 10 else { return nil }
            let from = a.0.timeIntervalSince1970, to = b.0.timeIntervalSince1970
            return to - from < week ? (from, to) : nil
        }
        guard gaps.count >= 2 else { return nil }
        let step: TimeInterval = 900
        let fits = stride(from: 0, to: week, by: step).filter { slot in
            gaps.allSatisfy { from, to in
                let k = ((to - slot) / week).rounded(.down)
                let moment = slot + k * week
                return moment > from && moment <= to
            }
        }
        guard !fits.isEmpty else { return nil }
        // the fitting slots form one run on the circle of the week: it ends before the widest gap between them
        var widest = 0, gap = -1.0
        for (n, slot) in fits.enumerated() {
            let next = n + 1 < fits.count ? fits[n + 1] : fits[0] + week
            if next - slot > gap { gap = next - slot; widest = n }
        }
        guard fits.count == 1 || week - gap <= 6 * 3600 else { return nil }
        return fits[widest] // the run's last slot: never earlier than the reset itself
    }

    static func nextReset(after date: Date, phase: TimeInterval) -> Date {
        let t = date.timeIntervalSince1970, k = ((t - phase) / week).rounded(.down) + 1
        return Date(timeIntervalSince1970: phase + k * week)
    }
}
