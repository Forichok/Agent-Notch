import Foundation
#if canImport(NotchCore)
import NotchCore
#endif

struct LanguageChecks {
    func detect() {
        XCTAssertEqual(Loc.detect(["ru-RU", "en-US"]), .ru)
        XCTAssertEqual(Loc.detect(["en-US", "ru-RU"]), .en)
        XCTAssertEqual(Loc.detect(["de-DE"]), .en)
        XCTAssertEqual(Loc.detect([]), .en)
    }

    /// The same builders as the Russian checks, under English.
    func english() {
        let saved = Loc.forced
        Loc.forced = .en
        defer { Loc.forced = saved }
        let files = (0..<3).map { FileChange(path: "f\($0)", added: 1, removed: 0) }
        XCTAssertEqual(FinishSummary.line(AgentDetail(files: files, commands: [CommandRun(command: "./scripts/test.sh", ok: true)])),
                       "done · 3 files · tests ✓")
        XCTAssertEqual(FinishSummary.line(AgentDetail(files: [files[0]])), "done · 1 file")
        XCTAssertEqual(CardFormat.duration(startedAt: 100, now: 3760), "1 h 1 min")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(UsageViewText.reset(now.addingTimeInterval(9000), now: now), "resets in 2 h 30 min")
        XCTAssertEqual(UsageViewText.reset(nil, now: now), "reset time unknown")
        XCTAssertEqual(UsageViewText.context(ContextUsage(usedTokens: 630_000, windowTokens: 1_000_000)), "context 63% of 1M")
        XCTAssertEqual(LimitLabels.label(10080), "week")
        XCTAssertEqual(ProjectNames().name(for: nil), "no project")
    }
}
