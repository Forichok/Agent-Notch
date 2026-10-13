import Foundation

enum ToolText {


    /// The approved thing in full: the command (an argv joined by spaces), else the path or URL.
    static func full(_ input: Any?) -> String? {
        let i = input as? Rec ?? [:]
        let text = i["command"] as? String ?? (i["command"] as? [String])?.joined(separator: " ")
            ?? i["file_path"] as? String ?? i["notebook_path"] as? String ?? i["path"] as? String ?? i["url"] as? String
        return text.map { String($0.prefix(4000)) }
    }

    static func join(_ name: String, _ detail: String?) -> String {
        detail.map { "\(name) · \($0)" } ?? name
    }

    static func summary(_ tool: String, _ input: Any?) -> String {
        join(name(tool), detail(tool, input))
    }

    /// A Codex tool call from a `response_item`: `function_call` with JSON arguments,
    /// or `custom_tool_call` whose input is code like `tools.exec_command({cmd:"…"})`.
    static func codexCall(_ p: Rec) -> String? {
        guard let kind = p["type"] as? String, kind.hasSuffix("_call"), let name = p["name"] as? String ?? (kind == "local_shell_call" ? "shell" : nil)
        else { return nil }
        let raw = p["arguments"] as? String ?? p["input"] as? String ?? ""
        if let data = raw.data(using: .utf8), let args = try? JSONSerialization.jsonObject(with: data) as? Rec {
            return summary(name, ["command": args["cmd"] ?? args["command"] as Any, "path": args["path"] as Any].compactMapValues { $0 is NSNull ? nil : $0 })
        }
        if let cmd = raw.firstMatch(#"cmd"?\s*:\s*"((?:[^"\\]|\\.)*)""#) {
            return join("shell", command(cmd.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\n", with: "\n")))
        }
        if name == "apply_patch" || raw.contains("*** Begin Patch") { return join("patch", detail("apply_patch", ["input": raw])) }
        return name == "exec" ? nil : name
    }

    /// First line of a shell command without a leading `cd <dir> &&`, which says nothing new.
    static func command(_ cmd: String) -> String? {
        let bare = cmd.replacingOccurrences(of: #"^\s*cd\s+("[^"]*"|'[^']*'|\S+)\s*(&&|;)\s*"#, with: "", options: .regularExpression)
        return LogText.clip(bare, 120)
    }

    static func name(_ tool: String) -> String {
        if tool.hasPrefix("mcp__") {
            let parts = tool.split(separator: "_", omittingEmptySubsequences: true)
            return parts.dropFirst().joined(separator: " ")
        }
        return tool
    }

    static func detail(_ tool: String, _ input: Any?) -> String? {
        let i = input as? Rec ?? [:]
        if tool == "AskUserQuestion", let q = Question.parse(input).first { return LogText.clip(q.question, 80) }
        if tool == "ExitPlanMode" { return Loc.t("plan", "план") }
        if let cmd = i["command"] as? String ?? (i["command"] as? [String])?.last { return command(cmd) }
        if let path = i["file_path"] as? String ?? i["notebook_path"] as? String ?? i["path"] as? String {
            return URL(fileURLWithPath: path).pathComponents.suffix(2).joined(separator: "/")
        }
        if let url = i["url"] as? String { return LogText.clip(url, 80) }
        if let q = i["query"] as? String ?? i["pattern"] as? String ?? i["description"] as? String { return LogText.clip(q, 80) }
        if tool == "apply_patch", let patch = i["input"] as? String ?? i["patch"] as? String {
            let files = patch.split(separator: "\n").filter { $0.hasPrefix("*** ") && $0.contains(" File: ") }
            return files.map { String($0.split(separator: ":").last ?? "").trimmingCharacters(in: .whitespaces) }
                .joined(separator: ", ").nilIfEmpty
        }
        return nil
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }

    /// The first capture group of `pattern`.
    func firstMatch(_ pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: self, range: NSRange(startIndex..., in: self)), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: self) else { return nil }
        return String(self[r])
    }
}
