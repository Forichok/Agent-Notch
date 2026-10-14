import Foundation
#if canImport(NotchCore)
import NotchCore
#endif

struct SkillCatalogChecks {
    func write(_ text: String, _ path: String, in root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func frontMatter() {
        let (fields, body) = SkillFrontMatter.parse("""
        ---
        name: "review"
        description: >
          Reviews the diff
          and lists bugs.
        allowed-tools:
          - Read
          - Grep
        metadata:
          short-description: Review
        license: 'MIT'
        tags: [a, "b"]
        ---

        # Review
        Body text.
        """)
        let map = Dictionary(uniqueKeysWithValues: fields.map { ($0.key, $0.value) })
        XCTAssertEqual(map["name"], "review")
        XCTAssertEqual(map["description"], "Reviews the diff and lists bugs.")
        XCTAssertEqual(map["allowed-tools"], "Read, Grep")
        XCTAssertEqual(map["metadata"], "short-description: Review")
        XCTAssertEqual(map["license"], "MIT")
        XCTAssertEqual(map["tags"], "a, b")
        XCTAssertEqual(body, "# Review\nBody text.")
        XCTAssertEqual(SkillFrontMatter.parse("# no front matter").fields.count, 0)
    }

    func catalog() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("skills-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let skill = { (name: String, desc: String) in "---\nname: \(name)\ndescription: \(desc)\n---\nbody of \(name)\n" }
        try write(skill("trip", "Plans trips"), ".claude/skills/trip/SKILL.md", in: home)
        try write("notes", ".claude/skills/trip/references/a.md", in: home)
        try write("no skill here", ".claude/skills/empty/README.md", in: home)
        let plugin = home.appendingPathComponent(".claude/plugins/cache/m/decide/1.1.0").path
        try write(skill("decide", "Decides"), ".claude/plugins/cache/m/decide/1.1.0/skills/decide/SKILL.md", in: home)
        try write("""
        {"version":2,"plugins":{"decide@m":[{"scope":"user","installPath":"\(plugin)","version":"1.1.0"},
        {"scope":"project","projectPath":"/x","installPath":"\(plugin)","version":"1.1.0"}]}}
        """, ".claude/plugins/installed_plugins.json", in: home)
        try write(#"{"enabledPlugins":{"decide@m":false}}"#, ".claude/settings.json", in: home)
        try write(skill("imagegen", "Images"), ".codex/skills/.system/imagegen/SKILL.md", in: home)
        try write(skill("mine", "Mine"), ".codex/skills/mine/SKILL.md", in: home)
        try write(skill("pdf", "Old"), ".codex/plugins/cache/rt/pdf/2.9.0/skills/pdf/SKILL.md", in: home)
        try write(skill("pdf", "New"), ".codex/plugins/cache/rt/pdf/10.0.1/skills/pdf/SKILL.md", in: home)
        try write("[plugins.\"pdf@rt\"]\nenabled = true\n\n[other]\nenabled = false\n", ".codex/config.toml", in: home)
        try write(skill("local", "Project skill"), "repo/.claude/skills/local/SKILL.md", in: home)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("repo/.git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("repo/src"), withIntermediateDirectories: true)
        try write(skill("local", "Stale copy in a worktree"), "wt/.claude/skills/local/SKILL.md", in: home)
        try write("gitdir: \(home.path)/repo/.git/worktrees/wt\n", "wt/.git", in: home)

        // Remembered by the agents, with no agent running there now.
        try write(skill("remembered", "From ~/.claude.json"), "old/.claude/skills/remembered/SKILL.md", in: home)
        try write(skill("codexproj", "From config.toml"), "plain/.agents/skills/codexproj/SKILL.md", in: home)
        try write(#"{"projects":{"\#(home.path)/old":{},"\#(home.path)/gone":{}}}"#, ".claude.json", in: home)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("old/.git"), withIntermediateDirectories: true)
        let toml = try String(contentsOf: home.appendingPathComponent(".codex/config.toml"), encoding: .utf8)
        try write(toml + "\n[projects.\"\(home.path)/plain\"]\ntrust_level = \"trusted\"\n", ".codex/config.toml", in: home)
        let found = SkillCatalog(home: home).scan(projects: [home.appendingPathComponent("repo/src").path, home.appendingPathComponent("repo").path,
                                                                  home.appendingPathComponent("wt").path])
        XCTAssertEqual(found.map(\.name), ["trip", "remembered", "local", "decide", "mine", "codexproj", "pdf", "imagegen"])
        XCTAssertEqual(found.map(\.source), [.user, .project, .project, .plugin, .user, .project, .plugin, .system])
        let trip = found[0], decide = found[3], pdf = found[6]
        XCTAssertEqual(trip.files, 2)
        XCTAssertEqual(trip.body, "body of trip")
        XCTAssertEqual(trip.invocation, "/trip")
        XCTAssertEqual(decide.invocation, "/decide:decide")
        XCTAssertEqual(decide.usageKeys, ["decide:decide", "decide"])
        XCTAssertEqual(decide.enabled, false)
        XCTAssertEqual(pdf.description, "New")
        XCTAssertEqual(pdf.pluginVersion, "10.0.1")
        XCTAssertEqual(pdf.enabled, true)
        XCTAssertEqual(pdf.invocation, "$pdf")
        XCTAssertEqual(found[2].project?.hasSuffix("/repo"), true)
    }

    func ranking() {
        func s(_ name: String, _ vendor: Vendor, _ description: String = "", enabled: Bool? = nil) -> InstalledSkill {
            InstalledSkill(id: vendor.rawValue + name, name: name, description: description, vendor: vendor, source: .user,
                           enabled: enabled, folder: "/x")
        }
        let list = [s("pdf", .codex, "Read PDF files"), s("alpha", .claude), s("off", .claude, enabled: false),
                    s("review", .claude, "Reviews a pdf diff"), s("beta", .codex)]
        let uses = ["clauderreview": 0, "claudealpha": 5, "claudeoff": 50]
        let use = { (x: InstalledSkill) in uses[x.id] ?? 0 }
        XCTAssertEqual(list.ranked(uses: use).map(\.name), ["alpha", "beta", "pdf", "review", "off"])
        XCTAssertEqual(list.ranked(uses: use, prefer: .codex).map(\.name), ["alpha", "beta", "pdf", "review", "off"])
        XCTAssertEqual(list.ranked(prefer: .codex).map(\.name), ["beta", "pdf", "alpha", "review", "off"])
        XCTAssertEqual(list.ranked(query: "pdf").map(\.name), ["pdf", "review"])
        XCTAssertEqual(list.ranked(query: "nothing").count, 0)
    }

    func usage() {
        let lines = [
            #"{"type":"assistant","timestamp":"2026-10-01T10:00:00.000Z","message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"decide:decide"}}]}}"#,
            #"{"type":"assistant","timestamp":"2026-10-02T10:00:00.000Z","message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"decide:decide"}}]}}"#,
            #"{"type":"user","timestamp":"2026-10-03T10:00:00.000Z","message":{"role":"user","content":"<command-name>/trip</command-name>\n<command-args></command-args>"}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"the \"Skill\" tool is not called here"}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"text","text":"no commands"}]}}"#,
        ]
        let uses = SkillUsageScanner.uses(in: Data(lines.joined(separator: "\n").utf8))
        XCTAssertEqual(uses["decide:decide"]?.count, 2)
        XCTAssertEqual(uses["decide:decide"]?.last, ISO8601DateFormatter().date(from: "2026-10-02T10:00:00Z"))
        XCTAssertEqual(uses["trip"]?.count, 1)
        XCTAssertEqual(uses.count, 2)
    }
}
