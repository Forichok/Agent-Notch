import Foundation

/// A pet made with Codex's /hatch (or installed from a pet pack): `<CODEX_HOME>/pets/<id>/pet.json` naming a spritesheet
/// of 8 columns by 9 rows (idle, running right, running left, waving, jumping, failed, waiting, running, review).
/// The agents' house draws Codex agents as this pet when there is one.
public struct CodexPet: Equatable, Sendable {
    public static let columns = 8, rows = 9
    public let id: String
    public let name: String
    public let sheet: URL

    /// The pet to show: Codex keeps no readable "selected pet" yet, so the one changed last wins.
    public static func find(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                            environment: [String: String] = ProcessInfo.processInfo.environment) -> CodexPet? {
        let pets = ConfigRoots(home: home, environment: environment).root(.codex).appendingPathComponent("pets")
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: pets, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return nil }
        let found: [(CodexPet, Date)] = dirs.compactMap { dir in
            let manifest = dir.appendingPathComponent("pet.json")
            guard let data = try? Data(contentsOf: manifest),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            let rel = (obj["spritesheetPath"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "spritesheet.webp"
            let sheet = dir.appendingPathComponent(rel).standardizedFileURL
            // the sheet must stay inside the pet's own folder
            guard sheet.path.hasPrefix(dir.standardizedFileURL.path + "/"), fm.fileExists(atPath: sheet.path) else { return nil }
            let id = (obj["id"] as? String) ?? dir.lastPathComponent
            let name = (obj["displayName"] as? String) ?? id
            let stamp = [manifest, sheet].compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.max() ?? .distantPast
            return (CodexPet(id: id, name: name, sheet: sheet), stamp)
        }
        return found.max { $0.1 < $1.1 || ($0.1 == $1.1 && $0.0.id > $1.0.id) }?.0
    }
}
