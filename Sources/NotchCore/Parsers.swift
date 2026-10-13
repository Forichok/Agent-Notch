import Foundation

/// Claude Code: ~/.claude/projects/<encoded-cwd>/<session>.jsonl, subagents in <session>/subagents/agent-<id>.jsonl.
enum ClaudeLine {
    /// Tools that stop and wait for the human by design.
    static var asking: [String: String] { ["AskUserQuestion": Loc.t("question", "вопрос"), "ExitPlanMode": Loc.t("approve plan", "согласовать план")] }

    static func apply(_ r: Rec, to s: inout SessionLog, isSubagent: Bool) {
        if r["isSidechain"] as? Bool == true && !isSubagent { return }
        if let cwd = r["cwd"] as? String { s.cwd = cwd }
        if let b = r["gitBranch"] as? String, !b.isEmpty { s.branch = b }
        let at = LogText.time(r["timestamp"])
        switch r["type"] as? String {
        case "custom-title": s.customTitle = r["customTitle"] as? String
        case "agent-name": s.customTitle = s.customTitle ?? r["agentName"] as? String
        case "last-prompt": s.prompt = LogText.clip(r["lastPrompt"] as? String) ?? s.prompt
        case "system":
            s.touch(at)
            if r["subtype"] as? String == "api_error" { s.errorStreak += 1 }
        case "assistant":
            s.touch(at)
            assistant(r, &s)
        case "user":
            s.touch(at)
            user(r, &s)
        default: break
        }
    }

    private static func assistant(_ r: Rec, _ s: inout SessionLog) {
        let msg = r["message"] as? Rec ?? [:]
        if let m = msg["model"] as? String, m != "<synthetic>" { s.model = m }
        if let e = Effort(r["effort"] as? String) { s.effort = e }
        var handedBack = false
        for block in msg["content"] as? [Rec] ?? [] where block["type"] as? String == "tool_use" {
            let name = block["name"] as? String ?? "tool"
            // A subagent's last act: its report goes back to the parent and it stops.
            if name == "SubagentHandback" { handedBack = true; continue }
            if let id = block["id"] as? String { s.pendingTools[id] = name }
            if let what = asking[name] { s.ask = what } else { s.activity = ToolText.summary(name, block["input"]) }
        }
        s.turnEnded = handedBack || msg["stop_reason"] as? String == "end_turn"
        if handedBack { s.activity = nil }
    }

    private static func user(_ r: Rec, _ s: inout SessionLog) {
        if r["isMeta"] as? Bool == true { return }
        let content = (r["message"] as? Rec)?["content"]
        if content is String {
            s.turnEnded = false
            return
        }
        for block in content as? [Rec] ?? [] {
            if block["type"] as? String == "tool_result" {
                let name = s.toolResult(id: block["tool_use_id"] as? String, isError: block["is_error"] as? Bool == true)
                if let name, asking[name] != nil { s.ask = nil }
            } else if block["type"] as? String == "text" {
                s.turnEnded = false
            }
        }
    }

    /// Subagent title from its .meta.json: the description the parent gave it, else its type.
    static func subagentTitle(meta: Data?) -> String? {
        guard let meta, let r = try? JSONSerialization.jsonObject(with: meta) as? Rec else { return nil }
        return LogText.clip(r["description"] as? String) ?? r["agentType"] as? String
    }
}

/// Codex: ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl, one per thread; a subagent names its parent thread.
enum CodexLine {
    static let approvals: Set<String> = ["exec_approval_request", "apply_patch_approval_request", "request_user_input"]
    /// Lines that are bookkeeping, not a sign that the agent moved on.
    static let quiet: Set<String> = ["token_count"]

    static func apply(_ r: Rec, to s: inout SessionLog) {
        let p = r["payload"] as? Rec ?? [:]
        let at = LogText.time(r["timestamp"])
        switch r["type"] as? String {
        case "session_meta":
            meta(p, &s)
            s.startedAt = LogText.time(p["timestamp"]) ?? at
            s.touch(at)
        case "turn_context":
            if let m = p["model"] as? String { s.model = m }
            if let e = Effort(p["effort"] as? String) { s.effort = e }
            if let cwd = p["cwd"] as? String { s.cwd = cwd }
        case "event_msg":
            event(p, at, &s)
        case "response_item":
            s.touch(at)
            s.ask = nil
            if let call = ToolText.codexCall(p) { s.activity = call }
        default: break
        }
    }

    private static func meta(_ p: Rec, _ s: inout SessionLog) {
        if let id = p["id"] as? String ?? p["session_id"] as? String { s.id = id }
        if let cwd = p["cwd"] as? String { s.cwd = cwd }
        if let b = (p["git"] as? Rec)?["branch"] as? String { s.branch = b }
        guard let sub = (p["source"] as? Rec)?["subagent"] as? Rec else { return }
        if sub["other"] as? String == "guardian" { s.hidden = true }
        let spawn = sub["thread_spawn"] as? Rec
        s.parentId = p["parent_thread_id"] as? String ?? spawn?["parent_thread_id"] as? String
        let path = p["agent_path"] as? String ?? spawn?["agent_path"] as? String
        let nick = p["agent_nickname"] as? String ?? spawn?["agent_nickname"] as? String
        s.subTitle = path?.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? nick
            ?? spawn?["agent_role"] as? String
    }

    private static func event(_ p: Rec, _ at: Double?, _ s: inout SessionLog) {
        let t = p["type"] as? String ?? ""
        if quiet.contains(t) { return }
        s.touch(at)
        if approvals.contains(t) {
            let cmd = (p["command"] as? [String])?.last ?? p["command"] as? String
            s.ask = cmd.flatMap { LogText.clip($0, 60) } ?? Loc.t("approval", "подтверждение")
            return
        }
        s.ask = nil
        switch t {
        case "task_started", "user_message": s.turnEnded = false
        case "task_complete", "turn_aborted":
            s.turnEnded = true
            s.activity = nil
        case "error", "stream_error": s.errorStreak += 1
        case "exec_command_end":
            if let code = p["exit_code"] as? Int { s.errorStreak = code == 0 ? 0 : s.errorStreak + 1 }
        default: break
        }
        if t == "user_message", let text = p["message"] as? String { s.prompt = LogText.clip(text) ?? s.prompt }
    }
}
