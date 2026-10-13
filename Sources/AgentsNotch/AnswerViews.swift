import SwiftUI
import NotchCore

/// All user-facing text of the answer rows, in one place.
private enum AnswerText {
    static var answer: String { Loc.t("Answer", "Ответить") }
    static var own: String { Loc.t("Your own answer…", "Свой ответ…") }
    static var ownHint: String { Loc.t("Your answer", "Ваш ответ") }
    static var inAgent: String { Loc.t("In the agent window", "В окне агента") }
    static var accept: String { Loc.t("Approve", "Принять") }
    static var comment: String { Loc.t("Send back with a comment…", "Вернуть с комментарием…") }
    static var commentHint: String { Loc.t("What to change in the plan", "Что поправить в плане") }
    static var send: String { Loc.t("Send back", "Вернуть") }
    static var plan: String { Loc.t("Plan", "План") }
    static var always: String { Loc.t("Always", "Всегда") }
}

/// A question of the agent with its options as buttons. One single-choice question answers on the click;
/// several questions or a multi-select collect the choices first and send them with "Ответить".
struct QuestionChoices: View {
    let ask: PendingAsk
    let store: Store
    @State private var picked: [String: [String]] = [:]
    @State private var own: [String: String] = [:]
    @State private var ownOpen: Set<String> = []

    private var questions: [Question] { ask.event.questions }
    private var instant: Bool { questions.count == 1 && !questions[0].multiSelect }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(questions) { q in block(q) }
            HStack(spacing: 8) {
                if !instant {
                    Button(AnswerText.answer) { send() }.buttonStyle(Pill(primary: true)).disabled(answers() == nil)
                }
                Button(AnswerText.inAgent) { store.decide(ask, .pass) }
                    .buttonStyle(.plain).foregroundStyle(dim).font(.system(size: 11))
            }
        }
        .padding(.top, 2)
    }

    @ViewBuilder private func block(_ q: Question) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(q.header.isEmpty ? q.question : "\(q.header) · \(q.question)")
                .foregroundStyle(Color(white: 0.92)).fixedSize(horizontal: false, vertical: true)
            ForEach(q.options, id: \.label) { o in
                let on = picked[q.question]?.contains(o.label) == true
                Button { choose(q, o.label) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(q.multiSelect ? (on ? "☑" : "☐") : (on ? "●" : "○")).foregroundStyle(on ? AgentState.waiting.color : dim)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(o.label).foregroundStyle(.white)
                            if !o.description.isEmpty {
                                Text(o.description).font(.system(size: 10.5)).foregroundStyle(dim)
                                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(white: on ? 0.27 : 0.19)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if ownOpen.contains(q.question) {
                TextField(AnswerText.ownHint, text: Binding(get: { own[q.question] ?? "" }, set: { own[q.question] = $0 }))
                    .textFieldStyle(.roundedBorder).onSubmit { send() }
            } else {
                Button(AnswerText.own) { ownOpen.insert(q.question); picked[q.question] = [] }
                    .buttonStyle(.plain).foregroundStyle(dim)
            }
        }
    }

    private func choose(_ q: Question, _ label: String) {
        ownOpen.remove(q.question)
        var now = picked[q.question] ?? []
        if q.multiSelect {
            if let i = now.firstIndex(of: label) { now.remove(at: i) } else { now.append(label) }
        } else {
            now = [label]
        }
        picked[q.question] = now
        if instant { send() }
    }

    /// Question text → answer, or nil while a question has none. Chosen labels keep the order of the options.
    private func answers() -> [String: String]? {
        QuestionAnswers.build(questions: questions, picked: picked, own: own, ownOpen: ownOpen)
    }

    private func send() {
        if let a = answers() { store.answer(ask, a) }
    }
}

/// The plan the agent wants approved: its text, "Принять", or back with a comment.
struct PlanChoices: View {
    let ask: PendingAsk
    let store: Store
    @State private var commenting = false
    @State private var comment = ""

    private static let maxLines = 14
    private var plan: String { ask.event.plan ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(AnswerText.plan).foregroundStyle(dim)
            let text = Text(plan).font(.system(size: 11)).foregroundStyle(Color(white: 0.92))
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            // Longer than ~14 lines scrolls; a short plan is drawn plainly.
            if plan.split(separator: "\n", omittingEmptySubsequences: false).count > Self.maxLines || plan.count > 900 {
                ScrollView { text.frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 14 * 15)
            } else {
                text
            }
            if commenting {
                TextField(AnswerText.commentHint, text: $comment).textFieldStyle(.roundedBorder).onSubmit { returnPlan() }
            }
            HStack(spacing: 6) {
                Button(AnswerText.accept) { store.approvePlan(ask) }.buttonStyle(Pill(primary: true))
                if commenting {
                    Button(AnswerText.send) { returnPlan() }.buttonStyle(Pill(primary: false))
                        .disabled(comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else {
                    Button(AnswerText.comment) { commenting = true }.buttonStyle(Pill(primary: false))
                }
                Button(AnswerText.inAgent) { store.decide(ask, .pass) }
                    .buttonStyle(.plain).foregroundStyle(dim).font(.system(size: 11)).lineLimit(1)
            }
        }
        .padding(.top, 2)
    }

    private func returnPlan() {
        let text = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { store.returnPlan(ask, feedback: text) }
    }
}

/// "Всегда" next to "Разрешить": only when the request has a rule that can be shown in full and is not risky or click-only.
/// The rule's label is the tooltip. Never bound to a hotkey.
struct AlwaysButton: View {
    let ask: PendingAsk
    let store: Store
    var body: some View {
        if !ask.event.needsClick, let rule = AlwaysRule.suggest(for: ask.event) {
            Button(AnswerText.always) { store.decideAlways(ask) }
                .buttonStyle(Pill(primary: false)).help(rule.label)
        }
    }
}
