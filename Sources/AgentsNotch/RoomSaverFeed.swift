import Combine
import Foundation
import NotchCore

/// Hands the agents' house over to the screen saver (Agent Notch House.saver), which runs in another process:
/// while the saver is installed, the house is written to HouseSnapshot's file on every change and every
/// `HouseSnapshot.heartbeat` seconds, so the saver tells a running app from a gone one.
@MainActor
final class RoomSaverFeed {
    private let store: Store
    private let info = RoomInfoFeed()
    private let file = HouseSnapshot.url(home: HouseSnapshot.realHome)
    private var subs: Set<AnyCancellable> = []
    private var timer: Timer?
    private var feeding = false
    private var last: HouseSnapshot?

    init(store: Store) { self.store = store }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: HouseSnapshot.heartbeat, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()
    }

    /// Called on quit: the saver shows an empty house right away instead of waiting for the file to go stale.
    func stop() {
        timer?.invalidate()
        timer = nil
        stopFeeding()
    }

    /// The saver can be installed or removed at any time; the feed starts and stops with it.
    private func tick() {
        let installed = !HouseSnapshot.installedSavers(home: HouseSnapshot.realHome).isEmpty
        if installed, !feeding { startFeeding() } else if !installed, feeding { stopFeeding() }
        if feeding { write(force: true) }
    }

    private func startFeeding() {
        feeding = true
        store.$agents.combineLatest(store.$hooks)
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.write() }
            .store(in: &subs)
        AppSettings.shared.$room.dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.write() } }
            .store(in: &subs)
        info.start(store: store, changed: { [weak self] in self?.write() }, send: { [weak self] _ in self?.write() })
    }

    private func stopFeeding() {
        guard feeding else { return }
        feeding = false
        subs.removeAll()
        info.stop()
        last = nil
        try? FileManager.default.removeItem(at: file)
    }

    /// Writes the house when it changed, or anyway on the heartbeat so its date stays fresh.
    private func write(force: Bool = false) {
        guard feeding else { return }
        info.track(store.shown)
        let prefs = AppSettings.shared.room
        let now = HouseSnapshot(agents: RoomWallpaper.rows(store.shown, contexts: info.contexts),
                                usage: info.lastUsage.isEmpty ? nil : info.lastUsage, config: prefs.pageConfig,
                                fps: RoomWallpaper.fps, written: Date())
        if !force, let last, last.sameHouse(as: now) { return }
        guard let data = now.encoded() else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            last = now
        } catch {
            NSLog("agents-notch: house snapshot not written: \(error)")
        }
    }
}
