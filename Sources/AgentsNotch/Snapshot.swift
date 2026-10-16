import AppKit
import SwiftUI
import NotchCore

/// `--snapshot <dir>`: renders every fixture scene (menu bar strip with the wing + the open list) to PNG and exits.
/// Lets a check see the real SwiftUI output without screen-recording permission.
@MainActor
enum Snapshot {
    /// `--snapshot-toast <dir>` renders the folder fallback in both languages.
    static func runToast(into dir: String) -> Bool {
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        catch { return false }
        guard let scratch = ScratchDefaults("snapshot") else { return false }
        let defaults = scratch.defaults
        let settings = AppSettings(defaults: defaults)
        let forced = Loc.forced
        defer { Loc.forced = forced; scratch.remove() }
        var ok = true
        for language in [Loc.Language.en, .ru] {
            Loc.forced = language
            for terminalOrigin in [true, false] {
                let name = terminalOrigin ? "fallback" : "app-fallback"
                ok = host(JumpToastView(canResume: true, terminalOrigin: terminalOrigin, onCopy: {}).environmentObject(settings),
                          to: url.appendingPathComponent("\(name)-\(language.rawValue).png")) && ok
            }
            let themes = ThemeID.allCases.map { id in
                let themed = AppSettings(defaults: defaults)
                themed.theme = id
                return themed
            }
            let grid = HStack(alignment: .top, spacing: 16) {
                ForEach(0..<3) { column in
                    VStack(spacing: 16) {
                        ForEach(themes.indices.filter { $0 % 3 == column }, id: \.self) { index in
                            let themeSettings = themes[index]
                            VStack(alignment: .leading, spacing: 4) {
                                Text(themeSettings.theme.rawValue).foregroundStyle(.white)
                                JumpToastView(canResume: true, onCopy: {}).environmentObject(themeSettings)
                            }
                        }
                    }
                }
            }.padding(16).background(Color(white: 0.3))
            ok = host(grid, to: url.appendingPathComponent("themes-\(language.rawValue).png")) && ok
        }
        return ok
    }

    static func run(into dir: String) {
        guard let scratch = ScratchDefaults("snapshot") else { return }
        let defaults = scratch.defaults
        defer { scratch.remove() }
        let settings = AppSettings(defaults: defaults)
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for name in Fixtures.names {
            for cramped in [false, true] where !cramped || name == "heavy" {
                let store = Store(settings: settings)
                store.useFixture(Fixtures.agents(name) ?? [], asks: Fixtures.asks(name))
                store.forceCramped = cramped
                write(Scene(store: store), to: url.appendingPathComponent("\(name)\(cramped ? "-cramped" : "").png"))
            }
        }
    }

    /// `--snapshot-honest-done <dir>`: helper row and finish toast, using the production views.
    static func runHonestDone(into dir: String) -> Bool {
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        catch { return false }
        guard let scratch = ScratchDefaults("snapshot") else { return false }
        let defaults = scratch.defaults
        let forced = Loc.forced
        defer { scratch.remove(); Loc.forced = forced }
        let settings = AppSettings(defaults: defaults)
        settings.setRowPart(.activity, shown: true)
        let fixture = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Tests/Fixtures/HonestDone/toast-claude.jsonl")
        guard let detail = DetailReader.read(path: fixture.path, vendor: .claude) else { return false }
        var ok = true
        for language in [Loc.Language.en, .ru] {
            Loc.forced = language
            let parent = Agent(id: "honest", vendor: .claude, title: "AN-0.6-7", state: .done, project: "Agent Notch")
            let kids = (1...2).map { Agent(id: "helper-\($0)", vendor: .claude, title: Loc.t("Helper \($0)", "Помощник \($0)"),
                state: .working, project: parent.project, parentId: parent.id) }
            let store = Store(settings: settings)
            store.useFixture([parent] + kids)
            ok = write(Scene(store: store), to: url.appendingPathComponent("helpers-\(language.rawValue).png")) && ok
            let notice = FinishNotice(agent: parent, title: parent.title, line: FinishSummary.line(detail),
                                      preview: FinishSummary.preview(detail))
            ok = write(ToastView(notice: notice, onOpen: {}).environmentObject(settings)
                .padding(20).background(Color(white: 0.35)),
                to: url.appendingPathComponent("toast-\(language.rawValue).png")) && ok
        }
        return ok
    }

    /// `--snapshot-delivery <dir>`: the same permission before countdown, near timeout, in flight, and after failure.
    static func runDelivery(into dir: String) -> Bool {
        guard let scratch = ScratchDefaults("snapshot") else { return false }
        let defaults = scratch.defaults
        let forced = Loc.forced
        defer { scratch.remove(); Loc.forced = forced }
        let settings = AppSettings(defaults: defaults)
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        catch { return false }
        var ok = true
        for language in [Loc.Language.en, .ru] {
            Loc.forced = language
            for (name, age, status) in [("waiting", 5.0, AnswerDelivery.waiting), ("countdown", 75.0, .waiting),
                                        ("sent", 76.0, .sent), ("not-delivered", 100.0, .notDelivered)] {
                let store = Store(settings: settings)
                store.useFixture(Fixtures.agents("ask") ?? [], asks: Array(Fixtures.asks("ask").prefix(1)), askAge: age, delivery: status)
                ok = write(Scene(store: store), to: url.appendingPathComponent("\(name)-\(language.rawValue).png")) && ok
            }
            let mixed = Store(settings: settings)
            let requests = Array(Fixtures.asks("ask").prefix(1)) + [HookEvent(vendor: .claude, name: "PermissionRequest",
                sessionId: "fx-1", tool: "Bash", toolUseID: "second", detail: "echo second request")]
            mixed.useFixture(Fixtures.agents("ask") ?? [], asks: requests, deliveries: [.notDelivered, .waiting])
            ok = write(Scene(store: mixed), to: url.appendingPathComponent("mixed-\(language.rawValue).png")) && ok
            for name in ["question", "plan"] {
                let store = Store(settings: settings)
                store.useFixture(Fixtures.agents(name) ?? [], asks: Fixtures.asks(name), delivery: .notDelivered)
                ok = write(Scene(store: store), to: url.appendingPathComponent("\(name)-not-delivered-\(language.rawValue).png")) && ok
            }
        }
        return ok
    }

    /// `--snapshot-live <file.png>`: scans this Mac's session logs once and renders what it found.
    static func runLive(to file: String) async {
        guard let scratch = ScratchDefaults("snapshot") else { return }
        let defaults = scratch.defaults
        defer { scratch.remove() }
        let settings = AppSettings(defaults: defaults)
        // The cost is off in the default preset; the live shot shows it so a check can see real amounts.
        settings.setRowPart(.cost, shown: true)
        let store = Store(settings: settings)
        await withCheckedContinuation { done in store.poll { done.resume() } }
        var costs: [String: SessionCost] = [:]
        for agent in store.agents {
            if let path = agent.logPath, let cost = SessionSpend.shared.read(path: path, vendor: agent.vendor) { costs[agent.id] = cost }
        }
        store.usage.useFixture(limits: [], spend: [], contexts: [:], costs: costs, now: Date())
        write(Scene(store: store), to: URL(fileURLWithPath: file))
        print("costs: " + store.agents.map { "\($0.title.prefix(24))=\(CardFormat.cost(costs[$0.id]) ?? "-")" }.joined(separator: ", "))
        print("agents: \(store.agents.count), live: \(store.agents.filter(\.state.isLive).count)")
    }

    /// A `.png` path renders «Внешний вид»; a folder gets every section plus «Внешний вид» under each preset and «Своё».
    static func runSettings(to path: String) -> Bool {
        guard let scratch = ScratchDefaults("snapshot") else { return false }
        let defaults = scratch.defaults
        defer { scratch.remove() }
        let libraryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("notch-snapshot-library-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: libraryDirectory) }
        let settings = AppSettings(defaults: defaults, soundLibraryDirectory: libraryDirectory)
        if ProcessInfo.processInfo.environment["AN_CONNECTION_SHOT"] == "1" {
            let home = URL(fileURLWithPath: "/tmp/nc-" + UUID().uuidString.prefix(8))
            defer { try? FileManager.default.removeItem(at: home) }
            let installer = HookInstaller(home: home)
            do {
                try installer.install(.claude)
                try installer.install(.codex)
                try FileManager.default.copyItem(at: AppActions.bundledHelper, to: installer.helper)
                chmod(installer.helper.path, 0o755)
                try Data((AppActions.appExecutable + "\n").utf8).write(to: installer.appPin)
                chmod(installer.appPin.path, 0o600)
            } catch { return false }
            let server = HookServer(path: ConnectionReport.socketPath(installer))
            do { try server.start() } catch { return false }
            defer { server.stop() }
            return host(SettingsConnection(settings: settings, installer: installer)
                .formStyle(.grouped).environment(\.colorScheme, .light),
                size: NSSize(width: 570, height: 850), to: URL(fileURLWithPath: path))
        }
        // `AN_VENDOR_PICKER=1`: the icon section alone, with the Codex menu drawn open.
        if ProcessInfo.processInfo.environment["AN_VENDOR_PICKER"] != nil {
            settings.theme = .midnight
            settings.themeMarks = true
            settings.vendorIcons[.claude] = .theme(.ducks)
            settings.vendorIcons[.codex] = .theme(.console)
            let scene = ZStack(alignment: .topTrailing) {
                Form {
                    Section(SettingsText.vendorIcons) {
                        SettingsVendorIconRow(settings: settings, vendor: .claude)
                        SettingsVendorIconRow(settings: settings, vendor: .codex)
                        Text(SettingsText.vendorIconHelp).font(.caption).foregroundStyle(.secondary)
                    }
                }.formStyle(.grouped)
                VendorIconMenuDrawing(settings: settings, vendor: .codex).padding(.top, 150).padding(.trailing, 40)
            }
            return host(scene.environmentObject(settings).environment(\.colorScheme, .light),
                        size: NSSize(width: 600, height: 760), to: URL(fileURLWithPath: path))
        }
        if ProcessInfo.processInfo.environment["AN_VENDOR_ICON_SHOT"] != nil {
            settings.theme = .paper
            if ProcessInfo.processInfo.environment["AN_VENDOR_ICON_SHOT"] == "after" {
                settings.vendorIcons[.codex] = .symbol("bolt.fill")
            }
        }
        let prompts = promptFixture()
        let skills = skillFixture()
        func shot(_ section: SettingsSection, _ url: URL, height: CGFloat = SettingsView.size.height) -> Bool {
            host(SettingsView(selection: section, prompts: prompts, skills: skills).environmentObject(settings).environment(\.colorScheme, .light),
                 size: NSSize(width: SettingsView.size.width, height: height), to: url)
        }
        guard !path.hasSuffix(".png") else { return shot(.appearance, URL(fileURLWithPath: path), height: ProcessInfo.processInfo.environment["AN_VENDOR_ICON_SHOT"] == nil ? SettingsView.size.height : 1800) }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var ok = true
        for section in SettingsSection.allCases {
            ok = shot(section, dir.appendingPathComponent("section-\(section.rawValue).png")) && ok
            ok = shot(section, dir.appendingPathComponent("full-\(section.rawValue).png"), height: section == .sounds ? 2200 : 1500) && ok
        }
        ok = host(SettingsSounds(settings: settings, customizing: true)
            .formStyle(.grouped).environment(\.colorScheme, .light),
            size: NSSize(width: 570, height: 2200), to: dir.appendingPathComponent("sounds-customize.png")) && ok
        for preset in SoundPreset.allCases {
            settings.applySoundPreset(preset)
            ok = shot(.sounds, dir.appendingPathComponent("sounds-\(preset.rawValue).png")) && ok
        }
        settings.soundEvents[.cardOpened] = "Frog"
        ok = shot(.sounds, dir.appendingPathComponent("sounds-custom.png")) && ok
        let sample = FileManager.default.temporaryDirectory.appendingPathComponent("Soft bell-" + UUID().uuidString + ".aiff")
        defer { try? FileManager.default.removeItem(at: sample) }
        do {
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/System/Library/Sounds/Glass.aiff"), to: sample)
            let custom = try settings.importSound(sample)
            settings.soundEvents[.agentFinished] = custom.id
            ok = shot(.sounds, dir.appendingPathComponent("sounds-library.png")) && ok
            ok = host(SettingsSounds(settings: settings, customizing: true)
                .formStyle(.grouped).environment(\.colorScheme, .light),
                size: NSSize(width: 570, height: 2500), to: dir.appendingPathComponent("sounds-library-events.png")) && ok
        } catch { print("snapshot sound library: \(error.localizedDescription)"); ok = false }
        for tab in [SettingsPrompts.Tab.stats, .skills] {
            prompts.tab = tab
            ok = shot(.vault, dir.appendingPathComponent("section-prompts-\(tab).png")) && ok
        }
        prompts.tab = .library
        for preset in DisplayPreset.allCases {
            settings.apply(preset)
            ok = shot(.appearance, dir.appendingPathComponent("preset-\(preset.rawValue).png")) && ok
        }
        settings.apply(.detailed)
        settings.appearance.finishedMinutes = 15
        ok = shot(.appearance, dir.appendingPathComponent("preset-own.png")) && ok
        settings.theme = .pixel
        ok = shot(.appearance, dir.appendingPathComponent("theme-pixel-marks.png"), height: 1500) && ok
        return ok
    }

    /// `--snapshot-themes <dir>`: per theme, the list with requests, the list with projects and the card, over one wallpaper.
    static func runThemes(into dir: String) -> Bool {
        guard let scratch = ScratchDefaults("snapshot") else { return false }
        let defaults = scratch.defaults
        defer { scratch.remove() }
        let settings = AppSettings(defaults: defaults)
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var ok = true
        for id in ThemeID.allCases {
            settings.theme = id
            let ask = Store(settings: settings), list = Store(settings: settings)
            ask.useFixture(Fixtures.agents("ask") ?? [], asks: Fixtures.asks("ask"))
            list.useFixture(Fixtures.agents("projects") ?? [], asks: [])
            let scene = VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 0) {
                    WingView(layout: list.layout).frame(height: 32)
                    Color.clear.frame(width: 120, height: 32)
                }
                .background(UnevenRoundedRectangle(bottomLeadingRadius: 9, bottomTrailingRadius: 9).fill(.black))
                HStack(alignment: .top, spacing: 24) {
                PanelView(store: ask, scrolls: false).fixedSize(horizontal: false, vertical: true).environmentObject(ask.usage)
                PanelView(store: list, scrolls: false).fixedSize(horizontal: false, vertical: true).environmentObject(list.usage)
                CardView(agent: CardFixture.agent, detail: CardFixture.detail, context: ContextUsage(usedTokens: 84_000, windowTokens: 200_000),
                         cost: SessionCost(tokens: 1, usd: 1.37)).frame(height: 430)
                }
            }
            .padding(28)
            .background(ThemeWallpaper())
            .environmentObject(settings)
            .environment(\.themeSnapshot, true)
            // The card's tab body sits in a ScrollView, which ImageRenderer leaves blank, so this goes through a window.
            ok = host(scene, to: url.appendingPathComponent("theme-\(id.rawValue).png")) && ok
        }
        settings.theme = .terminal
        ok = write(ThemeMarksGrid().environmentObject(settings).environment(\.themeSnapshot, true),
                   to: url.appendingPathComponent("theme-marks.png")) && ok
        return ok
    }

    static func runCard(to file: String, tab: CardTab = .done, log: String? = nil) -> Bool {
        guard let scratch = ScratchDefaults("snapshot") else { return false }
        let defaults = scratch.defaults
        defer { scratch.remove() }
        let detail = log.map { DetailReader.read(path: $0, vendor: $0.contains("/.codex/") ? .codex : .claude) } ?? CardFixture.detail
        let settings = AppSettings(defaults: defaults)
        if ProcessInfo.processInfo.environment["AN_VENDOR_ICON_SHOT"] == "after" {
            settings.theme = .paper
            // `AN_VENDOR_ICON_THEME=<id>` borrows that theme's mark instead of the symbol.
            settings.vendorIcons[.codex] = ProcessInfo.processInfo.environment["AN_VENDOR_ICON_THEME"]
                .flatMap(ThemeID.init(rawValue:)).map(VendorIcon.theme) ?? .symbol("bolt.fill")
            let store = Store(settings: settings)
            store.useFixture([CardFixture.agent])
            return host(VStack(spacing: 12) {
                WingView(layout: store.layout).frame(height: 30).background(Color.black)
                CardView(agent: CardFixture.agent, detail: detail,
                         context: ContextUsage(usedTokens: 84_000, windowTokens: 200_000),
                         cost: SessionCost(tokens: 1, usd: 1.37), tab: tab)
            }.environmentObject(settings).environment(\.theme, settings.currentTheme),
            size: NSSize(width: 340, height: 530), to: URL(fileURLWithPath: file))
        }
        return host(CardView(agent: CardFixture.agent, detail: detail, context: ContextUsage(usedTokens: 84_000, windowTokens: 200_000),
                      cost: SessionCost(tokens: 1, usd: 1.37), tab: tab).environmentObject(settings),
             size: NSSize(width: 340, height: 480), to: URL(fileURLWithPath: file))
    }

    /// Forms, lists and scroll views are AppKit views that ImageRenderer cannot draw, so this snapshot goes through a real window.
    /// Without a size the scene keeps its own fitting size.
    private static func host<V: View>(_ scene: V, size: NSSize? = nil, to url: URL) -> Bool {
        let view: NSView
        if let size { view = NSHostingView(rootView: scene.frame(width: size.width, height: size.height)) }
        else { view = NSHostingView(rootView: scene) }
        let size = size ?? view.fittingSize
        view.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        do { try png.write(to: url); return true }
        catch { print("snapshot: \(error.localizedDescription)"); return false }
    }

    /// The starter prompts with a few weeks of made-up insertions.
    static func promptFixture() -> PromptStore {
        var vault = PromptVault.starter
        let now = Date()
        let weights = [9, 4, 14, 2, 0]
        for (i, s) in vault.snippets.enumerated() {
            for n in 0..<weights[i] { vault.record(s.id, at: now.addingTimeInterval(-Double((n * 37 + i * 11) % 13) * 86_400 - 3600)) }
        }
        return PromptStore(file: nil, vault: vault)
    }

    /// A few made-up skills of both agents.
    static func skillFixture() -> SkillStore {
        func skill(_ name: String, _ vendor: Vendor, _ source: InstalledSkill.Source, plugin: String? = nil, _ description: String,
                   fields: [InstalledSkill.Field] = [], files: Int = 1) -> InstalledSkill {
            InstalledSkill(id: "/fixture/\(vendor.rawValue)/\(name)", name: name, description: description, vendor: vendor, source: source,
                           plugin: plugin, pluginVersion: plugin == nil ? nil : "1.1.0", project: source == .project ? "/Users/me/code/shop" : nil,
                           enabled: plugin == nil ? nil : true, fields: fields,
                           body: "# \(name)\n\n1. Read the request.\n2. Do the work.\n3. Check the result before answering.",
                           folder: "/Users/me/.claude/skills/\(name)", files: files, bytes: files * 2400,
                           modified: Date().addingTimeInterval(-3 * 86_400))
        }
        let list = [
            skill("commit-hygiene", .claude, .user, "Conventional Commits, scopes and a preflight before every commit.",
                  fields: [.init(key: "allowed-tools", value: "Bash, Read")], files: 3),
            skill("copywriter", .claude, .project, "Voice and UX-copy rules for the shop: short, plain, no jargon."),
            skill("decide", .claude, .plugin, plugin: "decide", "Let the user make decisions on a local browser page."),
            skill("imagegen", .codex, .system, "Generate or edit raster images.", files: 12),
            skill("pdf", .codex, .plugin, plugin: "pdf", "Read, create and verify PDF files.", files: 4),
        ]
        let ago = { (d: Double) in Date().addingTimeInterval(-d * 86_400) }
        return SkillStore(fixture: list, uses: ["commit-hygiene": SkillUse(count: 12, last: ago(1)),
                                                "copywriter": SkillUse(count: 9, last: ago(2)),
                                                "decide:decide": SkillUse(count: 2, last: ago(5))])
    }

    /// `--snapshot-prompts <file.png>`: the picker over a grey desktop.
    /// A `-skills` copy next to it shows the skills tab.
    static func runPrompts(to file: String) -> Bool {
        let prompts = promptFixture(), skills = skillFixture()
        func shot(_ mode: PromptPickerModel.Mode, _ url: URL, theme: Theme = .terminal) -> Bool {
            let model = PromptPickerModel()
            model.mode = mode
            model.selected = 1
            model.trusted = true
            let view = PromptPickerView(store: prompts, skills: skills, model: model, theme: theme)
                .padding(30).background(Color(white: 0.35))
            return host(view, size: NSSize(width: PromptPicker.width + 60, height: 520), to: url)
        }
        let url = URL(fileURLWithPath: file)
        let skillsURL = url.deletingPathExtension().appendingPathExtension("skills").appendingPathExtension("png")
        // Every other theme next to it, so a check can see the picker follow the list.
        var ok = shot(.prompts, url) && shot(.skills, skillsURL)
        for id in ThemeID.allCases where id != .terminal {
            ok = shot(.prompts, url.deletingPathExtension().appendingPathExtension(id.rawValue).appendingPathExtension("png"), theme: Theme.of(id)) && ok
        }
        return ok
    }

    static func runUsage(to file: String) -> Bool {
        guard let scratch = ScratchDefaults("snapshot") else { return false }
        defer { scratch.remove() }
        return host(UsageSnapshot().environmentObject(AppSettings(defaults: scratch.defaults)),
                    size: NSSize(width: 380, height: 300), to: URL(fileURLWithPath: file))
    }

    static func runMarks(to file: String) -> Bool {
        write(SettingsMarksGrid(), to: URL(fileURLWithPath: file))
    }

    @discardableResult private static func write<V: View>(_ scene: V, to url: URL) -> Bool {
        let renderer = ImageRenderer(content: scene)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return false }
        do { try png.write(to: url); return true }
        catch { print("snapshot: \(error.localizedDescription)"); return false }
    }

    private struct Scene: View {
        @ObservedObject var store: Store
        var body: some View {
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 0) {
                    Text(Loc.t("  Finder  File  Edit  View", "  Finder  Файл  Правка  Вид")).font(.system(size: 13)).foregroundStyle(.white)
                    Spacer(minLength: 20)
                    WingView(layout: store.layout)
                        .frame(height: 32)
                        .background(UnevenRoundedRectangle(bottomLeadingRadius: 9).fill(.black))
                    UnevenRoundedRectangle(bottomTrailingRadius: 9).fill(.black).frame(width: 180, height: 32)
                    Spacer().frame(width: 60)
                }
                .frame(width: 640, height: 32)
                .background(Color(white: 0.24))
                PanelView(store: store, scrolls: false).padding(.trailing, 60).padding(.bottom, 10)
            }
            .background(Color(white: 0.35))
            .environmentObject(store.settings)
            .environmentObject(store.usage)
        }
    }
}

/// Every theme's own mark side by side: vendor × weight × state, on that theme's surface.
private struct ThemeMarksGrid: View {
    private let states: [AgentState] = [.working, .waiting, .error, .done]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(ThemeID.allCases, id: \.self) { id in
                let theme = Theme.of(id)
                HStack(spacing: 14) {
                    Text(SettingsText.theme(id)).font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.text).frame(width: 110, alignment: .leading)
                    ForEach([Vendor.claude, .codex], id: \.rawValue) { vendor in
                        ForEach([false, true], id: \.self) { light in
                            HStack(spacing: 10) {
                                ForEach(states, id: \.rawValue) { state in
                                    Group {
                                        if id == .terminal {
                                            StatusMark(vendor: vendor, state: state, isLight: light, style: .logos, size: 14)
                                        } else {
                                            ThemeMark(theme: theme, vendor: vendor, state: state, isLight: light, size: 14)
                                        }
                                    }.frame(width: 18, height: 18)
                                }
                            }
                            .padding(.horizontal, 6)
                        }
                    }
                }
                .padding(10)
                .themeSurface(theme, radius: min(theme.radius, 10))
                .themed(theme)
            }
        }
        .padding(20)
        .background(ThemeWallpaper())
    }
}
