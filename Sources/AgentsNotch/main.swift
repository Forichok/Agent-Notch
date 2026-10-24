import AppKit
import Combine
import NotchCore

/// Flags: `--fixture <scene>` shows a made-up scene instead of the real logs, `--cramped` forces the one-summary wing,
/// `--snapshot-card <png> [--card-tab prompts] [--card-log <jsonl>]` draws the agent card on one tab, from a real log if given, `--open-list` opens the list on start, `--open-prompts` the prompt picker, `--snapshot <dir>` writes PNGs of every scene and quits,
/// `--install-hooks` / `--uninstall-hooks` edit the Claude Code and Codex hook files and quit.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // Lazy: snapshot and hook flags exit before it, so they never build `AppSettings.shared` on the real domain.
    lazy var store = Store()
    var notch: NotchController?
    var watcher: MenuWatcher?
    var keys: HotKeys?
    var picker: PromptPicker?
    var room: RoomWallpaper?
    var saverFeed: RoomSaverFeed?
    private var roomSub: AnyCancellable?
    var widget: DesktopWidget?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot-honest-done"), i + 1 < args.count {
            exit(Snapshot.runHonestDone(into: args[i + 1]) ? 0 : 1)
        }
        if let i = args.firstIndex(of: "--snapshot-toast"), i + 1 < args.count {
            exit(Snapshot.runToast(into: args[i + 1]) ? 0 : 1)
        }
        if let i = args.firstIndex(of: "--snapshot-delivery"), i + 1 < args.count {
            exit(Snapshot.runDelivery(into: args[i + 1]) ? 0 : 1)
        }
        if let i = args.firstIndex(of: "--snapshot-themes"), i + 1 < args.count {
            exit(Snapshot.runThemes(into: args[i + 1]) ? 0 : 1)
        }
        if let i = args.firstIndex(of: "--snapshot-widget"), i + 1 < args.count {
            exit(Snapshot.runWidget(into: args[i + 1]) ? 0 : 1)
        }
        if let i = args.firstIndex(of: "--snapshot-card"), i + 1 < args.count {
            let tab = args.firstIndex(of: "--card-tab").flatMap { $0 + 1 < args.count ? CardTab(rawValue: args[$0 + 1]) : nil }
            let log = args.firstIndex(of: "--card-log").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
            exit(Snapshot.runCard(to: args[i + 1], tab: tab ?? .done, log: log) ? 0 : 1)
        }
        if let i = args.firstIndex(of: "--snapshot-usage"), i + 1 < args.count {
            exit(Snapshot.runUsage(to: args[i + 1]) ? 0 : 1)
        }
        if let i = args.firstIndex(of: "--snapshot-settings"), i + 1 < args.count {
            exit(Snapshot.runSettings(to: args[i + 1]) ? 0 : 1)
        }
        if let i = args.firstIndex(of: "--snapshot-prompts"), i + 1 < args.count {
            exit(Snapshot.runPrompts(to: args[i + 1]) ? 0 : 1)
        }
        if let i = args.firstIndex(of: "--snapshot-marks"), i + 1 < args.count {
            exit(Snapshot.runMarks(to: args[i + 1]) ? 0 : 1)
        }
        if let i = args.firstIndex(of: "--snapshot-live"), i + 1 < args.count {
            Task { await Snapshot.runLive(to: args[i + 1]); NSApp.terminate(nil) }
            return
        }
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            Snapshot.run(into: args[i + 1])
            NSApp.terminate(nil)
            return
        }
        if args.contains("--install-hooks") || args.contains("--uninstall-hooks") {
            exit(Self.editHooks(install: args.contains("--install-hooks")))
        }
        let inst = HookInstaller()
        if inst.hasManagedHook(.claude) || inst.hasManagedHook(.codex) { try? inst.placeHelper(from: AppActions.bundledHelper, app: AppActions.appExecutable) }
        if let i = args.firstIndex(of: "--fixture"), i + 1 < args.count, let scene = Fixtures.agents(args[i + 1]) {
            store.useFixture(scene, asks: Fixtures.asks(args[i + 1]))
        } else {
            store.start()
        }
        store.forceCramped = args.contains("--cramped")
        if UpdateLaunchPolicy.shouldStart(arguments: args) {
            AppUpdates.shared.start()
        }
        KeepAwakeModel.shared.startMonitoring()
        let notch = NotchController(store: store)
        self.notch = notch
        widget = DesktopWidget(store: store)
        store.onNewAsk = { [weak notch] in
            if AppSettings.shared.behavior.openOnRequest { notch?.showList() }
        }
        // A hotkey that cannot answer yet opens the list, so the request gets seen first.
        let answer: @MainActor (HookDecision) -> Void = { [weak self, weak notch] d in
            guard let self, !self.store.hooks.pending.isEmpty, !self.store.decideByHotkey(d) else { return }
            notch?.showList()
        }
        SkillStore.shared.projects = { [store] in store.agents.compactMap(\.cwd) }
        let picker = PromptPicker()
        self.picker = picker
        notch.onPrompts = { [weak picker] in picker?.show() }
        keys = HotKeys(allow: { answer(.allow) }, deny: { answer(.deny) }, list: { [weak notch] in notch?.toggleList() },
                       vault: { [weak picker] in picker?.toggle() })
        watcher = MenuWatcher(store: store) { [weak notch] in notch?.fullWingLeft }
        if args.contains("--open-list") { notch.showList() }
        if args.contains("--open-prompts") { picker.show() }
        RoomProjects.shared.source = { [store] in store.shown.map(\.project) }
        let room = RoomWallpaper(store: store)
        self.room = room
        roomSub = AppSettings.shared.$roomWallpaper.sink { on in on || args.contains("--room") ? room.start() : room.stop() }
        let saverFeed = RoomSaverFeed(store: store)
        self.saverFeed = saverFeed
        saverFeed.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        PromptStore.shared.flush()
        saverFeed?.stop()
    }

    private static func editHooks(install: Bool) -> Int32 {
        let inst = HookInstaller()
        do {
            if install { try inst.placeHelper(from: AppActions.bundledHelper, app: AppActions.appExecutable) }
            let status = inst.editHooks(install: install)
            if install && status == 0 { print(AppActions.codexTrustNote) }
            return status
        } catch {
            FileHandle.standardError.write(Data("hooks: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
