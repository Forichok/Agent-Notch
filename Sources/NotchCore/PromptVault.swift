import Foundation

/// A saved pre-prompt: the picker pastes `text` into whatever field has focus.
public struct PromptSnippet: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var text: String
    public var created: Date

    public init(id: UUID = UUID(), title: String, text: String, created: Date = Date()) {
        self.id = id
        self.title = title
        self.text = text
        self.created = created
    }

    /// The title, or the first line of the text when the title is empty.
    public var label: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        return text.split(whereSeparator: \.isNewline).first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
    }
}

/// One insertion: the stats are counted from these.
public struct PromptUse: Codable, Equatable, Sendable {
    public var id: UUID
    public var at: Date
    public init(id: UUID, at: Date) { self.id = id; self.at = at }
}

public struct PromptStat: Equatable, Sendable {
    public var snippet: PromptSnippet
    public var total: Int
    public var week: Int
    public var last: Date?
}

/// Everything the vault keeps on disk: the snippets in the user's order and the log of insertions.
public struct PromptVault: Codable, Equatable, Sendable {
    public var snippets: [PromptSnippet]
    public var uses: [PromptUse]

    /// The oldest insertions are dropped past this, so the file stays small after years of use.
    public static let maxUses = 20_000
    /// A use this many days old counts half as much in the picker's order.
    public static let halfLifeDays = 14.0

    public init(snippets: [PromptSnippet] = [], uses: [PromptUse] = []) {
        self.snippets = snippets
        self.uses = uses
    }

    public mutating func record(_ id: UUID, at date: Date = Date()) {
        guard snippets.contains(where: { $0.id == id }) else { return }
        uses.append(PromptUse(id: id, at: date))
        if uses.count > Self.maxUses { uses.removeFirst(uses.count - Self.maxUses) }
    }

    public mutating func remove(_ id: UUID) {
        snippets.removeAll { $0.id == id }
        uses.removeAll { $0.id == id }
    }

    public mutating func resetStats() { uses = [] }

    /// What the picker shows: matches for every word of the query, most used lately first.
    /// Without a query nothing is filtered; with one, a hit in the title beats a hit only in the text.
    public func ranked(query: String = "", now: Date = Date()) -> [PromptSnippet] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let score = frecency(now: now)
        let order = Dictionary(uniqueKeysWithValues: snippets.enumerated().map { ($1.id, $0) })
        func titleHits(_ s: PromptSnippet) -> Int {
            let title = s.label.lowercased()
            return words.filter { title.contains($0) }.count
        }
        let matched = words.isEmpty ? snippets : snippets.filter { s in
            let hay = (s.label + "\n" + s.text).lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
        return matched.sorted { a, b in
            let ta = titleHits(a), tb = titleHits(b)
            if ta != tb { return ta > tb }
            let fa = score[a.id] ?? 0, fb = score[b.id] ?? 0
            if fa != fb { return fa > fb }
            return (order[a.id] ?? 0) < (order[b.id] ?? 0)
        }
    }

    /// Each use weighs 1 today and halves every `halfLifeDays`: a prompt used daily this week beats one used a lot last year.
    public func frecency(now: Date = Date()) -> [UUID: Double] {
        var result: [UUID: Double] = [:]
        for use in uses {
            let days = max(0, now.timeIntervalSince(use.at) / 86_400)
            result[use.id, default: 0] += pow(0.5, days / Self.halfLifeDays)
        }
        return result
    }

    /// Per snippet, most inserted first; never-used snippets come last in the user's order.
    public func stats(now: Date = Date()) -> [PromptStat] {
        let weekAgo = now.addingTimeInterval(-7 * 86_400)
        var total: [UUID: Int] = [:], week: [UUID: Int] = [:], last: [UUID: Date] = [:]
        for use in uses {
            total[use.id, default: 0] += 1
            if use.at >= weekAgo { week[use.id, default: 0] += 1 }
            if last[use.id].map({ use.at > $0 }) ?? true { last[use.id] = use.at }
        }
        let order = Dictionary(uniqueKeysWithValues: snippets.enumerated().map { ($1.id, $0) })
        return snippets.map { PromptStat(snippet: $0, total: total[$0.id] ?? 0, week: week[$0.id] ?? 0, last: last[$0.id]) }
            .sorted { a, b in
                if a.total != b.total { return a.total > b.total }
                if a.week != b.week { return a.week > b.week }
                return (order[a.snippet.id] ?? 0) < (order[b.snippet.id] ?? 0)
            }
    }

    /// Insertions per calendar day, oldest first, the last entry being today.
    public func daily(days: Int, now: Date = Date(), calendar: Calendar = .current) -> [Int] {
        guard days > 0 else { return [] }
        let today = calendar.startOfDay(for: now)
        var counts = Array(repeating: 0, count: days)
        for use in uses {
            let day = calendar.startOfDay(for: use.at)
            guard let back = calendar.dateComponents([.day], from: day, to: today).day, back >= 0, back < days else { continue }
            counts[days - 1 - back] += 1
        }
        return counts
    }

    public func uses(since date: Date) -> Int { uses.filter { $0.at >= date }.count }
}

/// `~/Library/Application Support/AgentsNotch/prompts.json`, written atomically.
public struct PromptVaultFile: Sendable {
    public let url: URL

    public init(url: URL? = nil) {
        self.url = url ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AgentsNotch/prompts.json")
    }

    public var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    /// nil when there is no file yet or it cannot be read; the caller decides whether to seed.
    public func load() -> PromptVault? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PromptVault.self, from: data)
    }

    public func save(_ vault: PromptVault) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(vault)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

public extension PromptVault {
    /// What a first launch starts with, so the picker is never empty.
    static var starter: PromptVault {
        PromptVault(snippets: Loc.isRussian ? [
            PromptSnippet(title: "Сначала план", text: "Прежде чем писать код, изучи нужные файлы и опиши план по шагам. Жди моего «ок», потом делай."),
            PromptSnippet(title: "Ревью диффа", text: "Сделай ревью текущего диффа: баги, пограничные случаи, лишняя сложность. Сначала самое серьёзное, с file:line."),
            PromptSnippet(title: "Тесты и фикс", text: "Запусти тесты. Если что-то падает — найди причину, почини и перезапусти, пока всё не станет зелёным."),
            PromptSnippet(title: "Коротко", text: "Отвечай коротко и по делу, без вступлений и пересказа задачи."),
            PromptSnippet(title: "Объясни как джуну", text: "Объясни, как работает этот код, простыми словами, как новичку в проекте. С примерами."),
        ] : [
            PromptSnippet(title: "Plan first", text: "Before writing code, read the relevant files and lay out a step-by-step plan. Wait for my OK, then do it."),
            PromptSnippet(title: "Review the diff", text: "Review the current diff: bugs, edge cases, needless complexity. Most serious first, with file:line."),
            PromptSnippet(title: "Test and fix", text: "Run the tests. If anything fails, find the cause, fix it and rerun until everything is green."),
            PromptSnippet(title: "Be brief", text: "Answer briefly and to the point, no preamble and no restating the task."),
            PromptSnippet(title: "Explain like I'm new", text: "Explain how this code works in plain words, as to someone new to the project. Use examples."),
        ])
    }
}
