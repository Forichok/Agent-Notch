import Foundation

/// One hook call from Claude Code or Codex, as `notch-hook` forwards it: what happened, in which session, to which tool.
public struct HookEvent: Sendable, Equatable {
    public var vendor: Vendor
    public var name: String
    public var sessionId: String
    /// Claude subagent id, when the hook fired inside one.
    public var agentId: String?
    public var cwd: String?
    public var tool: String?
    /// One line about the tool call: the command, the file, the URL.
    public var detail: String?
    /// The whole command, path or URL being approved, up to 4000 characters: what the person must be able to read.
    public var full: String?
    public var notificationType: String?
    public var message: String?
    /// AskUserQuestion: the questions with their options.
    public var questions: [Question] = []
    /// ExitPlanMode: the plan text.
    public var plan: String?
    /// The tool input as JSON, kept only for a question or a plan: the reply sends it back with the answer.
    public var toolInput: String?

    /// The id LogScanner gives the agent this event belongs to.
    public var agentKey: String { agentId.map { "\(sessionId)/\($0)" } ?? sessionId }

    /// The agent stopped and waits for a permission decision.
    public var isPermission: Bool { name == "PermissionRequest" }
    /// Claude's own prompt is on screen (fires a few seconds after the dialog appears).
    public var isPromptShown: Bool {
        name == "Notification" && ["permission_prompt", "elicitation_dialog", "agent_needs_input"].contains(notificationType ?? "")
    }
    /// A question the notch can show with its options (Claude only: Codex documents no such hook).
    public var isQuestion: Bool { vendor == .claude && tool == "AskUserQuestion" && !questions.isEmpty && toolInput != nil }
    /// A plan the notch can show for acceptance.
    public var isPlan: Bool { vendor == .claude && tool == "ExitPlanMode" && plan?.isEmpty == false && toolInput != nil }
    /// Tools that ask the human something other than yes or no, when the notch cannot show them: the decision stays in the agent's own UI.
    public var answeredElsewhere: Bool { ["AskUserQuestion", "ExitPlanMode"].contains(tool ?? "") && !isQuestion && !isPlan }
    /// The tool input as an object, for building the reply.
    var inputObject: Rec? { toolInput.flatMap(HookDecision.object) }

    /// What the agent waits for, in the list row.
    public var askLine: String {
        if isQuestion { return Loc.t("question: ", "вопрос: ") + (LogText.clip(questions[0].question, 60) ?? "") }
        if isPlan { return Loc.t("approve plan", "принять план") }
        return Loc.t("allow: ", "разрешить: ") + summary
    }

    public init(vendor: Vendor, name: String, sessionId: String, agentId: String? = nil, cwd: String? = nil,
                tool: String? = nil, detail: String? = nil, full: String? = nil, notificationType: String? = nil, message: String? = nil,
                questions: [Question] = [], plan: String? = nil, toolInput: String? = nil) {
        self.vendor = vendor; self.name = name; self.sessionId = sessionId; self.agentId = agentId; self.cwd = cwd
        self.tool = tool; self.detail = detail; self.full = full ?? detail
        self.notificationType = notificationType; self.message = message
        self.questions = questions; self.plan = plan; self.toolInput = toolInput
    }

    /// Parses the hook's stdin JSON. Nil when it names no session.
    public init?(vendor: Vendor, payload p: Rec) {
        guard let session = p["session_id"] as? String, !session.isEmpty, let name = p["hook_event_name"] as? String else { return nil }
        let tool = p["tool_name"] as? String
        let input = p["tool_input"]
        let interactive = tool == "AskUserQuestion" || tool == "ExitPlanMode"
        self.init(vendor: vendor, name: name, sessionId: session, agentId: p["agent_id"] as? String, cwd: p["cwd"] as? String,
                  tool: tool, detail: tool.flatMap { ToolText.detail($0, input) }, full: ToolText.full(input),
                  notificationType: p["notification_type"] as? String, message: p["message"] as? String,
                  questions: tool == "AskUserQuestion" ? Question.parse(input) : [],
                  plan: tool == "ExitPlanMode" ? (input as? Rec)?["plan"] as? String : nil,
                  toolInput: interactive ? (input as? Rec).flatMap(HookDecision.json) : nil)
    }

    /// "Bash · pnpm test", "Edit · src/app.ts".
    public var summary: String {
        ToolText.join(tool.map(ToolText.name) ?? Loc.t("action", "действие"), detail)
    }

    /// Commands that are hard to undo. Checked on the whole command, not the shown line.
    public var isRisky: Bool {
        guard !isQuestion, !isPlan, let d = (full ?? detail)?.lowercased() else { return false }
        return RiskyCommand.contains(d)
    }

    /// The one line shown is not all of it: more lines, or longer than fits.
    public var isLong: Bool {
        guard let full else { return false }
        return full.contains("\n") || full.count > 120
    }

    /// Only a click may allow it: risky, too long to read at a glance, or nothing to read at all. Hotkeys never allow these.
    public var needsClick: Bool { isQuestion || isPlan || isRisky || isLong || full == nil }
}

public enum HookDecision: Equatable, Sendable {
    case allow, deny
    /// No decision: the agent asks in its own window as if the notch were not there.
    case pass
    /// Allow with the tool input replaced (JSON object): how a question gets its answers. Built only from a click.
    case allowWith(input: String)
    /// Deny with a reason the agent reads: how a plan goes back with a comment.
    case denyWith(message: String)
    /// Allow and remember the rule the button showed. Claude gets it as updatedPermissions; Codex gets a plain allow and the app writes the rule.
    case allowAlways(AlwaysRule.Suggestion)
}

/// What `notch-hook` prints back to the agent. Only a human click ever produces an allow.
public enum HookReply {
    public static func stdout(event: String, decision: HookDecision) -> String? {
        stdout(event: event, tool: nil, decision: decision)
    }

    /// `tool` picks the shape for PreToolUse, which is answered only for the tools that ask a human (see `AnswerTools`).
    public static func stdout(event: String, tool: String?, decision: HookDecision) -> String? {
        if event == "PreToolUse" { return preToolUse(tool: tool, decision) }
        guard event == "PermissionRequest" else { return nil }
        let inner: String
        switch decision {
        case .allow, .allowAlways: inner = #"{"behavior":"allow"}"#
        case .deny: inner = Loc.isRussian ? #"{"behavior":"deny","message":"Отклонено в Agents Notch"}"#
            : #"{"behavior":"deny","message":"Denied in Agents Notch"}"#
        case .pass: return nil
        case .allowWith(let input):
            guard let obj = HookDecision.object(input),
                  let text = HookDecision.json(["behavior": "allow", "updatedInput": obj]) else { return nil }
            inner = text
        case .denyWith(let message):
            guard let text = HookDecision.json(["behavior": "deny", "message": message]) else { return nil }
            inner = text
        }
        return #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":"# + inner + "}}"
    }
}
