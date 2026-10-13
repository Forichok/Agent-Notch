import Foundation

/// Tools that ask the human something other than yes or no. Claude answers them through PreToolUse
/// (`permissionDecision` + `updatedInput` to answer, `deny` + reason to send a plan back).
public enum AnswerTools {
    public static let names = ["AskUserQuestion", "ExitPlanMode"]
}

extension HookEvent {
    /// The hook holds the call open for a click: a permission request, or the synchronous PreToolUse of a question or plan.
    public var waitsForAnswer: Bool {
        isPermission || (vendor == .claude && name == "PreToolUse" && AnswerTools.names.contains(tool ?? ""))
    }
}

extension HookReply {
    /// The PreToolUse shape. Other tools get nothing: their PreToolUse hook only reports activity.
    static func preToolUse(tool: String?, _ decision: HookDecision) -> String? {
        guard AnswerTools.names.contains(tool ?? "") else { return nil }
        var out: Rec = ["hookEventName": "PreToolUse"]
        switch decision {
        case .pass: return nil
        case .allow, .allowAlways: out["permissionDecision"] = "allow"
        case .allowWith(let input):
            guard let obj = HookDecision.object(input) else { return nil }
            out["permissionDecision"] = "allow"
            out["updatedInput"] = obj
        case .deny:
            out["permissionDecision"] = "deny"
            out["permissionDecisionReason"] = Loc.t("Denied in Agents Notch", "Отклонено в Agents Notch")
        case .denyWith(let message):
            out["permissionDecision"] = "deny"
            out["permissionDecisionReason"] = message
        }
        return HookDecision.json(["hookSpecificOutput": out])
    }

    /// What `notch-hook` prints for this event and decision, whichever hook it came from.
    public static func stdout(event: HookEvent, decision: HookDecision) -> String? {
        if case .allowAlways(let rule) = decision { return stdout(event: event, decision: .allow, rule: rule) }
        return stdout(event: event.name, tool: event.tool, decision: decision)
    }
}

/// A PermissionRequest for a question or plan that follows the PreToolUse the notch already held:
/// the person sent it back to the agent's own window, so the second ask must not appear in the notch again.
public struct AnswerRoute: Sendable {
    private var seen: [String: Double] = [:]
    static let window = 120.0

    public init() {}

    private static func key(_ e: HookEvent) -> String { e.agentKey + "|" + (e.tool ?? "") }

    /// A PreToolUse for a question or plan reached the notch with a ticket.
    public mutating func noteRouted(_ e: HookEvent, now: Double) {
        guard e.name == "PreToolUse", e.waitsForAnswer else { return }
        seen = seen.filter { now - $0.value < Self.window }
        seen[Self.key(e)] = now
    }

    /// True once for a PermissionRequest that belongs to a call the notch already had.
    public mutating func isHandedBack(_ e: HookEvent, now: Double) -> Bool {
        guard e.isPermission, AnswerTools.names.contains(e.tool ?? ""),
              let at = seen.removeValue(forKey: Self.key(e)) else { return false }
        return now - at < Self.window
    }
}
