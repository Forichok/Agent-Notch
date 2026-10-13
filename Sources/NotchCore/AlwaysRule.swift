import Foundation

/// A standing approval is suggested only when its scope can be shown without shell parsing.
public enum AlwaysRule {
    public struct Suggestion: Sendable, Equatable {
        public let label: String
        public let toolName: String
        public let ruleContent: String?
        /// Literal argv prefix; nil for tools that do not run commands.
        public let prefix: [String]?
    }

    public static func suggest(for event: HookEvent) -> Suggestion? {
        guard event.vendor == .claude, event.isPermission, !event.isRisky, let tool = event.tool else { return nil }
        let content: String?, scope: String, prefix: [String]?
        switch tool {
        case "Bash":
            guard let command = event.full, let words = commandPrefix(command) else { return nil }
            prefix = words
            let text = words.joined(separator: " ")
            content = text + ":*"
            scope = text + " *"
        case "WebFetch":
            guard let raw = event.full, raw.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
                  let url = URLComponents(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  let host = url.host?.lowercased(), !host.isEmpty,
                  host.range(of: #"^[a-z0-9.:-]+$"#, options: .regularExpression) != nil,
                  !host.hasPrefix(".") else { return nil }
            content = "domain:" + host
            scope = host
            prefix = nil
        default:
            guard tool.range(of: #"^mcp__[A-Za-z0-9_-]+__[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else { return nil }
            content = nil
            scope = tool
            prefix = nil
        }
        let project = ProjectNames().name(for: event.cwd)
        return Suggestion(label: Text.label(scope, project), toolName: tool, ruleContent: content, prefix: prefix)
    }

    private static let subcommands: Set<String> = ["git", "pnpm", "npm", "yarn", "cargo", "go", "swift", "docker", "kubectl"]
    private static let wrappers: Set<String> = ["sudo", "env", "bash", "sh", "zsh", "fish", "eval", "exec", "command", "xargs"]

    private static func commandPrefix(_ command: String) -> [String]? {
        // full is capped at 4000 by HookEvent; a capped command could hide another command.
        guard command.count < 4000,
              command.rangeOfCharacter(from: CharacterSet(charactersIn: ";&|$`()<>\\\n\r")) == nil else { return nil }
        let words = command.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let first = words.first, validWord(first), !first.hasPrefix("-") else { return nil }
        let program = URL(fileURLWithPath: first).lastPathComponent
        guard !wrappers.contains(program) else { return nil }
        let count = subcommands.contains(program) ? 2 : 1
        guard words.count >= count else { return nil }
        let prefix = Array(words.prefix(count))
        guard prefix.allSatisfy({ validWord($0) && !$0.hasPrefix("-") }) else { return nil }
        return prefix
    }

    private static func validWord(_ word: String) -> Bool {
        word.range(of: #"^[A-Za-z0-9_./:-]+$"#, options: .regularExpression) != nil
    }

    private enum Text {
        static func label(_ scope: String, _ project: String) -> String { Loc.t("Always `\(scope)` in \(project)", "Всегда `\(scope)` в \(project)") }
    }
}

extension AlwaysRule.Suggestion {
    /// The rule as it crosses the socket between the app and `notch-hook`.
    var wire: Rec {
        var o: Rec = ["label": label, "toolName": toolName]
        if let ruleContent { o["ruleContent"] = ruleContent }
        if let prefix { o["prefix"] = prefix }
        return o
    }

    init?(wire r: Rec) {
        guard let label = r["label"] as? String, let tool = r["toolName"] as? String,
              !r.keys.contains("ruleContent") || r["ruleContent"] is String,
              !r.keys.contains("prefix") || r["prefix"] is [String] else { return nil }
        self.init(label: label, toolName: tool, ruleContent: r["ruleContent"] as? String, prefix: r["prefix"] as? [String])
    }
}
