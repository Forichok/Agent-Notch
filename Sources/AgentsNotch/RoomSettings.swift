import Combine
import Foundation
import NotchCore

/// «Дом на рабочем столе»: how the agents' house is laid out, which room each project gets, how often it is drawn
/// and on which screens. Every field decodes on its own, so older saved blobs keep their other values.
struct RoomPrefs: Codable, Equatable {
    enum Layout: String, Codable, CaseIterable { case islands, steps, towers }
    enum FrameRate: String, Codable, CaseIterable { case auto, fps30, fps60 }
    enum Screens: String, Codable, CaseIterable { case main, all }

    var layout: Layout = .islands
    /// Project name → theme id; a project missing here gets its automatic room.
    var themes: [String: String] = [:]
    var frameRate: FrameRate = .auto
    var screens: Screens = .main

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        layout = (try? c.decodeIfPresent(Layout.self, forKey: .layout)) ?? .islands
        themes = (try? c.decodeIfPresent([String: String].self, forKey: .themes)) ?? [:]
        frameRate = (try? c.decodeIfPresent(FrameRate.self, forKey: .frameRate)) ?? .auto
        screens = (try? c.decodeIfPresent(Screens.self, forKey: .screens)) ?? .main
    }

    /// Frames per second while the house is awake: the chosen cap, or 60 on power, 30 on battery and 20 in Low Power Mode.
    /// While no agent works and nobody walks the page draws nothing at all (room/index.html, houseAwake).
    func fps(lowPower: Bool, onBattery: Bool) -> Int {
        switch frameRate {
        case .fps30: 30
        case .fps60: 60
        case .auto: lowPower ? 20 : onBattery ? 30 : 60
        }
    }

    /// What `room.configure(...)` takes, as JSON.
    var pageConfig: String {
        let body: [String: Any] = ["layout": layout.rawValue, "themes": themes.filter { RoomTheme(rawValue: $0.value) != nil }]
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }
}

/// The project rooms of room/index.html, in the order of its PROJECT_THEMES.
enum RoomTheme: String, CaseIterable {
    case bedroom, server, library, greenhouse, arcade

    var title: String {
        switch self {
        case .bedroom: Loc.t("Bedroom", "Спальня")
        case .server: Loc.t("Server room", "Серверная")
        case .library: Loc.t("Library", "Библиотека")
        case .greenhouse: Loc.t("Greenhouse", "Оранжерея")
        case .arcade: Loc.t("Arcade", "Игровая")
        }
    }

    /// The room a project gets on its own: the page hashes the name the same way (FNV-1a over UTF-16, then mixed), so it never
    /// changes when other projects come and go.
    static func auto(for project: String) -> RoomTheme {
        var h: UInt32 = 0x811c9dc5
        for unit in project.utf16 { h ^= UInt32(unit); h = h &* 0x01000193 }
        h ^= h >> 16; h = h &* 0x45d9f3b; h ^= h >> 16
        return allCases[Int(h % UInt32(allCases.count))]
    }
}

/// The projects the settings list rooms for: what the notch shows now, read when the section opens.
@MainActor
final class RoomProjects {
    static let shared = RoomProjects()
    var source: () -> [String] = { [] }
    var current: [String] { Array(Set(source().filter { !$0.isEmpty })).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending } }
}
