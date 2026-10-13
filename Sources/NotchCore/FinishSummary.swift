import Foundation

/// Words of the finish toast, in one place.
private enum FinishText {
    static var done: String { Loc.t("done", "готово") }
    static var testsOk: String { Loc.t("tests ✓", "тесты ✓") }
    static var testsFailed: String { Loc.t("tests ✗", "тесты ✗") }
    static var commit: String { Loc.t("commit", "коммит") }
    static func files(_ n: Int) -> String {
        if !Loc.isRussian { return n == 1 ? "1 file" : "\(n) files" }
        let last = n % 10, tens = n % 100
        let word = tens >= 11 && tens <= 14 ? "файлов" : last == 1 ? "файл" : (2...4).contains(last) ? "файла" : "файлов"
        return "\(n) \(word)"
    }
}

/// The one line of the toast and the preview under it, built from what DetailReader read.
public enum FinishSummary {
    /// A `git commit` command, also behind `git -C dir` or `cd x && git commit`.
    static func isCommit(_ c: CommandRun) -> Bool {
        c.command.range(of: #"\bgit\b[^|;&\n]*\bcommit\b"#, options: .regularExpression) != nil
    }

    /// The commands of this run: those stamped before `since` belong to earlier work. Unstamped ones stay.
    static func recent(_ detail: AgentDetail, since: Double?) -> [CommandRun] {
        detail.commands.filter { c in since.map { s in c.at.map { $0 >= s } ?? true } ?? true }
    }

    /// Files changed in this run; unstamped ones stay, like commands.
    static func recentFiles(_ detail: AgentDetail, since: Double?) -> [FileChange] {
        detail.files.filter { f in since.map { s in f.at.map { $0 >= s } ?? true } ?? true }
    }

    /// Whether the run made a commit that did not fail. The app then asks git for its short hash.
    public static func madeCommit(_ detail: AgentDetail, since: Double?) -> Bool {
        recent(detail, since: since).contains { isCommit($0) && $0.ok != false }
    }

    /// "done · 3 files · tests ✓ · commit abc123". Parts with nothing to say are left out.
    public static func line(_ detail: AgentDetail, since: Double? = nil, commit: String? = nil) -> String {
        let commands = recent(detail, since: since)
        var parts = [FinishText.done]
        let files = recentFiles(detail, since: since)
        if !files.isEmpty { parts.append(FinishText.files(files.count)) }
        if let test = commands.last(where: { $0.isTest && $0.ok != nil }) {
            parts.append(test.ok == true ? FinishText.testsOk : FinishText.testsFailed)
        }
        if commands.contains(where: { isCommit($0) && $0.ok != false }) {
            parts.append([FinishText.commit, commit].compactMap { $0 }.joined(separator: " "))
        }
        return parts.joined(separator: " · ")
    }

    /// The first non-empty line of the agent's last message.
    public static func preview(_ detail: AgentDetail, limit: Int = 140) -> String? {
        let first = detail.lastMessage?.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        return first.flatMap { LogText.clip($0, limit) }
    }
}

/// An agent that went from working to done.
public struct Finished: Equatable, Sendable {
    public let agent: Agent
    /// When it was first seen working in this run; commands older than this are not part of it.
    public let workedSince: Double
}

/// Spots root sessions that finish. Subagents never count: the parent reports for them.
public struct FinishWatcher: Sendable {
    private var working: [String: Double] = [:]

    public init() {}

    /// Feed every poll. The first poll only learns who is working, so starting the app announces nothing.
    public mutating func update(_ agents: [Agent], now: Double) -> [Finished] {
        var out: [Finished] = []
        var next: [String: Double] = [:]
        for a in agents where a.parentId == nil {
            // A pause to ask for permission or an error does not end the run: its start time is kept.
            if a.state != .done { if a.state == .working || working[a.id] != nil { next[a.id] = working[a.id] ?? now } }
            else if let since = working[a.id] { out.append(Finished(agent: a, workedSince: since)) }
        }
        working = next
        return out
    }
}
