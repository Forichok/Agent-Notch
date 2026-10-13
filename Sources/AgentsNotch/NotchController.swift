import AppKit
import Combine
import ServiceManagement
import SwiftUI
import NotchCore

/// Draws the wing left of the notch (or a menu bar item on a screen without one) and the list panel below it.
@MainActor
final class NotchController {
    private let store: Store
    private let wingPanel = NotchController.makePanel()
    private let listPanel = NotchController.makePanel()
    private let toast = FinishToast()
    private lazy var cardPanel = CardPanel(store: store, list: listPanel) { [weak self] in self?.hideList() }
    private let wingHost: ClickHost
    private var statusItem: NSStatusItem?
    private var listHeight: CGFloat = 200
    private var outsideMonitor: Any?
    private var settingsShortcut: SettingsListShortcut?
    private var bag: Set<AnyCancellable> = []

    init(store: Store) {
        self.store = store
        wingHost = ClickHost(rootView: AnyView(EmptyView()))
        wingHost.onClick = { [weak self] in self?.toggleList() }
        wingHost.onRightClick = { [weak self] event in self?.showMenu(event) }
        let list = NSHostingView(rootView: PanelView(store: store) { [weak self] h in self?.resizeList(h) }.environmentObject(store.settings).environmentObject(store.usage))
        listPanel.contentView = list
        store.finisher.onNotice = { [weak self] n in self?.showToast(n) }
        _ = cardPanel
        store.objectWillChange.merge(with: store.settings.objectWillChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.render() }
            .store(in: &bag)
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.render() }
        }
        render()
    }

    // MARK: geometry

    /// The built-in screen with a camera housing, if any.
    var notchScreen: NSScreen? {
        NSScreen.screens.first { $0.auxiliaryTopLeftArea != nil && $0.safeAreaInsets.top > 0 }
    }

    /// Global x of the notch's left edge and the menu bar height on that screen.
    var notchAnchor: (x: CGFloat, top: CGFloat, height: CGFloat)? {
        guard let s = notchScreen, let left = s.auxiliaryTopLeftArea else { return nil }
        return (s.frame.minX + left.maxX, s.frame.maxY, s.safeAreaInsets.top)
    }

    private func render() {
        let view = WingView(layout: store.layout).environmentObject(store.settings)
        if let a = notchAnchor {
            statusItem.map { NSStatusBar.system.removeStatusItem($0) }
            statusItem = nil
            // The housing's own bottom corners are rounded: reach far enough under it to fill that curve.
            let under: CGFloat = 16
            wingHost.rootView = AnyView(view
                .padding(.trailing, under)
                .frame(height: a.height)
                .background(UnevenRoundedRectangle(bottomLeadingRadius: 9).fill(.black)))
            let w = wingHost.fittingSize.width
            wingPanel.contentView = wingHost
            wingPanel.setFrame(NSRect(x: a.x - w + under + 6, y: a.top - a.height, width: w, height: a.height), display: true)
            wingPanel.orderFrontRegardless()
        } else {
            wingPanel.orderOut(nil)
            if statusItem == nil { statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength) }
            wingHost.rootView = AnyView(view.frame(height: 22))
            let w = wingHost.fittingSize.width
            statusItem?.length = w
            if let button = statusItem?.button, wingHost.superview !== button {
                wingHost.removeFromSuperview()
                button.addSubview(wingHost)
            }
            wingHost.frame = NSRect(x: 0, y: 0, width: w, height: 22)
        }
        listPanel.wantsKey = store.hooks.pending.contains(where: \.needsTyping)
        if listPanel.isVisible { placeList() }
    }

    private func showToast(_ n: FinishNotice) {
        toast.show(n, notch: notchAnchor) { [weak self] in self?.showList(); self?.store.select(n.agent) }
    }

    /// Where the wing's left edge would sit if it were drawn in full: MenuWatcher keeps the menu clear of it.
    var fullWingLeft: CGFloat? {
        guard let a = notchAnchor else { return nil }
        return a.x - CGFloat(Wing.configuredWidth(store.fullLayout.groups, prefs: store.settings.wingDisplay)) - 26
    }

    // MARK: list panel

    func toggleList() {
        listPanel.isVisible ? hideList() : showList()
    }

    func showList() {
        if listPanel.isVisible { return }
        placeList()
        listPanel.orderFrontRegardless()
        settingsShortcut = SettingsListShortcut(panel: listPanel)
        store.listShownAt = Date().timeIntervalSince1970
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.hideList() }
        }
    }

    private func hideList() {
        listPanel.orderOut(nil)
        cardPanel.close()
        store.selected = nil
        settingsShortcut = nil
        store.listShownAt = nil
        if let m = outsideMonitor { NSEvent.removeMonitor(m) }
        outsideMonitor = nil
    }

    private func resizeList(_ contentHeight: CGFloat) {
        listHeight = min(max(contentHeight, 40), 560)
        if listPanel.isVisible { placeList() }
    }

    private func placeList() {
        let width: CGFloat = 380
        let anchor: NSRect = {
            if let a = notchAnchor { return NSRect(x: a.x, y: a.top - a.height, width: 0, height: a.height) }
            if let b = statusItem?.button, let w = b.window { return w.convertToScreen(b.convert(b.bounds, to: nil)) }
            return NSRect(x: 400, y: 800, width: 0, height: 0)
        }()
        let screen = NSScreen.screens.first { $0.frame.contains(anchor.origin) } ?? NSScreen.main
        var x = anchor.maxX - width + 40
        if let f = screen?.visibleFrame { x = min(max(x, f.minX + 8), f.maxX - width - 8) }
        listPanel.setFrame(NSRect(x: x, y: anchor.minY - 6 - listHeight, width: width, height: listHeight), display: true)
        cardPanel.place(nextTo: listPanel)
    }

    // MARK: menu

    private func showMenu(_ event: NSEvent) {
        let menu = NSMenu()
        let actions = AppActions.shared
        func item(_ title: String, _ action: Selector, on: Bool? = nil, enabled: Bool = true, tag: Int = 0) {
            let i = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            i.target = actions
            i.tag = tag
            i.isEnabled = enabled
            if let on { i.state = on ? .on : .off }
        }
        let settingsItem = menu.addItem(withTitle: SettingsText.window, action: #selector(SettingsWindow.show), keyEquivalent: ",")
        settingsItem.target = SettingsWindow.shared
        settingsItem.keyEquivalentModifierMask = .command
        let inst = HookInstaller()
        item(inst.isInstalled(.claude) ? Loc.t("Claude Code hooks installed — remove", "Хуки Claude Code установлены — удалить")
             : Loc.t("Install Claude Code hooks", "Установить хуки Claude Code"),
             #selector(AppActions.toggleHooks(_:)), tag: 0)
        item(inst.isInstalled(.codex) ? Loc.t("Codex hooks installed — remove", "Хуки Codex установлены — удалить")
             : Loc.t("Install Codex hooks", "Установить хуки Codex"),
             #selector(AppActions.toggleHooks(_:)), tag: 1)
        item(Loc.t("Answer requests from the notch", "Решать запросы из чёлки"), #selector(AppActions.toggleAnswer), on: AppSettings.shared.answerFromNotch)
        item(Loc.t("Sound when an agent is waiting", "Звук, когда агент ждёт"), #selector(AppActions.toggleSounds), on: AppSettings.shared.sounds)
        item(ToastText.menu, #selector(AppActions.toggleFinishToast), on: AppSettings.shared.finishToast)
        menu.addItem(.separator())
        item(Loc.t("Open at login", "Открывать при входе в систему"), #selector(AppActions.toggleLogin), on: SMAppService.mainApp.status == .enabled)
        item(AXIsProcessTrusted() ? Loc.t("Shrinking for menus is on", "Сжатие по меню включено")
             : Loc.t("Shrink when the menu reaches the notch…", "Сжимать, когда меню доходит до чёлки…"),
             #selector(AppActions.askAccessibility), enabled: !AXIsProcessTrusted())
        menu.addItem(.separator())
        menu.addItem(withTitle: Loc.t("Quit", "Выйти"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        NSMenu.popUpContextMenu(menu, with: event, for: wingHost)
    }

    private static func makePanel() -> KeyPanel {
        let p = KeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.hidesOnDeactivate = false
        return p
    }
}

/// A hosting view that takes every click itself instead of passing it to SwiftUI.
final class ClickHost: NSHostingView<AnyView> {
    var onClick: () -> Void = {}
    var onRightClick: (NSEvent) -> Void = { _ in }

    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        event.modifierFlags.contains(.control) ? onRightClick(event) : onClick()
    }
    override func rightMouseDown(with event: NSEvent) { onRightClick(event) }
}

@MainActor
final class AppActions: NSObject {
    static let shared = AppActions()

    @objc func askAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    @objc func toggleHooks(_ sender: NSMenuItem) {
        let vendor: Vendor = sender.tag == 0 ? .claude : .codex
        let inst = HookInstaller()
        do {
            if inst.isInstalled(vendor) {
                try inst.uninstall(vendor)
            } else {
                try inst.placeHelper(from: Self.bundledHelper, app: Self.appExecutable)
                try inst.install(vendor)
                if vendor == .codex { Self.say(Loc.t("Codex hooks written to ~/.codex/hooks.json", "Хуки Codex записаны в ~/.codex/hooks.json"), Self.codexTrustNote) }
            }
        } catch {
            Self.say(Loc.t("Could not change the hooks", "Не получилось изменить хуки"), error.localizedDescription)
        }
    }

    @objc func toggleAnswer() { AppSettings.shared.answerFromNotch.toggle() }
    @objc func toggleSounds() { AppSettings.shared.sounds.toggle() }

    @objc func toggleLogin() {
        let s = SMAppService.mainApp
        do {
            if s.status == .enabled { try s.unregister() } else { try s.register() }
        } catch {
            Self.say(Loc.t("Could not turn on open at login", "Не получилось включить автозапуск"), error.localizedDescription)
        }
    }

    static var codexTrustNote: String {
        Loc.t("Codex runs new hooks only after a review. Open Codex, type /hooks and mark the notch-hook hooks as trusted.",
              "Codex запускает новые хуки только после проверки. Откройте Codex, введите /hooks и отметьте хуки notch-hook как доверенные.")
    }

    /// The running app's own binary: the only process the helper will take a decision from.
    static var appExecutable: String { Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? CommandLine.arguments[0] }

    static var bundledHelper: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/notch-hook")
    }

    static func say(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}
