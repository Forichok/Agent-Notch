import AppKit
import SwiftUI
import NotchCore

/// «Промпты» → «Скиллы»: every skill Claude Code and Codex can load, with what it says about itself and how often it ran.
struct SettingsSkills: View {
    @ObservedObject var skills: SkillStore
    @ObservedObject var prompts: PromptStore
    @State private var filter = ""
    @State private var vendor: Vendor?
    @State private var added: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 14) {
                list.frame(width: 250)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
                detail.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(maxHeight: .infinity)
            HStack(spacing: 8) {
                if skills.scanning { ProgressView().controlSize(.small); Text(SkillText.scanning) }
                else if skills.counting { ProgressView().controlSize(.small); Text(SkillText.counting) }
                else { Text(SkillText.count(skills.skills.count) + " · " + SkillText.usageHint) }
                Spacer()
                Button(SkillText.refresh) { skills.refresh() }.disabled(skills.scanning).controlSize(.small)
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 30).padding(.top, 8).padding(.bottom, 20)
        .onAppear { skills.refresh() }
    }

    // MARK: list

    private struct SkillGroup: Identifiable {
        var id: String
        var title: String
        var items: [InstalledSkill]
    }

    private var groups: [SkillGroup] {
        let words = filter.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let shown = skills.skills.filter { s in
            (vendor == nil || s.vendor == vendor) && words.allSatisfy {
                (s.name + "\n" + s.description + "\n" + (s.plugin ?? "")).lowercased().contains($0)
            }
        }
        var result: [SkillGroup] = []
        for s in shown {
            let place = s.source == .project ? (s.project.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "") : ""
            let id = "\(s.vendor.rawValue)/\(s.source.rawValue)/\(place)"
            let title = SkillText.vendor(s.vendor) + " · " + (place.isEmpty ? SkillText.source(s.source) : place)
            if result.last?.id == id { result[result.count - 1].items.append(s) }
            else { result.append(SkillGroup(id: id, title: title, items: [s])) }
        }
        return result
    }

    private var list: some View {
        VStack(spacing: 0) {
            TextField(SkillText.search, text: $filter).textFieldStyle(.roundedBorder).padding([.horizontal, .top], 8)
            Picker("", selection: $vendor) {
                Text(SkillText.all).tag(Vendor?.none)
                Text("Claude").tag(Vendor?.some(.claude))
                Text("Codex").tag(Vendor?.some(.codex))
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.small).padding(8)
            if skills.skills.isEmpty && !skills.scanning {
                Text(SkillText.none).font(.caption).foregroundStyle(.secondary).padding().frame(maxHeight: .infinity, alignment: .top)
            } else {
                List(selection: $skills.selected) {
                    ForEach(groups) { g in
                        Section(g.title) {
                            ForEach(g.items) { s in row(s).tag(s.id) }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private func row(_ s: InstalledSkill) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(s.name).lineLimit(1)
                if let plugin = s.plugin, plugin != s.name {
                    Text(plugin).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .opacity(s.enabled == false ? 0.5 : 1)
            Spacer(minLength: 4)
            let n = skills.use(of: s).count
            if n > 0 { Text(PromptText.uses(n)).font(.caption).foregroundStyle(.secondary) }
        }
    }

    // MARK: detail

    @ViewBuilder private var detail: some View {
        if let s = skills.skill(skills.selected) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header(s)
                    if !s.description.isEmpty { Text(s.description).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                    facts(s)
                    actions(s)
                    if !s.body.isEmpty { contents(s) }
                }
                .padding(.trailing, 4)
            }
        } else {
            Text(skills.scanning ? SkillText.scanning : SkillText.noneSelected).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func header(_ s: InstalledSkill) -> some View {
        HStack(alignment: .center, spacing: 10) {
            if let icon = AppIconCache.image(s.vendor, dark: false) {
                Image(nsImage: icon).resizable().frame(width: 30, height: 30)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(s.name).font(.system(size: 16, weight: .semibold)).textSelection(.enabled)
                HStack(spacing: 6) {
                    chip(SkillText.vendor(s.vendor))
                    chip(SkillText.source(s.source))
                    if s.enabled == false { chip(SkillText.off, tint: .orange) }
                }
            }
            Spacer()
        }
    }

    private func facts(_ s: InstalledSkill) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            fact(SkillText.call) {
                Text(s.invocation).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            }
            fact(SkillText.used) {
                if s.vendor == .codex { Text(SkillText.codexUsage).foregroundStyle(.secondary) }
                else if skills.counting && skills.uses.isEmpty { Text(SkillText.counting).foregroundStyle(.secondary) }
                else {
                    let u = skills.use(of: s)
                    Text(u.count == 0 ? SkillText.neverUsed : SkillText.usedTimes(u.count, last: u.last.map(SettingsPrompts.relative)))
                }
            }
            if let plugin = s.plugin { fact(SkillText.plugin) { Text(plugin + (s.pluginVersion.map { " " + $0 } ?? "")) } }
            if let project = s.project { fact(SkillText.project) { Text(project).lineLimit(1).truncationMode(.middle) } }
            fact(SkillText.folder) {
                Text(s.folder.replacingOccurrences(of: NSHomeDirectory(), with: "~")).lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled).help(s.folder)
            }
            fact(SkillText.files) {
                Text("\(s.files) · " + ByteCountFormatter.string(fromByteCount: Int64(s.bytes), countStyle: .file))
            }
            if s.modified > .distantPast { fact(SkillText.changed) { Text(SettingsPrompts.relative(s.modified)) } }
            ForEach(Array(s.fields.enumerated()), id: \.offset) { _, f in
                fact(f.key) { Text(f.value).lineLimit(4).textSelection(.enabled) }
            }
        }
        .font(.system(size: 12))
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private func fact<V: View>(_ title: String, @ViewBuilder _ value: () -> V) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            value()
        }
    }

    /// One row when it fits, two otherwise: the labels are long in Russian.
    private func actions(_ s: InstalledSkill) -> some View {
        let files = Group {
            Button(SkillText.open) { NSWorkspace.shared.open(URL(fileURLWithPath: s.folder).appendingPathComponent("SKILL.md")) }
            Button(SkillText.reveal) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: s.folder)]) }
        }
        let calls = Group {
            Button(SkillText.copyCall) { PromptPaster.copy(s.invocation) }
            Button(added == s.id ? SkillText.added : SkillText.toVault) {
                prompts.add(title: s.name, text: s.invocation + " ")
                added = s.id
            }
            .disabled(added == s.id)
        }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { files; calls }.fixedSize()
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) { files }.fixedSize()
                HStack(spacing: 8) { calls }.fixedSize()
            }
        }
        .controlSize(.small)
    }

    private func contents(_ s: InstalledSkill) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(SkillText.contents).font(.caption).foregroundStyle(.secondary)
            let limit = 8000
            Text(s.body.count > limit ? String(s.body.prefix(limit)) + "\n\n" + SkillText.truncated : s.body)
                .font(.system(size: 11.5, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12)))
        }
    }

    private func chip(_ text: String, tint: Color = .secondary) -> some View {
        Text(text).font(.system(size: 10.5, weight: .medium)).foregroundStyle(tint)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(tint.opacity(0.12), in: Capsule())
    }
}
