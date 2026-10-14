import AppKit
import SwiftUI
import NotchCore

/// «Промпты»: the vault's library on the left, the editor on the right, and a statistics tab.
struct SettingsPrompts: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var prompts: PromptStore
    var skills: SkillStore = .shared
    @State private var filter = ""

    enum Tab: Hashable { case library, stats, skills }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("", selection: $prompts.tab) {
                Text(PromptText.library).tag(Tab.library)
                Text(PromptText.stats).tag(Tab.stats)
                Text(SkillText.tab).tag(Tab.skills)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .padding(.leading, 30).padding(.top, 10).padding(.bottom, 4)
            switch prompts.tab {
            case .library: library
            case .stats: PromptStatsView(prompts: prompts)
            case .skills: SettingsSkills(skills: skills, prompts: prompts)
            }
        }
    }

    private var library: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 0) {
                    TextField(PromptText.search, text: $filter).textFieldStyle(.roundedBorder).padding(8)
                    List(selection: $prompts.editing) {
                        ForEach(listed) { s in
                            HStack {
                                Text(s.label).lineLimit(1)
                                Spacer(minLength: 4)
                                let n = uses[s.id] ?? 0
                                if n > 0 { Text(PromptText.uses(n)).font(.caption).foregroundStyle(.secondary) }
                            }
                            .tag(s.id)
                        }
                        .onMove(perform: filter.isEmpty ? { prompts.move(from: $0, to: $1) } : nil)
                    }
                    .listStyle(.inset)
                    Divider()
                    HStack(spacing: 2) {
                        Button { prompts.add(); filter = "" } label: { Image(systemName: "plus").frame(width: 22, height: 18) }
                            .help(PromptText.add)
                        Button { if let id = prompts.editing { prompts.remove(id) } } label: { Image(systemName: "minus").frame(width: 22, height: 18) }
                            .disabled(prompts.editing == nil).help(PromptText.remove)
                        Button { if let id = prompts.editing { prompts.duplicate(id) } } label: { Image(systemName: "plus.square.on.square").frame(width: 22, height: 18) }
                            .disabled(prompts.editing == nil).help(PromptText.duplicate)
                        Spacer()
                    }
                    .buttonStyle(.borderless).padding(6)
                }
                .frame(width: 230)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))

                editor.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    SettingsLabel(PromptText.restore, hint: PromptText.restoreHelp)
                    Spacer()
                    Toggle(PromptText.restore, isOn: $settings.prompts.restoreClipboard).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                Text(PromptText.hotkeyHint(settings.shortcuts.vault.display) + " " + PromptText.dragHint)
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 30).padding(.top, 8).padding(.bottom, 20)
    }

    @ViewBuilder private var editor: some View {
        if let id = prompts.editing, let s = prompts.snippet(id) {
            let stat = prompts.vault.stats().first { $0.snippet.id == id }
            VStack(alignment: .leading, spacing: 8) {
                Text(PromptText.titleField).font(.caption).foregroundStyle(.secondary)
                TextField(PromptText.titleField, text: Binding(get: { s.title }, set: { prompts.update(id, title: $0) }))
                    .textFieldStyle(.roundedBorder).font(.system(size: 13, weight: .medium))
                Text(PromptText.textField).font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                TextEditor(text: Binding(get: { s.text }, set: { prompts.update(id, text: $0) }))
                    .font(.system(size: 12.5, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12)))
                    .id(id)
                HStack {
                    Text(PromptText.used(stat?.total ?? 0, last: stat?.last.map(Self.relative)))
                    Spacer()
                    Text(PromptText.characters(s.text.count))
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Text(PromptText.noneSelected).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var listed: [PromptSnippet] {
        let words = filter.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return prompts.vault.snippets }
        return prompts.vault.snippets.filter { s in words.allSatisfy { (s.label + "\n" + s.text).lowercased().contains($0) } }
    }

    private var uses: [UUID: Int] { Dictionary(uniqueKeysWithValues: prompts.vault.stats().map { ($0.snippet.id, $0.total) }) }

    static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: Loc.isRussian ? "ru" : "en")
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }
}

/// Totals as tiles, the last two weeks as day bars, and the most used prompts ranked with bars.
struct PromptStatsView: View {
    @ObservedObject var prompts: PromptStore
    @State private var confirmReset = false
    static let days = 14

    var body: some View {
        let now = Date()
        let stats = prompts.vault.stats(now: now)
        let used = stats.filter { $0.total > 0 }
        let unused = stats.filter { $0.total == 0 }
        Form {
            Section {
                HStack(spacing: 10) {
                    tile(PromptText.total, prompts.vault.uses.count)
                    tile(PromptText.week, prompts.vault.uses(since: now.addingTimeInterval(-7 * 86_400)))
                    tile(PromptText.count, prompts.vault.snippets.count)
                }
            }
            if used.isEmpty {
                Section { Text(PromptText.noStats).foregroundStyle(.secondary) }
            } else {
                Section(PromptText.activity) { DayBars(counts: prompts.vault.daily(days: Self.days, now: now), now: now) }
                Section(PromptText.top) {
                    let top = used.prefix(10)
                    let peak = top.first?.total ?? 1
                    ForEach(Array(top.enumerated()), id: \.element.snippet.id) { i, stat in
                        TopRow(rank: i + 1, stat: stat, peak: peak)
                    }
                }
            }
            if !unused.isEmpty && !used.isEmpty {
                Section(PromptText.never) {
                    Text(unused.map(\.snippet.label).joined(separator: " · ")).foregroundStyle(.secondary)
                }
            }
            Section {
                LabeledContent {
                    Button(PromptText.resetStats) { confirmReset = true }.disabled(prompts.vault.uses.isEmpty)
                } label: {
                    SettingsLabel(PromptText.file, hint: "~/Library/Application Support/AgentsNotch/prompts.json")
                }
            }
        }
        .confirmationDialog(PromptText.resetStatsConfirm, isPresented: $confirmReset) {
            Button(PromptText.resetStats, role: .destructive) { prompts.resetStats() }
            Button(SettingsText.cancel, role: .cancel) {}
        }
    }

    private func tile(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)").font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// One bar per day, today on the right; hover shows the date and the count.
private struct DayBars: View {
    let counts: [Int]
    let now: Date
    static let height: CGFloat = 70

    var body: some View {
        let peak = max(counts.max() ?? 0, 1)
        VStack(spacing: 4) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(counts.enumerated()), id: \.offset) { i, n in
                    UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4)
                        .fill(n == 0 ? Color.primary.opacity(0.08) : Color.accentColor)
                        .frame(maxWidth: 22)
                        .frame(height: n == 0 ? 2 : max(4, Self.height * CGFloat(n) / CGFloat(peak)))
                        .frame(maxWidth: .infinity, maxHeight: Self.height, alignment: .bottom)
                        .contentShape(Rectangle())
                        .help("\(label(i)): \(n)")
                }
            }
            .frame(height: Self.height)
            HStack {
                Text(label(0)); Spacer(); Text(label(counts.count - 1))
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func label(_ i: Int) -> String {
        let day = Calendar.current.date(byAdding: .day, value: i - (counts.count - 1), to: now) ?? now
        let f = DateFormatter()
        f.locale = Locale(identifier: Loc.isRussian ? "ru" : "en")
        f.setLocalizedDateFormatFromTemplate("d MMM")
        return f.string(from: day)
    }
}

private struct TopRow: View {
    let rank: Int
    let stat: PromptStat
    let peak: Int

    var body: some View {
        HStack(spacing: 10) {
            Text("\(rank)").font(.caption).foregroundStyle(.secondary).monospacedDigit().frame(width: 16, alignment: .trailing)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(stat.snippet.label).lineLimit(1)
                    Spacer()
                    if stat.week > 0 { Text(PromptText.thisWeek(stat.week)).font(.caption).foregroundStyle(.secondary) }
                    Text("\(stat.total)").monospacedDigit().fontWeight(.semibold)
                }
                GeometryReader { g in
                    Capsule().fill(Color.accentColor)
                        .frame(width: max(4, g.size.width * CGFloat(stat.total) / CGFloat(max(peak, 1))), height: 4)
                }
                .frame(height: 4)
            }
        }
        .help(stat.last.map { SettingsPrompts.relative($0) } ?? "")
    }
}
