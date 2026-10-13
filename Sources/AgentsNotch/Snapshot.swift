import AppKit
import SwiftUI
import NotchCore

/// `--snapshot <dir>`: renders every fixture scene (menu bar strip with the wing + the open list) to PNG and exits.
/// Lets a check see the real SwiftUI output without screen-recording permission.
@MainActor
enum Snapshot {
    static func run(into dir: String) {
        let suite = "AgentsNotch.snapshot." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else { return }
        defer { defaults.removePersistentDomain(forName: suite) }
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

    /// `--snapshot-live <file.png>`: scans this Mac's session logs once and renders what it found.
    static func runLive(to file: String) async {
        let suite = "AgentsNotch.snapshot." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else { return }
        defer { defaults.removePersistentDomain(forName: suite) }
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
        let suite = "AgentsNotch.snapshot." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else { return false }
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        func shot(_ section: SettingsSection, _ url: URL, height: CGFloat = SettingsView.size.height) -> Bool {
            host(SettingsView(selection: section).environmentObject(settings).environment(\.colorScheme, .light),
                 size: NSSize(width: SettingsView.size.width, height: height), to: url)
        }
        guard !path.hasSuffix(".png") else { return shot(.appearance, URL(fileURLWithPath: path)) }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var ok = true
        for section in SettingsSection.allCases {
            ok = shot(section, dir.appendingPathComponent("section-\(section.rawValue).png")) && ok
            ok = shot(section, dir.appendingPathComponent("full-\(section.rawValue).png"), height: 1500) && ok
        }
        for preset in DisplayPreset.allCases {
            settings.apply(preset)
            ok = shot(.appearance, dir.appendingPathComponent("preset-\(preset.rawValue).png")) && ok
        }
        settings.apply(.detailed)
        settings.appearance.finishedMinutes = 15
        ok = shot(.appearance, dir.appendingPathComponent("preset-own.png")) && ok
        return ok
    }

    static func runCard(to file: String) -> Bool {
        host(CardView(agent: CardFixture.agent, detail: CardFixture.detail, context: ContextUsage(usedTokens: 84_000, windowTokens: 200_000),
                      cost: SessionCost(tokens: 1, usd: 1.37)).environmentObject(AppSettings.shared),
             size: NSSize(width: 340, height: 480), to: URL(fileURLWithPath: file))
    }

    /// Forms and lists are AppKit views that ImageRenderer cannot draw, so this snapshot goes through a real window.
    private static func host<V: View>(_ scene: V, size: NSSize, to url: URL) -> Bool {
        let view = NSHostingView(rootView: scene.frame(width: size.width, height: size.height))
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

    static func runUsage(to file: String) -> Bool {
        host(UsageSnapshot(), size: NSSize(width: 380, height: 300), to: URL(fileURLWithPath: file))
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
