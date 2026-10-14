import Foundation
#if canImport(NotchCore)
import NotchCore
#endif

struct PromptVaultChecks {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let plan = PromptSnippet(title: "Plan first", text: "Lay out a plan and wait for my OK.", created: Date(timeIntervalSince1970: 1_700_000_000))
    let review = PromptSnippet(title: "Review", text: "Review the diff, list bugs with a plan to fix.", created: Date(timeIntervalSince1970: 1_700_000_000))
    let brief = PromptSnippet(title: "", text: "Be brief\nno preamble", created: Date(timeIntervalSince1970: 1_700_000_000))

    func vault() -> PromptVault { PromptVault(snippets: [plan, review, brief]) }
    func days(_ n: Double) -> Date { now.addingTimeInterval(-n * 86_400) }

    func ranking() {
        var v = vault()
        XCTAssertEqual(v.ranked(now: now).map(\.id), [plan.id, review.id, brief.id], "unused keep the user's order")
        v.record(brief.id, at: days(0))
        v.record(review.id, at: days(60))
        v.record(review.id, at: days(61))
        v.record(review.id, at: days(62))
        // Three uses two months ago weigh less than one today.
        XCTAssertEqual(v.ranked(now: now).map(\.id), [brief.id, review.id, plan.id])
        // A title hit beats a text-only hit, whatever the usage.
        XCTAssertEqual(v.ranked(query: "plan", now: now).map(\.id), [plan.id, review.id])
        XCTAssertEqual(v.ranked(query: "REVIEW bugs", now: now).map(\.id), [review.id])
        XCTAssertEqual(v.ranked(query: "nothing here", now: now).count, 0)
        XCTAssertEqual(brief.label, "Be brief")
    }

    func stats() {
        var v = vault()
        v.record(review.id, at: days(30))
        v.record(review.id, at: days(20))
        v.record(review.id, at: days(10))
        v.record(plan.id, at: days(1))
        v.record(plan.id, at: days(0.5))
        v.record(UUID(), at: days(0))
        let s = v.stats(now: now)
        XCTAssertEqual(s.map(\.snippet.id), [review.id, plan.id, brief.id])
        XCTAssertEqual(s.map(\.total), [3, 2, 0])
        XCTAssertEqual(s.map(\.week), [0, 2, 0])
        XCTAssertEqual(s[0].last, days(10))
        XCTAssertNil(s[2].last)
        XCTAssertEqual(v.uses.count, 5, "unknown ids are not recorded")
        XCTAssertEqual(v.uses(since: days(7)), 2)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(v.daily(days: 3, now: now, calendar: utc).reduce(0, +), 2)
        XCTAssertEqual(v.daily(days: 3, now: now, calendar: utc).count, 3)
        v.remove(plan.id)
        XCTAssertEqual(v.uses.count, 3)
        XCTAssertEqual(v.snippets.count, 2)
        v.resetStats()
        XCTAssertEqual(v.uses.count, 0)
    }

    func file() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("prompt-vault-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = PromptVaultFile(url: dir.appendingPathComponent("nested/prompts.json"))
        XCTAssertFalse(f.exists)
        XCTAssertNil(f.load())
        var v = vault()
        v.record(plan.id, at: Date(timeIntervalSince1970: 1_800_000_000))
        try f.save(v)
        XCTAssertEqual(try XCTUnwrap(f.load()), v)
        XCTAssertTrue(PromptVault.starter.snippets.allSatisfy { !$0.title.isEmpty && !$0.text.isEmpty })
    }
}
