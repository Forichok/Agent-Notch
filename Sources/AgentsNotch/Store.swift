import AppKit
import NotchCore

/// Live agents read straight from the Claude Code and Codex session logs on this Mac, plus what the hooks report.
@MainActor
final class Store: ObservableObject {
    let settings: AppSettings
    init(settings: AppSettings? = nil) {
        self.settings = settings ?? .shared
        usage.readsCost = { [weak self] in self?.settings.rowPartShown(.cost) ?? false }
        usage.limitThreshold = { [weak self] in self?.settings.limits.warningPercent ?? 80 }
        usage.onSound = { [weak self] event in self?.play(event) }
    }

    @Published private(set) var agents: [Agent] = []
    @Published var selected: Agent.ID?
    @Published private(set) var hooks = HookState() {
        didSet {
            let first = hooks.pending.first(where: { $0.delivery == .waiting })?.ticket
            if first != hinted?.ticket { hinted = first.map { ($0, Date().timeIntervalSince1970) } }
        }
    }
    /// The request the hotkeys answer and since when it has been the one shown with them.
    private var hinted: (ticket: Int, since: Double)?
    /// When the list panel was last opened; nil while it is closed. Set by NotchController.
    var listShownAt: Double?
    /// Set by MenuWatcher when the frontmost app's menu reaches the wing.
    @Published var menuCramped = false
    var forceCramped = false
    /// Called when something new starts waiting for you.
    var onNewAsk: (() -> Void)?

    /// Announces agents that finish; NotchController shows its notices as a toast.
    let finisher = FinishNotifier()
    private var route = AnswerRoute()
    let usage = UsageModel()
    private let scanner = LogScanner()
    private let names = ProjectNames()
    private let queue = DispatchQueue(label: "agents-notch.scan", qos: .utility)
    private var polling = false
    private var pollCompletions: [() -> Void] = []
    private var timer: Timer?
    private var livenessTimer: Timer?
    private var retentionTimer: Timer?
    private var retentionExpiry: Date?
    private var watcher: FileWatcher?
    private var processWatcher: ProcessWatcher?
    private var watchedPaths: [String] = []
    private var watchedRoots: [String] = []
    private var pendingChanges: FileChanges?
    private var server: HookServer?
    private var deliverySounds: [Int: SoundEvent] = [:]
    private var deliveryAudit: [Int: (HookEvent, HookDecision)] = [:]
    private var fakeTicket = 1_000_000
    private var soundWatcher = SoundAgentWatcher()

    private func play(_ event: SoundEvent) { SoundPlayer.shared.play(event, settings: settings) }

    func visibilityChanged() {
        passHiddenRequests()
        soundWatcher.seed(shown)
    }

    /// Agents as drawn: the logs with open requests and on-screen prompts laid over.
    var shown: [Agent] { settings.visibleAgents(hooks.apply(to: agents, now: Date().timeIntervalSince1970, finishedRetention: Double(settings.appearance.finishedMinutes) * 60, project: names.name(for:)), store: self) }
    var projects: [ProjectNode] { settings.projects(from: shown) }
    var layout: WingLayout { Wing.configuredLayout(projects, cramped: forceCramped || menuCramped, prefs: settings.wingDisplay) }
    /// The layout as it would be drawn with room to spare: the width MenuWatcher has to keep clear.
    var fullLayout: WingLayout { Wing.configuredLayout(projects, cramped: false, prefs: settings.wingDisplay) }

    func useFixture(_ fixture: [Agent], asks: [HookEvent] = [], askAge: Double = 0, delivery: AnswerDelivery = .waiting, deliveries: [AnswerDelivery] = []) {
        agents = fixture
        var tickets: [Int] = []
        for e in asks {
            fakeTicket += 1
            _ = hooks.receive(e, ticket: fakeTicket, now: Date().timeIntervalSince1970 - askAge)
            tickets.append(fakeTicket)
        }
        for (index, ticket) in tickets.enumerated() {
            let status = deliveries.indices.contains(index) ? deliveries[index] : delivery
            if status != .waiting, let ask = hooks.pending.first(where: { $0.ticket == ticket }) {
                _ = hooks.send(ask)
                hooks.delivery(ticket, status)
            }
        }
    }

    func start() {
        usage.start()
        processWatcher = ProcessWatcher { [weak self] in
            Task { @MainActor in self?.poll(changes: .processes) }
        }
        watch(scanner.watchPaths)
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                if self?.watcher?.isWatching == false { self?.watchedPaths = [] }
                self?.processWatcher?.repair()
                self?.poll(changes: .processes)
            }
        }
        startHooks()
    }

    /// One scan now; the callback runs on the main actor after the agents are published.
    private func watch(_ paths: [String]) {
        let targets = FileWatcher.roots(for: paths, shallowPaths: scanner.watchRootPaths)
        guard paths != watchedPaths || targets != watchedRoots else { return }
        watchedPaths = paths
        watchedRoots = targets
        watcher = FileWatcher(paths: paths, shallowPaths: scanner.watchRootPaths) { [weak self] changes in
            Task { @MainActor in self?.poll(changes: changes) }
        }
    }

    private func updateLivenessTimer() {
        let live = agents.contains { $0.state != .done } || !hooks.pending.isEmpty || watcher?.isWatching != true
        if live, livenessTimer == nil {
            livenessTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.poll(changes: self.watcher?.isWatching == true ? .paths([]) : .full)
                }
            }
        } else if !live {
            livenessTimer?.invalidate()
            livenessTimer = nil
        }
        retentionTimer?.invalidate()
        retentionTimer = nil
        if !live, let expiry = retentionExpiry {
            let timer = Timer(fire: max(expiry, Date().addingTimeInterval(0.001)), interval: 0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.poll(changes: .paths([])) }
            }
            retentionTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func poll(then done: (() -> Void)? = nil, changes: FileChanges = .full) {
        if let done { pollCompletions.append(done) }
        if polling {
            pendingChanges = pendingChanges.map { $0.merging(changes) } ?? changes
            return
        }
        polling = true
        let scanner = scanner
        let retention = Double(settings.appearance.finishedMinutes) * 60
        queue.async {
            let next = scanner.poll(finishedRetention: retention, changes: changes)
            let paths = changes == .paths([]) ? nil : scanner.watchPaths
            let expiry = scanner.nextRetentionExpiry
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.polling = false
                if let next {
                    if next.sorted(by: { $0.id < $1.id }) != self.agents.sorted(by: { $0.id < $1.id }) { self.agents = next }
                }
                // Age failed requests even when the scanner has no changed snapshot.
                for ticket in self.hooks.expire(agents: self.agents, now: Date().timeIntervalSince1970) {
                    self.deliverySounds[ticket] = nil
                }
                if let next {
                    self.finisher.check(self.settings.listFilter.apply(self.hooks.apply(to: next, now: Date().timeIntervalSince1970, finishedRetention: retention, project: self.names.name(for:))))
                    for event in Set(self.soundWatcher.update(self.shown)) { self.play(event) }
                }
                if let paths { self.watch(paths) }
                self.retentionExpiry = expiry
                self.updateLivenessTimer()
                if let pending = self.pendingChanges {
                    self.pendingChanges = nil
                    self.poll(changes: pending)
                    return
                }
                let completions = self.pollCompletions
                self.pollCompletions.removeAll()
                for completion in completions { completion() }
            }
        }
    }

    // MARK: hooks

    private func startHooks() {
        let server = HookServer()
        server.onEvent = { [weak self] e, ticket in
            Task { @MainActor in self?.receive(e, ticket: ticket) }
        }
        server.onDelivery = { [weak self] ticket, status in
            Task { @MainActor in self?.receivedDelivery(ticket, status) }
        }
        server.onGone = { [weak self] ticket in
            Task { @MainActor in
                guard let self, let ask = self.hooks.pending.first(where: { $0.ticket == ticket }),
                      ask.delivery == .waiting else { return }
                self.hooks.resolve(ticket)
                self.soundWatcher.resolve(ask.event.agentKey)
            }
        }
        do {
            try server.start()
            self.server = server
        } catch {
            NSLog("agents-notch: hook socket failed: \(error)")
            play(.operationFailed)
        }
    }

    private func receivedDelivery(_ ticket: Int, _ status: AnswerDelivery) {
        let ask = hooks.pending.first { $0.ticket == ticket }
        hooks.delivery(ticket, status)
        guard status == .delivered || status == .notDelivered else { return }
        if let (event, decision) = deliveryAudit.removeValue(forKey: ticket) {
            Audit.record(event, decision, delivery: status)
        }
        if let ask { soundWatcher.resolve(ask.event.agentKey) }
        let sound = deliverySounds.removeValue(forKey: ticket)
        if ask?.delivery == .sent {
            if status == .notDelivered { play(.operationFailed) }
            else if let sound { play(sound) }
        }
    }

    private func receive(_ e: HookEvent, ticket: Int?) {
        try? ConnectionReceipt(installer: HookInstaller()).record(e.vendor)
        let receivedTicket = ticket
        var ticket = ticket
        let now = Date().timeIntervalSince1970
        let handedBack = ticket != nil && route.isHandedBack(e, now: now)
        // A question already sent back to the agent's window must not come back through its PermissionRequest.
        if let t = ticket, handedBack { server?.handBack(t); ticket = nil }
        else if ticket != nil { route.noteRouted(e, now: now) }
        if let t = ticket, settings.listFilter.shouldPass(e, project: names.name(for: e.cwd), answerFromNotch: settings.answerFromNotch,
                                                         owner: agents.first { $0.id == e.agentKey }) {
            server?.handBack(t)
            ticket = nil
        }
        if e.name == "SubagentStop", e.agentId == nil { return }
        let wasWaiting = hooks.pending.count
        let stale = hooks.receive(e, ticket: ticket, now: Date().timeIntervalSince1970)
        for ticket in stale { server?.handBack(ticket) }
        if e.name == "UserPromptSubmit" {
            soundWatcher.resume(e.agentKey)
        } else if !stale.isEmpty || ["Stop", "SessionEnd", "SubagentStop"].contains(e.name) {
            soundWatcher.resolve(e.agentKey)
        }
        if e.name == "PostToolUse", !hooks.pending.contains(where: { $0.event.agentKey == e.agentKey }) {
            soundWatcher.finishedTool(e)
        }
        updateLivenessTimer()
        let owner = agents.first { $0.id == e.agentKey }
        let visible = owner.map { settings.listFilter.includes(vendor: $0.vendor, project: $0.project, cwd: $0.cwd) }
            ?? settings.listFilter.includes(vendor: e.vendor, project: names.name(for: e.cwd), cwd: e.cwd)
        // A fresh permission handled in the agent's window still starts a new waiting event.
        // The permission after handing back a question/plan is the same request.
        if e.isPermission, ticket == nil, !handedBack, visible {
            if let event = soundWatcher.request(e, ticket: receivedTicket) { play(event) }
        }
        // A held request always has a row; a prompt shown elsewhere only matters for agents in the list.
        if hooks.pending.count > wasWaiting
            || (e.isPromptShown && settings.listFilter.includes(vendor: e.vendor, project: names.name(for: e.cwd), cwd: e.cwd)) {
            if let event = soundWatcher.request(e, ticket: receivedTicket) { play(event) }
            onNewAsk?()
        }
    }

    /// The human's answer from the notch. `.pass` hands the question back to the agent's own window.
    func decide(_ p: PendingAsk, _ d: HookDecision) {
        guard hooks.send(p) else { return }
        // Hand-back prints no decision and needs no stdout receipt.
        if d == .pass {
            hooks.resolve(p.ticket)
            soundWatcher.resolve(p.event.agentKey)
            Audit.record(p.event, d)
            server?.handBack(p.ticket)
            play(.handedBack)
            return
        }
        deliverySounds[p.ticket] = SoundEvent.decision(d, for: p.event)
        deliveryAudit[p.ticket] = (p.event, d)
        if let server { server.answer(p.ticket, d, toolUseID: p.toolUseID) }
        else { receivedDelivery(p.ticket, .notDelivered) }
    }

    /// "Всегда": allow and keep the rule. Claude gets it in the reply; for Codex the app writes the rule file and the reply is a plain allow.
    func decideAlways(_ p: PendingAsk) {
        guard hooks.pending.contains(where: { $0.ticket == p.ticket && $0.toolUseID == p.toolUseID && $0.delivery == .waiting }), !p.event.needsClick, let rule = AlwaysRule.suggest(for: p.event) else { return }
        if p.event.vendor == .codex {
            if let prefix = rule.prefix {
                do { try CodexRules.add(prefix: prefix, home: FileManager.default.homeDirectoryForCurrentUser) }
                catch { NSLog("agents-notch: codex rule failed: \(error)"); play(.operationFailed); return }
            }
            guard hooks.send(p) else { return }
            deliveryAudit[p.ticket] = (p.event, .allowAlways(rule))
            deliverySounds[p.ticket] = .alwaysAllowed
            if let server { server.answer(p.ticket, .allow, toolUseID: p.toolUseID) }
            else { receivedDelivery(p.ticket, .notDelivered) }
        } else {
            decide(p, .allowAlways(rule))
        }
    }

    /// The chosen answers of a question, sent as the allow that carries them.
    func answer(_ p: PendingAsk, _ answers: [String: String]) {
        guard let d = HookDecision.answer(p.event, answers) else { return }
        decide(p, d)
    }

    func approvePlan(_ p: PendingAsk) {
        guard let d = HookDecision.approvePlan(p.event) else { return }
        decide(p, d)
    }

    func returnPlan(_ p: PendingAsk, feedback: String) {
        decide(p, HookDecision.returnPlan(feedback: feedback))
    }

    /// The hotkeys answer only the request the open list has shown with the hint for at least half a second,
    /// so a keypress never lands on a request that just appeared or one nobody has seen. Never allows a click-only request.
    func decideByHotkey(_ d: HookDecision) -> Bool {
        let now = Date().timeIntervalSince1970
        guard let shownAt = listShownAt, let p = hooks.pending.first(where: { $0.delivery == .waiting }), let h = hinted, h.ticket == p.ticket,
              now - max(shownAt, h.since) >= 0.5, !p.event.isQuestion, !p.event.isPlan, d != .allow || !p.event.needsClick else { return false }
        decide(p, d)
        return true
    }

    func dismiss(_ ask: PendingAsk) {
        guard hooks.pending.contains(where: { $0.ticket == ask.ticket && $0.delivery == .notDelivered }) else { return }
        hooks.resolve(ask.ticket)
        deliverySounds[ask.ticket] = nil
    }

    // MARK: chat

    func select(_ agent: Agent) { selected = agent.id }

    var jumpScreen: () -> NSScreen? = { nil }
    private let jumpToast = JumpToast()

    func open(_ agent: Agent) {
        play(.agentOpened)
        let screen = NSApp.currentEvent?.window?.screen ?? jumpScreen()
            ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
        Opener.open(agent: JumpResolver.owner(of: agent, in: shown)) { [weak self] command, terminalOrigin in
            MainActor.assumeIsolated {
                guard let self, let screen else { return }
                self.jumpToast.show(command: command, terminalOrigin: terminalOrigin, screen: screen, settings: self.settings)
            }
        }
    }
}

/// Every decision made in the notch, one JSON line each, in ~/Library/Application Support/AgentsNotch/decisions.jsonl.
enum Audit {
    private static let lock = NSLock()
    private static let maxBytes = 1_048_576

    static func record(_ e: HookEvent, _ d: HookDecision, delivery: AnswerDelivery? = nil) {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AgentsNotch/decisions.jsonl")
        var row: [String: Any] = ["at": ISO8601DateFormatter().string(from: Date()), "decision": d.name,
                                  "vendor": e.vendor.rawValue, "session": e.agentKey, "tool": e.tool ?? "", "detail": e.detail ?? "",
                                  "cwd": e.cwd ?? "", "tool_use_id": e.toolUseID ?? ""]
        row["delivery"] = delivery?.rawValue
        guard var line = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return }
        line.append(0x0A)
        guard line.count <= maxBytes else { return }
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Keep the lock on a separate inode: rotation replaces the log itself.
            let fd = open(url.appendingPathExtension("lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
            guard fd >= 0 else { return }
            defer { close(fd) }
            guard flock(fd, LOCK_EX) == 0 else { return }
            defer { flock(fd, LOCK_UN) }
            if fm.fileExists(atPath: url.path) {
                let h = try FileHandle(forWritingTo: url)
                defer { try? h.close() }
                let size = try h.seekToEnd()
                if size <= UInt64(maxBytes - line.count) {
                    try h.write(contentsOf: line)
                    return
                }
                try h.close()
                let backup = url.appendingPathExtension("1")
                if fm.fileExists(atPath: backup.path) { try fm.removeItem(at: backup) }
                try fm.moveItem(at: url, to: backup)
            }
            try line.write(to: url, options: .atomic)
        } catch {
            // Logging must not prevent the decision from reaching the agent.
        }
    }
}
