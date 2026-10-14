import Foundation

public enum MarkStyle: String, Codable, CaseIterable, Sendable { case dots, logos, logosMono, letters }
public enum MarkSize: String, Codable, CaseIterable, Sendable {
    case small, medium, large
    public var points: Double { switch self { case .small: 6; case .medium: 9; case .large: 12 } }
}
public enum LimitChipMode: String, Codable, CaseIterable, Sendable {
    case always, nearLimit, never
    public func isVisible(usedPercent: Double?, threshold: Double = 80) -> Bool {
        switch self {
        case .always: true
        case .never: false
        case .nearLimit: usedPercent.map { $0 >= min(100, max(0, threshold)) } ?? false
        }
    }
}
public enum RowPart: String, Codable, CaseIterable, Sendable {
    case statusMark, title, project, model, effort, branch, worktree, activity, runningTime, context, cost
}
public enum CardBlock: String, Codable, CaseIterable, Sendable {
    case done, remaining, files, log, prompts, commands, lastMessage, errors, modelTime, contextCost
}

/// Order and visibility travel together, including disabled parts.
public struct DisplayPart<Part: RawRepresentable & Codable & Hashable & CaseIterable>: Codable, Equatable, Identifiable where Part.RawValue == String {
    public var part: Part
    public var enabled: Bool
    public var id: Part { part }
    public init(_ part: Part, enabled: Bool = true) { self.part = part; self.enabled = enabled }
}

public enum DisplayOrder {
    /// Older saved layouts gain new parts without losing their chosen order.
    public static func normalize<P>(_ parts: [DisplayPart<P>]) -> [DisplayPart<P>] {
        var seen = Set<P>()
        let unique = parts.filter { seen.insert($0.part).inserted }
        return unique + P.allCases.filter { !seen.contains($0) }.map { DisplayPart($0) }
    }
    public static func visible<P>(_ parts: [DisplayPart<P>]) -> [P] { parts.filter(\.enabled).map(\.part) }
    public static func move<P>(_ parts: [DisplayPart<P>], from: Int, to: Int) -> [DisplayPart<P>] {
        guard parts.indices.contains(from), parts.indices.contains(to) else { return parts }
        var next = parts
        next.insert(next.remove(at: from), at: to)
        return next
    }
}

public enum RowDisplay {
    /// Appearance switches hide parts without changing the saved order.
    public static func parts(_ order: [DisplayPart<RowPart>], showModel: Bool = true,
                             showActivity: Bool = true, showContext: Bool = true) -> [RowPart] {
        DisplayOrder.visible(order).filter {
            switch $0 {
            case .model: showModel
            case .activity: showActivity
            case .context: showContext
            default: true
            }
        }
    }
}

public struct ShortcutModifiers: OptionSet, Codable, Hashable, Sendable {
    public var rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let control = Self(rawValue: 1)
    public static let option = Self(rawValue: 2)
    public static let shift = Self(rawValue: 4)
    public static let command = Self(rawValue: 8)
}

/// Physical key codes keep global shortcuts stable when the input language changes.
public struct KeyboardShortcut: Codable, Equatable, Sendable {
    public var keyCode: UInt32
    public var modifiers: ShortcutModifiers
    public init(keyCode: UInt32, modifiers: ShortcutModifiers) { self.keyCode = keyCode; self.modifiers = modifiers }
    public static let allow = Self(keyCode: 16, modifiers: [.control, .option])
    public static let deny = Self(keyCode: 45, modifiers: [.control, .option])
    public static let list = Self(keyCode: 0, modifiers: [.control, .option])
    public static let vault = Self(keyCode: 35, modifiers: [.control, .option])
    public var isValid: Bool {
        // The open list owns ⌘, so it must never answer a permission request.
        !(keyCode == 43 && modifiers == .command) &&
        Self.keys[keyCode] != nil && modifiers.rawValue & ~UInt32(15) == 0 &&
        !modifiers.intersection([.control, .option, .command]).isEmpty
    }
    public var display: String {
        [(ShortcutModifiers.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
            .filter { modifiers.contains($0.0) }.map(\.1).joined() + (Self.keys[keyCode] ?? "?")
    }
    private static let keys: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B",
        12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4",
        22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "−", 28: "8", 29: "0", 30: "]", 31: "O",
        32: "U", 33: "[", 34: "I", 35: "P", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\",
        43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 49: "␣", 50: "`",
        123: "←", 124: "→", 125: "↓", 126: "↑"
    ]
}

/// Keep legacy boolean keys readable after settings move into the shared object.
public enum SettingsStorage {
    public static func read<T: Codable>(_ type: T.Type, key: String, default fallback: T, in defaults: UserDefaults) -> T {
        if T.self == Bool.self, let value = defaults.object(forKey: key) as? T { return value }
        guard let data = defaults.data(forKey: key), let value = try? JSONDecoder().decode(T.self, from: data) else { return fallback }
        return value
    }
    public static func write<T: Codable>(_ value: T, key: String, in defaults: UserDefaults) {
        if let bool = value as? Bool { defaults.set(bool, forKey: key) }
        else if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
}
