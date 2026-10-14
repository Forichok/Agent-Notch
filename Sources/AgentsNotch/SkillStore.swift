import AppKit
import Foundation
import NotchCore

/// Installed skills of both agents and how often Claude Code called each. Scans run off the main thread;
/// the first count reads every Claude transcript once, later ones only the sessions that changed.
@MainActor
final class SkillStore: ObservableObject {
    static let shared = SkillStore()

    @Published private(set) var skills: [InstalledSkill] = []
    @Published private(set) var uses: [String: SkillUse] = [:]
    @Published private(set) var scanning = false
    @Published private(set) var counting = false
    @Published private(set) var updated: Date?
    @Published var selected: String?
    /// Working folders of the agents the app knows: their repositories may hold project skills.
    var projects: @MainActor () -> [String] = { [] }
    private var scanner = SkillUsageScanner()
    private let fixture: Bool

    init(fixture: [InstalledSkill]? = nil, uses: [String: SkillUse] = [:]) {
        self.fixture = fixture != nil
        if let fixture {
            skills = fixture
            self.uses = uses
            selected = fixture.first?.id
            updated = Date()
        }
    }

    func refresh() {
        guard !fixture, !scanning else { return }
        scanning = true
        let roots = projects()
        Task.detached(priority: .userInitiated) {
            let found = SkillCatalog().scan(projects: roots)
            await MainActor.run {
                self.skills = found
                self.scanning = false
                self.updated = Date()
                if self.selected.map({ id in !found.contains { $0.id == id } }) ?? true { self.selected = found.first?.id }
            }
        }
        guard !counting else { return }
        counting = true
        let scanner = self.scanner
        Task.detached(priority: .utility) {
            var scanner = scanner
            let uses = scanner.scan()
            let done = scanner
            await MainActor.run {
                self.scanner = done
                self.uses = uses
                self.counting = false
            }
        }
    }

    func use(of skill: InstalledSkill) -> SkillUse {
        var total = SkillUse()
        for key in skill.usageKeys { if let u = uses[key] { total.add(u) } }
        return total
    }

    func skill(_ id: String?) -> InstalledSkill? { skills.first { $0.id == id } }
}
