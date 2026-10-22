import Foundation

/// What the agents' house screen saver shows, handed over by the running app: the app rewrites
/// ~/Library/Application Support/AgentsNotch/house.json on every change and at least every `heartbeat` seconds,
/// and the saver (another process, sandboxed in legacyScreenSaver) polls it. A file older than `staleAfter`
/// means the app is gone, and the saver shows an empty house.
public struct HouseSnapshot: Equatable {
    public static let heartbeat: TimeInterval = 10
    public static let staleAfter: TimeInterval = 35

    /// The rows `room.setAgents(...)` takes, as JSON.
    public var agents: String
    /// What `room.setUsage(...)` takes, as JSON; nil until the app has read the limits.
    public var usage: String?
    /// What `room.configure(...)` takes, as JSON.
    public var config: String
    public var fps: Int
    public var written: Date

    public init(agents: String, usage: String?, config: String, fps: Int, written: Date) {
        self.agents = agents
        self.usage = usage
        self.config = config
        self.fps = fps
        self.written = written
    }

    /// An empty house, for when the app is not running.
    public static func empty(at date: Date) -> HouseSnapshot { HouseSnapshot(agents: "[]", usage: nil, config: "{}", fps: 30, written: date) }

    /// Snapshots that differ only in when they were written show the same house.
    public func sameHouse(as other: HouseSnapshot) -> Bool {
        agents == other.agents && usage == other.usage && config == other.config && fps == other.fps
    }

    public func encoded() -> Data? {
        var body: [String: Any] = ["written": written.timeIntervalSince1970, "fps": fps]
        for (key, json) in [("agents", agents), ("usage", usage), ("config", config)] {
            guard let json, let value = try? JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed]) else { continue }
            body[key] = value
        }
        return try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    /// The house in `data`, or nil when it is unreadable or older than `staleAfter` (a clock set back counts as fresh).
    public static func decode(_ data: Data, now: Date) -> HouseSnapshot? {
        guard let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let written = body["written"] as? Double,
              now.timeIntervalSince1970 - written < staleAfter,
              let agents = body["agents"] as? [Any] else { return nil }
        func json(_ value: Any?) -> String? {
            guard let value, JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        return HouseSnapshot(agents: json(agents) ?? "[]", usage: json(body["usage"]), config: json(body["config"]) ?? "{}",
                             fps: (body["fps"] as? Int).map { min(max($0, 10), 60) } ?? 30,
                             written: Date(timeIntervalSince1970: written))
    }

    /// The snapshot file under a home folder.
    public static func url(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/AgentsNotch/house.json")
    }

    /// The user's real home: inside legacyScreenSaver's sandbox NSHomeDirectory() is its container.
    public static var realHome: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { return URL(fileURLWithPath: String(cString: dir)) }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// Where the saver is installed for this user or for everyone; the app only writes the snapshot while one is.
    public static func installedSavers(home: URL) -> [URL] {
        let name = "Agent Notch House.saver"
        return [home.appendingPathComponent("Library/Screen Savers/\(name)"), URL(fileURLWithPath: "/Library/Screen Savers/\(name)")]
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}
