import Foundation
import NotchCore

enum CardFixture {
    static let agent = Agent(id: "card-fixture", vendor: .codex, title: CardFixtureText.title,
                             model: "gpt-6.1-sol", effort: .high, state: .working, project: "Agents Notch",
                             cwd: "/tmp/agents-notch", branch: "feat/ui-card", worktree: "ui-card")
    static var detail: AgentDetail {
        AgentDetail(plan: [PlanItem(text: CardFixtureText.completed, status: .done),
                           PlanItem(text: CardFixtureText.active, status: .active),
                           PlanItem(text: CardFixtureText.todo, status: .todo)],
                    files: [FileChange(path: "Sources/AgentsNotch/CardView.swift", added: 96, removed: 3)],
                    commands: [CommandRun(command: "./scripts/build.sh", ok: true),
                               CommandRun(command: "./scripts/test.sh", ok: false),
                               CommandRun(command: "./scripts/test.sh", ok: true)],
                    lastMessage: CardFixtureText.message,
                    errors: [DetailError(text: CardFixtureText.error, count: 2)],
                    meta: DetailMeta(model: "gpt-6.1-sol", effort: .high,
                                     startedAt: Date().timeIntervalSince1970 - 732, branch: "feat/ui-card", worktree: "ui-card"))
    }
}

private enum CardFixtureText {
    static var title: String { Loc.t("Agent card", "Карточка агента") }
    static var completed: String { Loc.t("Hook up log reading", "Подключить чтение журнала") }
    static var active: String { Loc.t("Check the card tabs", "Проверить вкладки карточки") }
    static var todo: String { Loc.t("Check jumping to the agent window", "Проверить переход в окно агента") }
    static var message: String { Loc.t("The card reads the log in the background. Jumping between windows is left to check.", "Карточка читает журнал в фоне. Осталось проверить переход между окнами.") }
    static var error: String { Loc.t("Check file not found", "Не найден файл проверки") }
}
