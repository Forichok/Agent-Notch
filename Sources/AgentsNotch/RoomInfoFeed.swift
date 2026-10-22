import Combine
import Foundation
import NotchCore

/// What the agents' house shows besides the agents: each agent's context fill, the subscription limits and today's spend.
/// Limits and spend are reused from the app's UsageModel; the context fill is read here, from a bounded log tail
/// cached by file stamp, so the wallpaper never re-reads a log that did not change.
@MainActor
final class RoomInfoFeed {
    /// Context fill 0...1 by agent id, for the rows RoomWallpaper pushes.
    private(set) var contexts: [String: Double] = [:]
    private var agents: [String: Agent] = [:]
    private let cache = FileReadCache<ContextUsage?>()
    private let queue = DispatchQueue(label: "agents-notch.room-info", qos: .utility)
    private var reading = false
    private var timer: Timer?
    private var subs: Set<AnyCancellable> = []
    /// The last usage sent, as `room.setUsage(...)` takes it; empty until the limits are read.
    private(set) var lastUsage = ""
    private var send: (String) -> Void = { _ in }
    /// The Codex pet last sent (RoomCodexPet.stamp), "-" for none; checked again on the timer.
    private var petSent = ""
    private var petReading = false
    private var changed: () -> Void = {}

    func start(store: Store, changed: @escaping () -> Void, send: @escaping (String) -> Void) {
        self.changed = changed
        self.send = send
        let usage = store.usage, settings = store.settings
        usage.$limits.combineLatest(usage.$spend, usage.$spendComplete)
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] limits, spend, complete in
                self?.pushUsage(limits: limits, spend: spend, complete: complete, warning: settings.limits.warningPercent)
            }
            .store(in: &subs)
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.readContexts(); self?.pushPet() }
        }
        pushPet()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        subs.removeAll()
        agents = [:]
        contexts = [:]
        lastUsage = ""
        petSent = ""
    }

    /// The page reloaded: send everything again.
    func resend(store: Store) {
        lastUsage = ""
        petSent = ""
        pushPet()
        let usage = store.usage
        pushUsage(limits: usage.limits, spend: usage.spend, complete: usage.spendComplete, warning: store.settings.limits.warningPercent)
    }

    /// Called with the rows the wallpaper shows; new or moved logs are read right away, the rest on the timer.
    func track(_ shown: [Agent]) {
        var next: [String: Agent] = [:]
        for a in shown where a.logPath != nil { next[a.id] = a }
        let fresh = next.contains { agents[$0.key]?.logPath != $0.value.logPath }
        agents = next
        contexts = contexts.filter { next[$0.key] != nil }
        if fresh { readContexts() }
    }

    private func readContexts() {
        guard !reading, !agents.isEmpty else { return }
        reading = true
        let list = Array(agents.values), cache = cache
        queue.async { [weak self] in
            cache.retain(paths: Set(list.compactMap(\.logPath)))
            var values: [String: Double] = [:]
            for a in list {
                guard let path = a.logPath,
                      let usage = cache.read(path: path, load: { ContextFill.read(path: path, vendor: a.vendor) }),
                      usage.windowTokens > 0 else { continue }
                values[a.id] = (UsageView.fraction(usage.percent) * 100).rounded() / 100
            }
            let result = values
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.reading = false
                let kept = result.filter { self.agents[$0.key] != nil }
                if kept != self.contexts { self.contexts = kept; self.changed() }
            }
        }
    }

    /// Codex agents look like the user's own Codex pet when there is one (`~/.codex/pets`), decoded off the main thread.
    private func pushPet() {
        guard !petReading else { return }
        petReading = true
        let known = petSent
        queue.async { [weak self] in
            let pet = CodexPet.find()
            let stamp = pet.map(RoomCodexPet.stamp) ?? "-"
            let js: String? = stamp == known ? nil
                : pet.flatMap(RoomCodexPet.payload).map { "window.room && room.setCodexPet && room.setCodexPet(\($0)); true" }
                    ?? "window.room && room.setCodexPet && room.setCodexPet(null); true"
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.petReading = false
                    if let js { self.petSent = stamp; self.send(js) }
                }
            }
        }
    }

    private func pushUsage(limits: [VendorLimits], spend: [ProjectSpend], complete: Bool, warning: Int) {
        var u: [String: Any] = ["warning": warning]
        for l in limits {
            guard let used = UsageView.tightest(l) else { continue }
            var v: [String: Any] = ["used": (used * 10).rounded() / 10]
            v["updated"] = Int(l.updatedAt.timeIntervalSince1970) // how old the figures are, for the tank's tooltip
            if let w = l.windows.first(where: { $0.usedPercent == used }) {
                v["window"] = w.label
                if let r = w.resetsAt { v["resetsAt"] = Int(r.timeIntervalSince1970) }
            }
            // every window, for the tank's tooltip
            v["windows"] = l.windows.filter { $0.usedPercent.isFinite }.map { w -> [String: Any] in
                var o: [String: Any] = ["label": w.label, "used": (w.usedPercent * 10).rounded() / 10]
                if let r = w.resetsAt { o["resetsAt"] = Int(r.timeIntervalSince1970) }
                return o
            }
            u[l.vendor.rawValue] = v
        }
        let usd = spend.compactMap(\.usd).reduce(0, +)
        u["spend"] = ["usd": (usd * 100).rounded() / 100,
                      "partial": !complete || spend.contains { $0.isPartial || $0.usd == nil }]
        guard let data = try? JSONSerialization.data(withJSONObject: u, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8), json != lastUsage else { return }
        lastUsage = json
        send("window.room && room.setUsage && room.setUsage(\(json)); true")
    }
}
