import Foundation

struct UsageFixChecks {
    let u = UsageChecks()
    func expiredLimits() throws {
        let h = u.home(); defer { try? FileManager.default.removeItem(at: h) }
        let file = h.appendingPathComponent(".codex/sessions/a.jsonl")
        let window: Rec = ["used_percent": 99, "window_minutes": 300, "resets_at": u.now.timeIntervalSince1970 - 1]
        let payload: Rec = ["type": "token_count", "rate_limits": ["primary": window]]
        let record: Rec = ["type": "event_msg", "timestamp": u.stamp(u.now), "payload": payload]
        try u.write(file, [record])
        XCTAssertEqual(LimitsReader.read(home: h, now: u.now).first?.windows.first?.usedPercent, 0)
        let history = h.appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json")
        try FileManager.default.createDirectory(at: history.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sample: Rec = ["t": u.now.addingTimeInterval(-18001).timeIntervalSince1970 * 1000,
                           "u": ["fh": 90, "sd": 30]]
        let data: Rec = ["version": 2, "samples": [sample]]
        try JSONSerialization.data(withJSONObject: data).write(to: history)
        XCTAssertEqual(LimitsReader.read(home: h, now: u.now).first?.windows.map(\.label), ["неделя"])
        XCTAssertEqual(LimitsReader.read(home: h, now: u.now.addingTimeInterval(7 * 86400)).first?.windows.count, 0)
    }
    /// The history keeps no reset times: the weekly reset is found from earlier drops to near zero, so yesterday's figure
    /// does not outlive the reset that zeroed it.
    func claudeWeeklyReset() throws {
        let h = u.home(); defer { try? FileManager.default.removeItem(at: h) }
        let history = h.appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json")
        try FileManager.default.createDirectory(at: history.deletingLastPathComponent(), withIntermediateDirectories: true)
        let week = 7 * 86400.0, reset = u.now.addingTimeInterval(-3600) // the latest reset, an hour ago
        func at(_ d: Date, _ sd: Double) -> Rec { ["t": d.timeIntervalSince1970 * 1000, "u": ["fh": 0, "sd": sd]] }
        let samples: [Rec] = [
            at(reset.addingTimeInterval(-2 * week - 900), 27), at(reset.addingTimeInterval(-2 * week + 30), 0),   // a quarter hour around it
            at(reset.addingTimeInterval(-week - 20000), 29), at(reset.addingTimeInterval(-week + 40000), 3),      // a wide gap that agrees
            at(reset.addingTimeInterval(-week + 90000), 70), at(reset.addingTimeInterval(-week + 300000), 47),    // a fall that is not a reset
            at(reset.addingTimeInterval(-12 * 3600), 52)]                                                       // yesterday, before the reset
        try JSONSerialization.data(withJSONObject: ["version": 2, "samples": samples] as Rec).write(to: history)
        let after = try XCTUnwrap(LimitsReader.read(home: h, now: u.now).first?.windows.first { $0.label == "неделя" })
        XCTAssertEqual(after.usedPercent, 0)
        XCTAssertEqual(after.resetsAt.map { Int($0.timeIntervalSince(reset)) }, Int(week))
        let before = try XCTUnwrap(LimitsReader.read(home: h, now: reset.addingTimeInterval(-600)).first?.windows.first { $0.label == "неделя" })
        XCTAssertEqual(before.usedPercent, 52)
        XCTAssertEqual(before.resetsAt.map { Int($0.timeIntervalSince(reset)) }, 0)
    }
    func outputDoesNotExpandWindow() throws {
        let h = u.home(); defer { try? FileManager.default.removeItem(at: h) }
        let file = h.appendingPathComponent("c.jsonl")
        var rec = u.claude("near-limit")
        var msg = rec["message"] as? Rec ?? [:]
        msg["usage"] = ["input_tokens": 10000, "cache_read_input_tokens": 185000, "output_tokens": 10000]
        rec["message"] = msg
        try u.write(file, [rec])
        XCTAssertEqual(ContextFill.read(path: file.path, vendor: .claude)?.windowTokens, 200000)
    }
    func configuredThresholds() {
        XCTAssertEqual(UsageView.limitTone(59, warningPercent: 60), .grey)
        XCTAssertEqual(UsageView.limitTone(60, warningPercent: 60), .amber)
        XCTAssertEqual(UsageView.limitTone(75, warningPercent: 60), .red)
        XCTAssertEqual(UsageView.limitTone(94, warningPercent: 99), .grey)
        XCTAssertEqual(UsageView.limitTone(95, warningPercent: 99), .red)
    }
    func fileCache() throws {
        let h = u.home(); defer { try? FileManager.default.removeItem(at: h) }
        let file = h.appendingPathComponent("c.jsonl")
        try u.write(file, [u.claude("a")])
        let cache = FileReadCache<Int>()
        var reads = 0
        func load() -> Int { reads += 1; return reads }
        XCTAssertEqual(cache.read(path: file.path, load: load), 1)
        XCTAssertEqual(cache.read(path: file.path, load: load), 1)
        try u.write(file, [u.claude("b")], append: true)
        XCTAssertEqual(cache.read(path: file.path, load: load), 2)
        try FileManager.default.setAttributes([.modificationDate: u.now.addingTimeInterval(1)], ofItemAtPath: file.path)
        XCTAssertEqual(cache.read(path: file.path, load: load), 3)
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(cache.read(path: file.path, load: load), 4)
        XCTAssertEqual(reads, 4)
        XCTAssertEqual(UsagePolling.interval(listOpen: true), 60)
        XCTAssertEqual(UsagePolling.interval(listOpen: false), 300)
    }
    func worktreeCache() throws {
        let h = u.home(); defer { try? FileManager.default.removeItem(at: h) }
        let git = h.appendingPathComponent("branch/.git")
        try FileManager.default.createDirectory(at: git.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "gitdir: /repo/.git/worktrees/branch".write(to: git, atomically: true, encoding: .utf8)
        let cwd = git.deletingLastPathComponent().path
        XCTAssertEqual(SessionLog.worktreeName(cwd: cwd, now: u.now), "branch")
        try FileManager.default.removeItem(at: git)
        XCTAssertEqual(SessionLog.worktreeName(cwd: cwd, now: u.now.addingTimeInterval(59)), "branch")
        XCTAssertNil(SessionLog.worktreeName(cwd: cwd, now: u.now.addingTimeInterval(60)))
        try "gitdir: /repo/.git/worktrees/branch".write(to: git, atomically: true, encoding: .utf8)
        XCTAssertNil(SessionLog.worktreeName(cwd: cwd, now: u.now.addingTimeInterval(61)))
        XCTAssertEqual(SessionLog.worktreeName(cwd: cwd, now: u.now.addingTimeInterval(120)), "branch")
    }

    func windowSelection() {
        let limits = VendorLimits(vendor: .claude, windows: [LimitWindow(label: "5 ч", usedPercent: 90),
            LimitWindow(label: "неделя", usedPercent: 30)], updatedAt: u.now)
        XCTAssertEqual(UsageView.selectWindows(limits, short: false, weekly: true).windows.map(\.usedPercent), [30])
        XCTAssertEqual(UsageView.selectWindows(limits, short: true, weekly: false).windows.map(\.usedPercent), [90])
        XCTAssertTrue(UsageView.selectWindows(limits, short: false, weekly: false).windows.isEmpty)
        XCTAssertFalse(LimitChipMode.nearLimit.isVisible(usedPercent: 59, threshold: 60))
        XCTAssertTrue(LimitChipMode.nearLimit.isVisible(usedPercent: 60, threshold: 60))
        XCTAssertTrue(UsagePolling.isDue(last: u.now, now: u.now.addingTimeInterval(60), listOpen: true))
        XCTAssertFalse(UsagePolling.isDue(last: u.now, now: u.now.addingTimeInterval(299), listOpen: false))
        XCTAssertTrue(UsagePolling.isDue(last: u.now, now: u.now.addingTimeInterval(300), listOpen: false))
    }

    func limitsCacheAndEarlyStop() throws {
        let h = u.home(); defer { try? FileManager.default.removeItem(at: h) }
        let newest = h.appendingPathComponent(".codex/sessions/new.jsonl")
        let older = h.appendingPathComponent(".codex/sessions/old.jsonl")
        let window: Rec = ["used_percent": 90, "window_minutes": 300,
                           "resets_at": u.now.timeIntervalSince1970 + 10]
        let payload: Rec = ["type": "token_count", "rate_limits": ["primary": window]]
        let record: Rec = ["type": "event_msg", "timestamp": u.stamp(u.now), "payload": payload]
        try u.write(newest, [record]); try u.write(older, [u.codex(100)])
        try FileManager.default.setAttributes([.modificationDate: u.now.addingTimeInterval(-1)], ofItemAtPath: older.path)
        let before = LimitsReader.codexReadCount
        XCTAssertEqual(LimitsReader.read(home: h, now: u.now).first?.windows.first?.usedPercent, 90)
        XCTAssertEqual(LimitsReader.codexReadCount - before, 1)
        XCTAssertEqual(LimitsReader.read(home: h, now: u.now.addingTimeInterval(11)).first?.windows.first?.usedPercent, 0)
        XCTAssertEqual(LimitsReader.codexReadCount - before, 1, "cached snapshot must still age without another tail read")
    }

    func codexFutureAndDuration() throws {
        let h = u.home(); defer { try? FileManager.default.removeItem(at: h) }
        let file = h.appendingPathComponent(".codex/sessions/a.jsonl")
        let window: Rec = ["used_percent": 90, "window_minutes": 60]
        let payload: Rec = ["type": "token_count", "rate_limits": ["primary": window]]
        let valid: Rec = ["type": "event_msg", "timestamp": u.stamp(u.now), "payload": payload]
        var future = valid; future["timestamp"] = u.stamp(u.now.addingTimeInterval(60))
        try u.write(file, [valid, future])
        XCTAssertEqual(LimitsReader.read(home: h, now: u.now).first?.updatedAt, u.now)
        try u.write(file, [valid])
        XCTAssertEqual(LimitsReader.read(home: h, now: u.now.addingTimeInterval(3600)).first?.windows.count, 0)
    }

}
