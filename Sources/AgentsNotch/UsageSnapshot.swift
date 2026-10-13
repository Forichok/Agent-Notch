import SwiftUI
import NotchCore

private enum UsageSnapshotText {
    static let project = "Agents Notch"
    static var otherProject: String { Loc.t("Another project", "Другой проект") }
    static var analyse: String { Loc.t("Explore the project", "Разобрать проект") }
    static var build: String { Loc.t("Check the build", "Проверить сборку") }
    static var review: String { Loc.t("Review the changes", "Проверить изменения") }
    static var shortWindow: String { Loc.t("5 h", "5 ч") }
    static var week: String { Loc.t("week", "неделя") }
}

/// Deterministic usage data lets the lead inspect all thresholds without reading personal logs.
@MainActor
struct UsageSnapshot: View {
    @StateObject private var usage: UsageModel
    private let agents: [Agent]

    init() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let agents = [
            Agent(id: "usage-grey", vendor: .claude, title: UsageSnapshotText.analyse, model: "claude-sonnet-4", state: .working, project: UsageSnapshotText.project),
            Agent(id: "usage-amber", vendor: .codex, title: UsageSnapshotText.build, model: "gpt-6.1-sol", state: .working, project: UsageSnapshotText.project),
            Agent(id: "usage-red", vendor: .claude, title: UsageSnapshotText.review, model: "claude-opus-4", state: .working, project: UsageSnapshotText.project)
        ]
        let usage = UsageModel()
        usage.useFixture(limits: [
            VendorLimits(vendor: .claude, windows: [
                NotchCore.LimitWindow(label: UsageSnapshotText.shortWindow, usedPercent: 42),
                NotchCore.LimitWindow(label: UsageSnapshotText.week, usedPercent: 81, resetsAt: now.addingTimeInterval(172800))
            ], updatedAt: now),
            VendorLimits(vendor: .codex, windows: [
                NotchCore.LimitWindow(label: UsageSnapshotText.shortWindow, usedPercent: 96, resetsAt: now.addingTimeInterval(7200)),
                NotchCore.LimitWindow(label: UsageSnapshotText.week, usedPercent: 63, resetsAt: now.addingTimeInterval(86400))
            ], updatedAt: now)
        ], spend: [ProjectSpend(project: UsageSnapshotText.project, tokens: 120_000, usd: 3.42),
                   ProjectSpend(project: UsageSnapshotText.otherProject, tokens: 40_000, usd: nil)], contexts: [
            agents[0].id: ContextUsage(usedTokens: 630_000, windowTokens: 1_000_000),
            agents[1].id: ContextUsage(usedTokens: 150_000, windowTokens: 200_000),
            agents[2].id: ContextUsage(usedTokens: 190_000, windowTokens: 200_000)
        ], now: now)
        usage.selectedVendor = .codex
        _usage = StateObject(wrappedValue: usage)
        self.agents = agents
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LimitChips(usage: usage, mode: .always).padding(.horizontal, 12)
            UsageInline(usage: usage)
            ForEach(agents) { agent in
                HStack(spacing: 7) {
                    MarkView(agent, size: 7)
                    Text(agent.title)
                    Spacer()
                    ContextRing(usage: usage, agent: agent)
                    Text(agent.shortModel ?? "").foregroundStyle(dim)
                }.padding(.horizontal, 12)
            }
        }
        .font(.system(size: 12)).padding(.vertical, 12)
        .frame(width: 380)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.11)))
        .environment(\.colorScheme, .dark)
    }
}
