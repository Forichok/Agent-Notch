import AppKit
import NotchCore

/// Puts the bundled Agent Notch House.saver into ~/Library/Screen Savers. The copy keeps no quarantine flag:
/// the user already let the app run, and a flagged saver would only show a blank thumbnail in System Settings.
enum RoomSaverInstall {
    enum State: Equatable { case missing, installed, outdated, unavailable }

    static let name = "Agent Notch House.saver"
    static var bundled: URL? { Bundle.main.url(forResource: "Agent Notch House", withExtension: "saver") }
    static var target: URL { HouseSnapshot.realHome.appendingPathComponent("Library/Screen Savers/\(name)") }

    static var state: State {
        guard let bundled else { return .unavailable }
        guard FileManager.default.fileExists(atPath: target.path) else { return .missing }
        return revision(bundled) == revision(target) ? .installed : .outdated
    }

    static func install() throws {
        guard let bundled else { return }
        let fm = FileManager.default
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        try fm.copyItem(at: bundled, to: target)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        task.arguments = ["-dr", "com.apple.quarantine", target.path]
        try? task.run()
        task.waitUntilExit()
    }

    /// System Settings → Screen Saver, where the house is picked; Lock Screen holds "Require password".
    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.ScreenSaver-Settings.extension") { NSWorkspace.shared.open(url) }
    }

    private static func revision(_ saver: URL) -> String? {
        guard let info = NSDictionary(contentsOf: saver.appendingPathComponent("Contents/Info.plist")) else { return nil }
        return "\(info["CFBundleVersion"] ?? "")/\(info["AgentNotchSourceRevision"] ?? "")"
    }
}
