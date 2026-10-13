import SwiftUI
import NotchCore

private enum RowPartsText {
    static func branch(_ value: String) -> String { "⎇ " + value }
    static func worktree(_ value: String) -> String { "⌂ " + value }
    static var cost: String { Loc.t("Approximate session cost at public model prices, not a bill", "Примерная цена сессии по публичным ценам моделей, это не счёт") }
}

/// Metadata wraps in saved order; the activity gets its own line at its chosen position.
struct RowParts: View {
    let agent: Agent
    var small = false
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var usage: UsageModel

    var body: some View {
        RowPartsLayout {
            ForEach(settings.visibleRowParts, id: \.self) { part in
                content(part).layoutValue(key: RowActivityLine.self, value: part == .activity)
            }
        }
        .padding(.vertical, 3)
        // One registration per row: the context ring and the cost share the same log read.
        .background {
            if settings.rowPartShown(.context) || settings.rowPartShown(.cost) {
                UsageVisibility(usage: usage, agent: agent).frame(width: 0, height: 0)
                    .onChange(of: agent) { _, next in usage.show(next) }
                    .onDisappear { usage.hide(agent.id) }
            }
        }
    }

    @ViewBuilder private func content(_ part: RowPart) -> some View {
        switch part {
        case .statusMark: AgentStatusMark(agent: agent, small: small)
        case .title:
            Text(settings.rows.titleSource == .branch ? (agent.branch ?? agent.title) : agent.title)
                .lineLimit(1).truncationMode(.middle).frame(maxWidth: 170, alignment: .leading)
        case .project: metadata(agent.project, width: 110)
        case .model:
            if let model = agent.shortModel { metadata(model, width: 80) }
        case .effort:
            if agent.effort != nil { EffortBars(effort: agent.effort) }
        case .branch:
            if let branch = agent.branch, !branch.isEmpty { metadata(RowPartsText.branch(branch), width: 110) }
        case .worktree:
            if let worktree = agent.worktree, !worktree.isEmpty { metadata(RowPartsText.worktree(worktree), width: 110) }
        case .activity:
            if agent.state == .working, let activity = agent.activity, !activity.isEmpty {
                Text(activity).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(dim)
                    .lineLimit(1).truncationMode(.tail)
            }
        case .runningTime:
            if agent.state.isLive, agent.startedAt > 0 {
                // Seconds are shown under a minute, so tick every second until then.
                TimelineView(.periodic(from: .now, by: Date().timeIntervalSince1970 - agent.startedAt < 60 ? 1 : 60)) { context in
                    let now = context.date.timeIntervalSince1970
                    // Over two days is a start time from somewhere else, not a run: show nothing rather than nonsense.
                    if now - agent.startedAt < 2 * 86_400, let text = CardFormat.duration(startedAt: agent.startedAt, now: now) {
                        metadata(text, width: 70)
                    }
                }
            }
        case .context:
            ContextRing(usage: usage, agent: agent)
        case .cost:
            if let text = CardFormat.cost(usage.costs[agent.id]) {
                metadata(text, width: 70).help(RowPartsText.cost).accessibilityLabel(RowPartsText.cost + ": " + text)
            }
        }
    }

    private func metadata(_ text: String, width: CGFloat) -> some View {
        Text(text).font(.system(size: 10.5)).foregroundStyle(dim)
            .lineLimit(1).truncationMode(.middle).frame(maxWidth: width, alignment: .leading)
    }
}
