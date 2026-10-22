import Combine
import Foundation

@MainActor
protocol KeepAwakeSystem {
    var permissionInstalled: Bool { get }
    func read() throws -> Bool
    func set(_ enabled: Bool) async throws -> Bool
    func configurePasswordless(_ enabled: Bool) async throws
    func verifyPasswordless() async throws -> Bool
}

enum KeepAwakeFailure: Error {
    case unavailable
    case cancelled
    case authorization(String)
    case notApplied
    case permissionNotApplied
    case passwordlessDenied(String)
}

@MainActor
final class KeepAwakeModel: ObservableObject {
    static let shared = KeepAwakeModel(system: MacSleepSystem())

    // nil means the OS state could not be read; it must not look like "off".
    @Published private(set) var enabled: Bool?
    @Published private(set) var busy = false
    @Published var error: Error?
    @Published private(set) var permissionInstalled = false
    @Published private(set) var passwordless: Bool?
    @Published var permissionError: Error?
    private let system: any KeepAwakeSystem
    private var timer: Timer?

    init(system: any KeepAwakeSystem) {
        self.system = system
        refresh()
    }

    func startMonitoring() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        guard !busy else { return }
        // Publish only real changes: this runs every few seconds and each write redraws the views that watch it.
        let read = try? system.read()
        if enabled != read { enabled = read }
        let installed = system.permissionInstalled
        if permissionInstalled != installed { permissionInstalled = installed }
        if !installed, passwordless != nil { passwordless = nil }
    }

    func setEnabled(_ requested: Bool) async {
        guard !busy, let enabled, enabled != requested else { return }
        busy = true
        error = nil
        defer { busy = false }
        var writeError: Error?
        do { passwordless = try await system.set(requested) }
        catch {
            writeError = error
            if case KeepAwakeFailure.passwordlessDenied = error { passwordless = false }
        }

        // Read even after a failed/cancelled command: another app may have changed the setting.
        do {
            self.enabled = try system.read()
            // A command can finish before IOKit's property catches up. Confirm the
            // requested state for up to one second, without repeating the write.
            if writeError == nil {
                for _ in 0..<10 {
                    if self.enabled == requested { break }
                    try await Task.sleep(for: .milliseconds(100))
                    self.enabled = try system.read()
                }
            }
        }
        catch { self.enabled = nil; self.error = error; return }

        if let writeError {
            if case KeepAwakeFailure.cancelled = writeError { return }
            error = writeError
        } else if self.enabled != requested {
            error = KeepAwakeFailure.notApplied
        }
    }

    func configurePasswordless(_ requested: Bool) async {
        guard !busy, permissionInstalled != requested else { return }
        busy = true
        permissionError = nil
        defer { busy = false }
        var writeError: Error?
        do { try await system.configurePasswordless(requested) }
        catch { writeError = error }
        permissionInstalled = system.permissionInstalled
        passwordless = nil
        enabled = try? system.read()
        if let writeError {
            if case KeepAwakeFailure.cancelled = writeError { return }
            permissionError = writeError
        } else if permissionInstalled != requested {
            permissionError = KeepAwakeFailure.permissionNotApplied
        } else if requested {
            do {
                passwordless = try await system.verifyPasswordless()
                enabled = try? system.read()
                if passwordless != true { permissionError = KeepAwakeFailure.permissionNotApplied }
            } catch { permissionError = error }
        }
    }

    func checkPasswordless() async {
        guard !busy, permissionInstalled else { return }
        busy = true
        permissionError = nil
        defer { busy = false }
        do { passwordless = try await system.verifyPasswordless(); enabled = try? system.read() }
        catch { passwordless = nil; permissionError = error }
    }
}
