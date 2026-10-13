import Foundation

public struct QuestionOption: Equatable, Sendable {
    public var label: String
    public var description: String
}

/// One question of Claude's AskUserQuestion tool.
public struct Question: Equatable, Sendable, Identifiable {
    public var question: String
    public var header: String
    public var options: [QuestionOption]
    public var multiSelect: Bool
    public var id: String { question }

    /// The `questions` array of a tool input. Questions without text or options are dropped.
    static func parse(_ input: Any?) -> [Question] {
        let list = (input as? Rec)?["questions"] as? [Any] ?? []
        return list.compactMap { item in
            guard let q = item as? Rec, let text = q["question"] as? String, !text.isEmpty,
                  let raw = q["options"] as? [Any] else { return nil }
            let options = raw.compactMap { o -> QuestionOption? in
                guard let o = o as? Rec, let label = o["label"] as? String, !label.isEmpty else { return nil }
                return QuestionOption(label: label, description: o["description"] as? String ?? "")
            }
            guard !options.isEmpty else { return nil }
            return Question(question: text, header: q["header"] as? String ?? "", options: options,
                            multiSelect: q["multiSelect"] as? Bool ?? false)
        }
    }
}

public extension HookDecision {
    /// Claude's answers to its questions: the original tool input plus `answers` (question text → label;
    /// several labels of a multi-select joined by ", "). Nil when the event holds no question.
    static func answer(_ e: HookEvent, _ answers: [String: String]) -> HookDecision? {
        guard e.isQuestion, var input = e.inputObject else { return nil }
        input["answers"] = answers
        return json(input).map { .allowWith(input: $0) }
    }

    /// The plan accepted as it is. Nil when the event holds no plan.
    static func approvePlan(_ e: HookEvent) -> HookDecision? {
        guard e.isPlan, let input = e.toolInput else { return nil }
        return .allowWith(input: input)
    }

    /// The plan sent back: Claude gets the comment as the reason and revises.
    static func returnPlan(feedback: String) -> HookDecision {
        .denyWith(message: Loc.t("Plan sent back from Agents Notch with a comment: \(feedback)", "План возвращён в Agents Notch с комментарием: \(feedback)"))
    }

    /// Short name for the audit log.
    var name: String {
        switch self {
        case .allow, .allowWith: return "allow"
        case .allowAlways: return "always"
        case .deny, .denyWith: return "deny"
        case .pass: return "pass"
        }
    }

    /// The decision as one socket line (without the newline).
    var wire: Data {
        var o: Rec = ["decision": name == "always" ? "allow" : name]
        if case .allowAlways(let rule) = self { o["always"] = rule.wire }
        if case .allowWith(let input) = self, let obj = Self.object(input) { o["updatedInput"] = obj }
        if case .denyWith(let m) = self { o["message"] = m }
        return (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data(#"{"decision":"pass"}"#.utf8)
    }

    init?(wire r: Rec) {
        switch r["decision"] as? String {
        case "allow":
            if r.keys.contains("always") {
                guard let rule = (r["always"] as? Rec).flatMap(AlwaysRule.Suggestion.init(wire:)) else { return nil }
                self = .allowAlways(rule)
            } else if let obj = r["updatedInput"] as? Rec, let s = Self.json(obj) { self = .allowWith(input: s) } else { self = .allow }
        case "deny":
            if let m = r["message"] as? String { self = .denyWith(message: m) } else { self = .deny }
        case "pass": self = .pass
        default: return nil
        }
    }

    static func json(_ o: Rec) -> String? {
        (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func object(_ s: String) -> Rec? {
        try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? Rec
    }
}
