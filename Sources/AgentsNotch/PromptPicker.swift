import AppKit
import SwiftUI
import NotchCore

@MainActor
final class PromptPickerModel: ObservableObject {
    enum Mode: Hashable { case prompts, skills }
    @Published var mode: Mode = .prompts { didSet { if mode != oldValue { selected = 0 } } }
    @Published var query = "" { didSet { if query != oldValue { selected = 0 } } }
    @Published var selected = 0
    @Published var trusted = AXIsProcessTrusted()
    /// The agent whose app is in front: its skills go first among equally used ones.
    var prefer: Vendor?
}

/// One row of the picker: a saved prompt, or a skill whose call gets pasted.
struct PickerItem: Identifiable {
    enum Kind { case prompt(PromptSnippet), skill(InstalledSkill) }
    let kind: Kind
    let uses: Int

    var id: String {
        switch kind { case .prompt(let p): p.id.uuidString; case .skill(let s): s.id }
    }
    var title: String {
        switch kind { case .prompt(let p): p.label; case .skill(let s): s.name }
    }
    var subtitle: String {
        switch kind {
        case .prompt(let p): p.text.replacingOccurrences(of: "\n", with: " ")
        case .skill(let s): s.invocation + (s.description.isEmpty ? "" : " — " + s.description)
        }
    }
    var vendor: Vendor? {
        if case .skill(let s) = kind { return s.vendor }
        return nil
    }
    var dimmed: Bool {
        if case .skill(let s) = kind { return s.enabled == false }
        return false
    }
    /// What lands in the field: the prompt itself, or the call with a space for arguments.
    var text: String {
        switch kind { case .prompt(let p): p.text; case .skill(let s): s.invocation + " " }
    }
    var help: String {
        switch kind { case .prompt(let p): p.text; case .skill(let s): s.description }
    }

    @MainActor
    static func list(_ model: PromptPickerModel, prompts: PromptStore, skills: SkillStore) -> [PickerItem] {
        switch model.mode {
        case .prompts:
            let counts = Dictionary(uniqueKeysWithValues: prompts.vault.stats().map { ($0.snippet.id, $0.total) })
            return prompts.vault.ranked(query: model.query).map { PickerItem(kind: .prompt($0), uses: counts[$0.id] ?? 0) }
        case .skills:
            return skills.skills.ranked(query: model.query, uses: { skills.use(of: $0).count }, prefer: model.prefer)
                .map { PickerItem(kind: .skill($0), uses: skills.use(of: $0).count) }
        }
    }
}

/// The prompt picker: a search box under the notch over whatever app is in front. ↩ pastes the prompt
/// into the field that had focus, ⌘↩ only copies it. The panel takes keys without activating the app,
/// so the frontmost app keeps its text cursor.
@MainActor
final class PromptPicker {
    static let width: CGFloat = 460
    private let store: PromptStore
    private let skills: SkillStore
    private let settings: AppSettings
    private let panel: KeyPanel
    private let model = PromptPickerModel()
    private var target: NSRunningApplication?
    private var height: CGFloat = 120
    private var keyMonitor: Any?
    private var outsideMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var trustTimer: Timer?

    init(store: PromptStore? = nil, skills: SkillStore? = nil, settings: AppSettings? = nil) {
        self.store = store ?? .shared
        self.skills = skills ?? .shared
        self.settings = settings ?? .shared
        panel = KeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.wantsKey = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
    }

    var isVisible: Bool { panel.isVisible }
    func toggle() { panel.isVisible ? close() : show() }

    func show() {
        guard !panel.isVisible else { return }
        let front = NSWorkspace.shared.frontmostApplication
        target = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        model.query = ""
        model.selected = 0
        model.trusted = AXIsProcessTrusted()
        model.prefer = Self.vendor(of: target)
        // Keeps the list fresh for the skills tab; cheap after the first scan.
        skills.refresh()
        // A fresh view each time, so the search field takes focus again. The mode stays as it was left.
        panel.contentView = NSHostingView(rootView: PromptPickerView(
            store: store, skills: skills, model: model, theme: settings.currentTheme,
            onHeight: { [weak self] h in self?.resize(h) },
            choose: { [weak self] s, paste in self?.choose(s, paste: paste) },
            grant: { [weak self] in
                self?.close()
                AppActions.shared.askAccessibility()
                AppActions.shared.openAccessibilitySettings()
            }))
        place()
        panel.makeKeyAndOrderFront(nil)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let window = event.windowNumber, code = event.keyCode, flags = event.modifierFlags
            let handled = MainActor.assumeIsolated {
                guard let self, window == self.panel.windowNumber else { return false }
                return self.handle(code, flags)
            }
            return handled ? nil : event
        }
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        // Access granted while the picker is open hides the note without reopening it.
        if !model.trusted {
            trustTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, AXIsProcessTrusted() else { return }
                    self.model.trusted = true
                    self.trustTimer?.invalidate()
                    self.trustTimer = nil
                }
            }
        }
    }

    func close() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        panel.contentView = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        keyMonitor = nil
        outsideMonitor = nil
        resignObserver = nil
        trustTimer?.invalidate()
        trustTimer = nil
    }

    private var results: [PickerItem] { PickerItem.list(model, prompts: store, skills: skills) }

    static func vendor(of app: NSRunningApplication?) -> Vendor? {
        let id = app?.bundleIdentifier?.lowercased() ?? ""
        if id.contains("anthropic") { return .claude }
        if id.contains("openai") { return .codex }
        return nil
    }

    private func handle(_ keyCode: UInt16, _ flags: NSEvent.ModifierFlags) -> Bool {
        let mods = flags.intersection([.command, .control, .option, .shift])
        let items = results
        switch (keyCode, mods) {
        case (53, _): close()
        case (48, []), (48, .shift): model.mode = model.mode == .prompts ? .skills : .prompts
        case (125, []), (45, .control): if !items.isEmpty { model.selected = min(model.selected + 1, items.count - 1) }
        case (126, []), (35, .control): model.selected = max(model.selected - 1, 0)
        case (36, []), (76, []): if items.indices.contains(model.selected) { choose(items[model.selected], paste: true) }
        case (36, .command), (76, .command): if items.indices.contains(model.selected) { choose(items[model.selected], paste: false) }
        case (45, .command):
            close()
            store.add(text: model.query)
            SettingsWindow.shared.open(.vault)
        case (14, .command), (43, .command):
            if items.indices.contains(model.selected) {
                switch items[model.selected].kind {
                case .prompt(let p): store.editing = p.id
                case .skill(let s): skills.selected = s.id
                }
            }
            store.tab = model.mode == .skills ? .skills : .library
            close()
            SettingsWindow.shared.open(.vault)
        default:
            guard mods == .command, let n = Self.digits[keyCode] else { return false }
            if items.indices.contains(n - 1) { choose(items[n - 1], paste: true) }
        }
        return true
    }

    /// ⌘1…⌘9 by physical key, so they work in any input language.
    private static let digits: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]

    /// Prompts count their insertions; skills are counted from the agent's own log once they run.
    private func choose(_ item: PickerItem, paste: Bool) {
        if case .prompt(let p) = item.kind { store.record(p.id) }
        let target = self.target
        close()
        if paste && AXIsProcessTrusted() {
            PromptPaster.paste(item.text, into: target, restore: settings.prompts.restoreClipboard)
        } else {
            PromptPaster.copy(item.text)
            target?.activate()
        }
    }

    private func resize(_ h: CGFloat) {
        height = ceil(h)
        if panel.isVisible { place() }
    }

    /// Centered under the menu bar (and so under the notch) of the screen with the pointer.
    private func place() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let f = screen?.visibleFrame else { return }
        panel.setFrame(NSRect(x: f.midX - Self.width / 2, y: f.maxY - 8 - height, width: Self.width, height: height), display: true)
    }
}

/// Pastes through the clipboard with a synthetic ⌘V, the only way that works in every app and terminal.
@MainActor
enum PromptPaster {
    static func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    static func paste(_ text: String, into app: NSRunningApplication?, restore: Bool) {
        let pb = NSPasteboard.general
        let saved = restore ? snapshot(pb) : nil
        copy(text)
        let mark = pb.changeCount
        if let app, !app.isActive { app.activate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            pressCommandV()
            guard let saved else { return }
            // Give the app time to read the clipboard; someone else may have written to it meanwhile.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                guard pb.changeCount == mark else { return }
                pb.clearContents()
                if !saved.isEmpty { pb.writeObjects(saved) }
            }
        }
    }

    private static func snapshot(_ pb: NSPasteboard) -> [NSPasteboardItem] {
        (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
    }

    private static func pressCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let v: CGKeyCode = 9
        let down = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

private struct PickerHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct PromptPickerView: View {
    @ObservedObject var store: PromptStore
    @ObservedObject var skills: SkillStore
    @ObservedObject var model: PromptPickerModel
    var theme: Theme = .terminal
    var onHeight: (CGFloat) -> Void = { _ in }
    var choose: (PickerItem, Bool) -> Void = { _, _ in }
    var grant: () -> Void = {}
    @FocusState private var focused: Bool

    static let rowHeight: CGFloat = 44
    static let visibleRows = 7

    var body: some View {
        let items = PickerItem.list(model, prompts: store, skills: skills)
        let selected = min(model.selected, max(items.count - 1, 0))
        let skillMode = model.mode == .skills
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: skillMode ? "wand.and.stars" : "text.quote").font(.system(size: 15, weight: .semibold)).foregroundStyle(dim)
                    .frame(width: 18)
                TextField(skillMode ? SkillText.search : PromptText.search, text: $model.query)
                    .textFieldStyle(.plain).font(.system(size: 16)).focused($focused)
                tabs
            }
            .padding(.horizontal, 14).frame(height: 46)
            Rectangle().fill(Ink.rule).frame(height: 0.5)
            if items.isEmpty {
                Text(empty).foregroundStyle(dim).frame(maxWidth: .infinity).padding(.vertical, 18)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { i, s in
                                row(s, index: i, on: i == selected).id(s.id)
                            }
                        }
                        .padding(6)
                    }
                    .scrollIndicators(items.count > Self.visibleRows ? .automatic : .never)
                    .frame(height: CGFloat(min(items.count, Self.visibleRows)) * Self.rowHeight + 12)
                    .onChange(of: model.selected) { _, i in
                        if items.indices.contains(i) { proxy.scrollTo(items[i].id) }
                    }
                }
            }
            if !model.trusted {
                HStack(spacing: 8) {
                    Image(systemName: "hand.raised.fill").foregroundStyle(Ink.waiting)
                    Text(PromptText.needsAccess).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button(PromptText.grant, action: grant).controlSize(.small)
                }
                .font(.system(size: 11)).padding(.horizontal, 14).padding(.vertical, 8)
                .background(Ink.waitingBg)
            }
            Rectangle().fill(Ink.rule).frame(height: 0.5)
            HStack(spacing: 14) {
                hint("⇥", (skillMode ? PromptText.title : SkillText.tab).lowercased())
                hint("↩", PromptText.insert)
                hint("⌘↩", PromptText.copy)
                hint("⌘E", skillMode ? PromptText.details : PromptText.edit)
                Spacer(minLength: 0)
                hint("esc", PromptText.close)
            }
            .padding(.horizontal, 14).frame(height: 28)
        }
        .frame(width: PromptPicker.width)
        // The list's theme: same surface, rim, inks and face.
        .themeSurface(theme)
        .themed(theme)
        .font(.system(size: 12, design: theme.design))
        .foregroundStyle(theme.id == .terminal ? AnyShapeStyle(.primary) : AnyShapeStyle(Ink.text))
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { g in Color.clear.preference(key: PickerHeightKey.self, value: g.size.height) })
        .onPreferenceChange(PickerHeightKey.self) { h in onHeight(h) }
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    private var empty: String {
        switch model.mode {
        case .prompts: store.vault.snippets.isEmpty ? PromptText.empty : PromptText.nothingFound
        case .skills: skills.skills.isEmpty ? (skills.scanning ? SkillText.scanning : SkillText.none) : PromptText.nothingFound
        }
    }

    /// «Prompts | Skills» on the right of the search field; ⇥ flips it too.
    private var tabs: some View {
        HStack(spacing: 2) {
            ForEach([(PromptPickerModel.Mode.prompts, PromptText.title), (.skills, SkillText.tab)], id: \.0) { mode, title in
                Text(title).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(model.mode == mode ? Ink.primaryText : dim)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(model.mode == mode ? AnyShapeStyle(Ink.primary) : AnyShapeStyle(Color.clear)))
                    .contentShape(Capsule())
                    .onTapGesture { model.mode = mode; focused = true }
            }
        }
        .padding(2)
        .background(Capsule().fill(Ink.pill))
    }

    private func row(_ s: PickerItem, index: Int, on: Bool) -> some View {
        HStack(spacing: 10) {
            if let vendor = s.vendor {
                if let icon = AppIconCache.image(vendor, dark: theme.scheme == .dark) { Image(nsImage: icon).resizable().frame(width: 18, height: 18) }
                else { Text(vendor == .claude ? "C" : "X").font(.system(size: 11, weight: .bold)).frame(width: 18) }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(s.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    .foregroundStyle(on ? AnyShapeStyle(Ink.primaryText) : AnyShapeStyle(Ink.strong))
                Text(s.subtitle).foregroundStyle(on ? Ink.primaryText : dim).lineLimit(1)
            }
            .opacity(s.dimmed ? 0.5 : 1)
            Spacer(minLength: 6)
            if s.uses > 0 { Text(PromptText.uses(s.uses)).font(.system(size: 11, design: .rounded)).foregroundStyle(on ? Ink.primaryText : dim) }
            if index < 9 {
                Text("⌘\(index + 1)").font(.system(size: 11, design: .rounded)).foregroundStyle(on ? Ink.primaryText : dim)
                    .frame(width: 26, alignment: .trailing)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Self.rowHeight)
        .background(RoundedRectangle(cornerRadius: max(theme.rowRadius, 4), style: theme.cornerStyle)
            .fill(on ? AnyShapeStyle(Ink.primary) : AnyShapeStyle(Color.clear)))
        .contentShape(Rectangle())
        .onHover { inside in if inside { model.selected = index } }
        .onTapGesture { choose(s, true) }
        .help(s.help)
    }

    private func hint(_ key: String, _ text: String?) -> some View {
        HStack(spacing: 4) {
            Text(key).font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundStyle(Ink.secondary)
            if let text { Text(text).font(.system(size: 10.5)).foregroundStyle(dim) }
        }
        .lineLimit(1).fixedSize()
    }
}
