import Foundation

/// A permission request held open until someone clicks.
public struct PendingAsk: Identifiable, Equatable, Sendable {
    public let ticket: Int
    public let event: HookEvent
    public let at: Double
    public var id: Int { ticket }
}

/// What the hooks have said on top of the logs: open permission requests and prompts on screen in the agent's own window.
public struct HookState: Sendable, Equatable {
    public private(set) var pending: [PendingAsk] = []
    /// Agent key → what its own window asks right now, and since when.
    private(set) var shown: [String: Shown] = [:]

    struct Shown: Sendable, Equatable {
        var text: String
        var at: Double
    }

    public init() {}

    /// Takes one event. Returns the tickets that went stale: the agent moved on without our answer, so they get `.pass`.
    public mutating func receive(_ e: HookEvent, ticket: Int?, now: Double) -> [Int] {
        if let ticket {
            pending.append(PendingAsk(ticket: ticket, event: e, at: now))
            return []
        }
        if e.isPromptShown {
            shown[e.agentKey] = Shown(text: LogText.clip(e.message, 60) ?? Loc.t("approval", "подтверждение"), at: now)
            return []
        }
        shown[e.agentKey] = nil
        let ended = ["Stop", "UserPromptSubmit", "SessionEnd", "SubagentStop"].contains(e.name)
        let stale = pending.filter { p in
            p.event.agentKey == e.agentKey && (ended || (e.name == "PostToolUse" && p.event.tool == e.tool && p.event.detail == e.detail))
        }
        if e.name == "SessionEnd" { shown = shown.filter { !$0.key.hasPrefix(e.sessionId) } }
        pending.removeAll { p in stale.contains { $0.ticket == p.ticket } }
        return stale.map(\.ticket)
    }

    public mutating func resolve(_ ticket: Int) {
        pending.removeAll { $0.ticket == ticket }
    }

    /// The agents with hook knowledge laid over: open requests and shown prompts make them wait.
    /// A request from a session the logs do not show yet becomes its own row.
    public func apply(to agents: [Agent], now: Double, project: (String?) -> String) -> [Agent] {
        var out = agents.map { a -> Agent in
            var a = a
            if let p = pending.first(where: { $0.event.agentKey == a.id }) {
                a.state = .waiting
                a.ask = p.event.askLine
            } else if let s = shown[a.id], now - s.at < 3600 {
                a.state = .waiting
                a.ask = s.text
            }
            return a
        }
        var known = Set(agents.map(\.id))
        for p in pending where !known.contains(p.event.agentKey) {
            let e = p.event
            known.insert(e.agentKey)
            out.append(Agent(id: e.agentKey, vendor: e.vendor, title: Loc.t("new session", "новая сессия"), state: .waiting,
                             project: project(e.cwd), parentId: e.agentId == nil ? nil : e.sessionId,
                             ask: e.askLine, startedAt: p.at, cwd: e.cwd, chatId: e.sessionId))
        }
        return out
    }
}
