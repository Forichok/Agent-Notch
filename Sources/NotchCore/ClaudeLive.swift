import Darwin
import Foundation

/// What a running Claude Code process says about itself in ~/.claude/sessions/<pid>.json:
/// busy, idle, or waiting with what it waits for. More exact than reading silence in the log.
public struct ClaudeLive: Sendable, Equatable {
    public var status: String
    public var waitingFor: String?
    public var name: String?
    /// The process is still running.
    public var alive: Bool
    /// The Claude Code process, 0 when unknown.
    public var pid: Int32 = 0

    /// Session id → its live status. Files of processes that are gone come back with `alive == false`.
    static func read(_ dir: URL, alive: (Int32) -> Bool = ClaudeLive.isRunning) -> [String: ClaudeLive] {
        var out: [String: ClaudeLive] = [:]
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f), data.count < 64 << 10,
                  let r = try? JSONSerialization.jsonObject(with: data) as? Rec,
                  let id = r["sessionId"] as? String, let status = r["status"] as? String else { continue }
            let pid = (r["pid"] as? NSNumber)?.int32Value ?? 0
            out[id] = ClaudeLive(status: status, waitingFor: r["waitingFor"] as? String, name: r["name"] as? String,
                                 alive: pid > 0 && alive(pid), pid: pid)
        }
        return out
    }

    static func isRunning(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// "dialog open" → words for the list.
    var waitingText: String {
        switch waitingFor {
        case nil, "dialog open": Loc.t("approval in the Claude window", "подтверждение в окне Claude")
        case "input needed": Loc.t("needs an answer", "нужен ответ")
        case "sandbox request": Loc.t("sandbox access", "доступ из песочницы")
        case let other?: other
        }
    }
}
