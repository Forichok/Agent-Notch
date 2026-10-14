import Foundation

/// A skill found on this Mac: a folder with a `SKILL.md` that Claude Code or Codex loads.
public struct InstalledSkill: Identifiable, Equatable, Sendable {
    public enum Source: String, Sendable { case user, system, plugin, project }

    /// The SKILL.md path, resolved: the same file reached twice is listed once.
    public var id: String
    public var name: String
    public var description: String
    public var vendor: Vendor
    public var source: Source
    public var plugin: String?
    public var pluginVersion: String?
    /// The repository folder for project skills.
    public var project: String?
    /// false when the plugin is switched off in the agent's settings; nil when they say nothing.
    public var enabled: Bool?
    /// Front matter besides name and description, in file order (allowed-tools, model, license…).
    public var fields: [Field]
    /// SKILL.md after the front matter.
    public var body: String
    public var folder: String
    public var files: Int
    public var bytes: Int
    public var modified: Date

    public struct Field: Equatable, Sendable {
        public var key: String
        public var value: String
        public init(key: String, value: String) { self.key = key; self.value = value }
    }

    public init(id: String, name: String, description: String, vendor: Vendor, source: Source, plugin: String? = nil,
                pluginVersion: String? = nil, project: String? = nil, enabled: Bool? = nil, fields: [Field] = [],
                body: String = "", folder: String, files: Int = 1, bytes: Int = 0, modified: Date = .distantPast) {
        self.id = id
        self.name = name
        self.description = description
        self.vendor = vendor
        self.source = source
        self.plugin = plugin
        self.pluginVersion = pluginVersion
        self.project = project
        self.enabled = enabled
        self.fields = fields
        self.body = body
        self.folder = folder
        self.files = files
        self.bytes = bytes
        self.modified = modified
    }

    /// What you type to call it: `/name` or `/plugin:name` in Claude Code, `$name` in Codex.
    public var invocation: String {
        switch vendor {
        case .claude: "/" + (plugin.map { $0 + ":" } ?? "") + name
        case .codex: "$" + name
        }
    }

    /// The names a Claude transcript may record for a call of this skill.
    public var usageKeys: [String] {
        guard vendor == .claude else { return [] }
        return plugin.map { [$0 + ":" + name, name] } ?? [name]
    }
}

public extension Array where Element == InstalledSkill {
    /// The picker's order: a hit in the name beats a hit in the text, then most called, then the agent in front,
    /// then by name. Plugins switched off go last.
    func ranked(query: String = "", uses: (InstalledSkill) -> Int = { _ in 0 }, prefer: Vendor? = nil) -> [InstalledSkill] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let matched = words.isEmpty ? self : filter { s in
            let hay = (s.name + "\n" + s.description + "\n" + (s.plugin ?? "")).lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
        let counts = Dictionary(matched.map { ($0.id, uses($0)) }, uniquingKeysWith: { a, _ in a })
        func nameHits(_ s: InstalledSkill) -> Int { words.filter { s.name.lowercased().contains($0) }.count }
        return matched.sorted { a, b in
            let offA = a.enabled == false, offB = b.enabled == false
            if offA != offB { return offB }
            let ha = nameHits(a), hb = nameHits(b)
            if ha != hb { return ha > hb }
            let ua = counts[a.id] ?? 0, ub = counts[b.id] ?? 0
            if ua != ub { return ua > ub }
            if let prefer, a.vendor != b.vendor { return a.vendor == prefer }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }
}

/// How often Claude Code called a skill: through the Skill tool or a typed `/name`.
public struct SkillUse: Equatable, Sendable {
    public var count: Int
    public var last: Date?
    public init(count: Int = 0, last: Date? = nil) { self.count = count; self.last = last }

    public mutating func add(_ other: SkillUse) {
        count += other.count
        if let d = other.last, last.map({ d > $0 }) ?? true { last = d }
    }
}

public enum SkillFrontMatter {
    /// The YAML subset skills use: scalars, quoted strings, `|` and `>` blocks, lists and one level of maps.
    public static func parse(_ text: String) -> (fields: [InstalledSkill.Field], body: String) {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return ([], text)
        }
        var fields: [InstalledSkill.Field] = []
        var i = 1
        while i < end {
            let line = lines[i]
            i += 1
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), !line.hasPrefix("#"),
                  let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let rest = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            var nested: [String] = []
            while i < end, lines[i].isEmpty || lines[i].hasPrefix(" ") || lines[i].hasPrefix("\t") {
                nested.append(lines[i])
                i += 1
            }
            let block = nested.map { $0.trimmingCharacters(in: .whitespaces) }
            let value: String
            if rest.hasPrefix("|") {
                value = block.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            } else if rest.hasPrefix(">") || (rest.isEmpty && !block.contains(where: { $0.hasPrefix("- ") || $0.contains(": ") })) {
                value = block.filter { !$0.isEmpty }.joined(separator: " ")
            } else if rest.isEmpty {
                value = block.filter { !$0.isEmpty }.map { $0.hasPrefix("- ") ? unquote(String($0.dropFirst(2))) : $0 }
                    .joined(separator: block.contains(where: { $0.hasPrefix("- ") }) ? ", " : "\n")
            } else if rest.hasPrefix("[") && rest.hasSuffix("]") {
                value = rest.dropFirst().dropLast().split(separator: ",").map { unquote($0.trimmingCharacters(in: .whitespaces)) }
                    .joined(separator: ", ")
            } else {
                // A plain scalar may continue on indented lines.
                value = ([unquote(rest)] + block.filter { !$0.isEmpty }).joined(separator: " ")
            }
            fields.append(.init(key: key, value: value))
        }
        let body = lines[(end + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (fields, body)
    }

    static func unquote(_ s: String) -> String {
        guard s.count >= 2, let f = s.first, f == "\"" || f == "'", s.last == f else { return s }
        let inner = String(s.dropFirst().dropLast())
        return f == "\"" ? inner.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\n", with: "\n")
            : inner.replacingOccurrences(of: "''", with: "'")
    }
}

/// Where each agent keeps its skills. Nothing is executed: only folders and settings files are read.
public struct SkillCatalog: Sendable {
    public let home: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) { self.home = home }

    /// Every skill, grouped Claude first, then by source and name. `projects` are working folders of live agents;
    /// the projects both agents remember (`~/.claude.json`, `~/.codex/config.toml`) are added to them.
    public func scan(projects: [String] = []) -> [InstalledSkill] {
        var found: [InstalledSkill] = []
        var seen = Set<String>()
        func add(_ dir: URL, _ vendor: Vendor, _ source: InstalledSkill.Source, plugin: String? = nil,
                 version: String? = nil, project: String? = nil, enabled: Bool? = nil) {
            for folder in Self.children(dir) {
                let file = folder.appendingPathComponent("SKILL.md")
                let id = file.resolvingSymlinksInPath().path
                guard !seen.contains(id), let skill = Self.read(file, id: id, vendor: vendor, source: source, plugin: plugin,
                                                               version: version, project: project, enabled: enabled) else { continue }
                seen.insert(id)
                found.append(skill)
            }
        }
        let claude = home.appendingPathComponent(".claude"), codex = home.appendingPathComponent(".codex")
        add(claude.appendingPathComponent("skills"), .claude, .user)
        for p in claudePlugins() {
            add(URL(fileURLWithPath: p.path).appendingPathComponent("skills"), .claude, .plugin,
                plugin: p.name, version: p.version, enabled: p.enabled)
        }
        add(codex.appendingPathComponent("skills"), .codex, .user)
        add(home.appendingPathComponent(".agents/skills"), .codex, .user)
        add(codex.appendingPathComponent("skills/.system"), .codex, .system)
        for p in codexPlugins() {
            add(p.path.appendingPathComponent("skills"), .codex, .plugin, plugin: p.name, version: p.version, enabled: p.enabled)
        }
        let roots = Set((projects + knownProjects()).compactMap { cwd in
            Self.repositoryRoot(cwd) ?? (FileManager.default.fileExists(atPath: cwd) ? URL(fileURLWithPath: cwd).standardizedFileURL.path : nil)
        })
        for root in roots.sorted() where root != home.path {
            let r = URL(fileURLWithPath: root)
            add(r.appendingPathComponent(".claude/skills"), .claude, .project, project: root)
            add(r.appendingPathComponent(".agents/skills"), .codex, .project, project: root)
            add(r.appendingPathComponent(".codex/skills"), .codex, .project, project: root)
        }
        let order: [InstalledSkill.Source] = [.user, .project, .plugin, .system]
        return found.sorted { a, b in
            if a.vendor != b.vendor { return a.vendor == .claude }
            if a.source != b.source { return order.firstIndex(of: a.source)! < order.firstIndex(of: b.source)! }
            if a.plugin != b.plugin { return (a.plugin ?? "") < (b.plugin ?? "") }
            if a.project != b.project { return (a.project ?? "") < (b.project ?? "") }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// Folders Claude Code (`projects` in `~/.claude.json`) and Codex (`[projects."…"]` in `config.toml`) have worked in.
    func knownProjects() -> [String] {
        var result: [String] = []
        if let data = try? Data(contentsOf: home.appendingPathComponent(".claude.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let projects = json["projects"] as? [String: Any] {
            result += projects.keys
        }
        let toml = (try? String(contentsOf: home.appendingPathComponent(".codex/config.toml"), encoding: .utf8)) ?? ""
        for raw in toml.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("[projects.\""), let close = line.range(of: "\"]", options: .backwards) else { continue }
            result.append(String(line[line.index(line.startIndex, offsetBy: 11)..<close.lowerBound]))
        }
        return result.filter { $0.hasPrefix("/") }
    }

    // MARK: plugins

    /// `~/.claude/plugins/installed_plugins.json`, switched on or off by `enabledPlugins` in `~/.claude/settings.json`.
    func claudePlugins() -> [(name: String, version: String?, path: String, enabled: Bool?)] {
        let base = home.appendingPathComponent(".claude")
        guard let data = try? Data(contentsOf: base.appendingPathComponent("plugins/installed_plugins.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plugins = json["plugins"] as? [String: Any] else { return [] }
        let settings = (try? Data(contentsOf: base.appendingPathComponent("settings.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let switches = settings?["enabledPlugins"] as? [String: Bool] ?? [:]
        var result: [(String, String?, String, Bool?)] = []
        var paths = Set<String>()
        for key in plugins.keys.sorted() {
            let entries = plugins[key] as? [[String: Any]] ?? []
            for e in entries {
                guard let path = e["installPath"] as? String, paths.insert(path).inserted else { continue }
                let name = key.split(separator: "@").first.map(String.init) ?? key
                result.append((name, e["version"] as? String, path, switches[key]))
            }
        }
        return result
    }

    /// `~/.codex/plugins/cache/<marketplace>/<plugin>/<version>`, the newest version of each, switched by `config.toml`.
    func codexPlugins() -> [(name: String, version: String?, path: URL, enabled: Bool?)] {
        let base = home.appendingPathComponent(".codex")
        let config = (try? String(contentsOf: base.appendingPathComponent("config.toml"), encoding: .utf8)) ?? ""
        let switches = Self.codexSwitches(config)
        var result: [(String, String?, URL, Bool?)] = []
        for market in Self.children(base.appendingPathComponent("plugins/cache")) {
            for plugin in Self.children(market) {
                let versions = Self.children(plugin).sorted {
                    $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending
                }
                guard let newest = versions.first else { continue }
                let key = plugin.lastPathComponent + "@" + market.lastPathComponent
                result.append((plugin.lastPathComponent, newest.lastPathComponent, newest, switches[key]))
            }
        }
        return result
    }

    /// `[plugins."name@market"]` tables and their `enabled = true|false`.
    static func codexSwitches(_ toml: String) -> [String: Bool] {
        var result: [String: Bool] = [:]
        var table: String?
        for raw in toml.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                table = nil
                if line.hasPrefix("[plugins.\""), let close = line.range(of: "\"]", options: .backwards) {
                    table = String(line[line.index(line.startIndex, offsetBy: 10)..<close.lowerBound])
                }
            } else if let table, line.hasPrefix("enabled") {
                let value = line.split(separator: "=").last?.trimmingCharacters(in: .whitespaces)
                if value == "true" { result[table] = true } else if value == "false" { result[table] = false }
            }
        }
        return result
    }

    // MARK: files

    static func read(_ file: URL, id: String, vendor: Vendor, source: InstalledSkill.Source, plugin: String?,
                     version: String?, project: String?, enabled: Bool?) -> InstalledSkill? {
        guard let data = try? Data(contentsOf: file), data.count < 2 << 20, let text = String(data: data, encoding: .utf8) else { return nil }
        let (fields, body) = SkillFrontMatter.parse(text)
        let folder = file.deletingLastPathComponent()
        let name = fields.first { $0.key == "name" }?.value.nonEmpty ?? folder.lastPathComponent
        let (files, bytes, modified) = stats(folder)
        return InstalledSkill(id: id, name: name, description: fields.first { $0.key == "description" }?.value ?? "",
                              vendor: vendor, source: source, plugin: plugin, pluginVersion: version, project: project,
                              enabled: enabled, fields: fields.filter { $0.key != "name" && $0.key != "description" },
                              body: body, folder: folder.path, files: files, bytes: bytes, modified: modified)
    }

    /// Files, total size and the newest change inside a skill folder; stops counting at 2000 files.
    static func stats(_ folder: URL) -> (Int, Int, Date) {
        var files = 0, bytes = 0, newest = Date.distantPast
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        while let url = walker?.nextObject() as? URL, files < 2000 {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            files += 1
            bytes += v.fileSize ?? 0
            if let d = v.contentModificationDate, d > newest { newest = d }
        }
        return (files, bytes, newest)
    }

    static func children(_ dir: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return items.filter { !$0.lastPathComponent.hasPrefix(".") && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The nearest folder with `.git`, or nil outside a repository. A worktree resolves to its main
    /// repository, so ten worktrees of one project do not list its skills ten times.
    public static func repositoryRoot(_ cwd: String) -> String? {
        var dir = URL(fileURLWithPath: cwd).standardizedFileURL
        while dir.path != "/" && !dir.path.isEmpty {
            let git = dir.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: git.path, isDirectory: &isDir) {
                if !isDir.boolValue, let text = try? String(contentsOf: git, encoding: .utf8),
                   let r = text.range(of: "gitdir:"),
                   let cut = text[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).range(of: "/.git/") {
                    let gitdir = text[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                    return String(gitdir[..<cut.lowerBound])
                }
                return dir.path
            }
            dir.deleteLastPathComponent()
        }
        return nil
    }
}

/// Counts skill calls in Claude Code transcripts. Only lines that mention a skill are decoded,
/// and a file is read again only after it changes, so later scans cost a few changed sessions.
public struct SkillUsageScanner: Sendable {
    struct FileState: Sendable { var size: Int; var modified: Date; var uses: [String: SkillUse] }
    var files: [String: FileState] = [:]

    public init() {}

    public mutating func scan(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String: SkillUse] {
        let root = home.appendingPathComponent(".claude/projects")
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        var live = Set<String>()
        var total: [String: SkillUse] = [:]
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys)
        while let url = walker?.nextObject() as? URL {
            guard url.pathExtension == "jsonl", let v = try? url.resourceValues(forKeys: Set(keys)),
                  let size = v.fileSize, let modified = v.contentModificationDate else { continue }
            live.insert(url.path)
            var state = files[url.path]
            if state?.size != size || state?.modified != modified {
                state = FileState(size: size, modified: modified, uses: Self.read(url))
                files[url.path] = state
            }
            for (name, use) in state?.uses ?? [:] { total[name, default: SkillUse()].add(use) }
        }
        files = files.filter { live.contains($0.key) }
        return total
    }

    static let markers = [Data("\"Skill\"".utf8), Data("<command-name>/".utf8)]

    static func read(_ url: URL) -> [String: SkillUse] {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return [:] }
        return uses(in: data)
    }

    /// Finds marker bytes first and decodes only the lines around them.
    public static func uses(in data: Data) -> [String: SkillUse] {
        var lines = Set<Range<Int>>()
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress, raw.count > 0 else { return }
            for marker in markers {
                marker.withUnsafeBytes { m in
                    var offset = 0
                    while offset < raw.count,
                          let hit = memmem(base + offset, raw.count - offset, m.baseAddress!, m.count) {
                        let at = base.distance(to: UnsafeRawPointer(hit))
                        var start = at, end = at
                        while start > 0 && raw[start - 1] != 0x0A { start -= 1 }
                        while end < raw.count && raw[end] != 0x0A { end += 1 }
                        lines.insert(start..<end)
                        offset = end + 1
                    }
                }
            }
        }
        var result: [String: SkillUse] = [:]
        for range in lines {
            guard let line = String(data: data.subdata(in: range), encoding: .utf8) else { continue }
            for name in names(in: line) { result[name, default: SkillUse()].add(SkillUse(count: 1, last: timestamp(line))) }
        }
        return result
    }

    /// Skill tool calls and typed slash commands in one transcript line.
    static func names(in line: String) -> [String] {
        guard let json = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              let message = json["message"] as? [String: Any] else { return [] }
        var names: [String] = []
        if let parts = message["content"] as? [[String: Any]] {
            for p in parts where p["type"] as? String == "tool_use" && p["name"] as? String == "Skill" {
                if let skill = (p["input"] as? [String: Any])?["skill"] as? String { names.append(skill) }
            }
        }
        if json["type"] as? String == "user" {
            let text = (message["content"] as? String)
                ?? (message["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: "\n") ?? ""
            var rest = text[...]
            while let open = rest.range(of: "<command-name>/"), let close = rest[open.upperBound...].range(of: "</command-name>") {
                names.append(String(rest[open.upperBound..<close.lowerBound]))
                rest = rest[close.upperBound...]
            }
        }
        return names
    }

    static func timestamp(_ line: String) -> Date? {
        guard let r = line.range(of: "\"timestamp\":\""), let end = line[r.upperBound...].firstIndex(of: "\"") else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let s = String(line[r.upperBound..<end])
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
