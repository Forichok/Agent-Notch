import AppKit
import Combine
import Foundation
import NotchCore

/// The prompt vault the picker and «Промпты» share. Edits are written to disk half a second after the last keystroke.
@MainActor
final class PromptStore: ObservableObject {
    static let shared = PromptStore()

    @Published private(set) var vault: PromptVault
    /// The snippet open in the settings editor.
    @Published var editing: UUID?
    /// The open tab of «Промпты»; the picker's ⌘E switches it.
    @Published var tab: SettingsPrompts.Tab = .library
    private let file: PromptVaultFile?
    private var pending: DispatchWorkItem?

    /// nil keeps everything in memory: snapshots and checks never touch the user's file.
    init(file: PromptVaultFile? = PromptVaultFile(), vault fixture: PromptVault? = nil) {
        self.file = file
        if let fixture {
            vault = fixture
        } else if let file, file.exists {
            if let loaded = file.load() {
                vault = loaded
            } else {
                // Never overwrite a file we could not read: move it aside and start clean.
                let aside = file.url.appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970))")
                try? FileManager.default.moveItem(at: file.url, to: aside)
                vault = PromptVault()
            }
        } else {
            vault = .starter
            if file != nil { scheduleSave() }
        }
        editing = vault.snippets.first?.id
    }

    func snippet(_ id: UUID?) -> PromptSnippet? { vault.snippets.first { $0.id == id } }

    @discardableResult
    func add(title: String = "", text: String = "") -> UUID {
        let s = PromptSnippet(title: title.isEmpty ? PromptText.untitled : title, text: text)
        change { $0.snippets.append(s) }
        editing = s.id
        return s.id
    }

    func duplicate(_ id: UUID) {
        guard let s = snippet(id), let i = vault.snippets.firstIndex(where: { $0.id == id }) else { return }
        let copy = PromptSnippet(title: s.title + PromptText.copySuffix, text: s.text)
        change { $0.snippets.insert(copy, at: i + 1) }
        editing = copy.id
    }

    func update(_ id: UUID, title: String? = nil, text: String? = nil) {
        guard let i = vault.snippets.firstIndex(where: { $0.id == id }) else { return }
        change {
            if let title { $0.snippets[i].title = title }
            if let text { $0.snippets[i].text = text }
        }
    }

    func remove(_ id: UUID) {
        let i = vault.snippets.firstIndex { $0.id == id }
        change { $0.remove(id) }
        if editing == id, let i {
            editing = vault.snippets.isEmpty ? nil : vault.snippets[min(i, vault.snippets.count - 1)].id
        }
    }

    func move(from source: IndexSet, to destination: Int) {
        change { $0.snippets.move(fromOffsets: source, toOffset: destination) }
    }

    func record(_ id: UUID) { change { $0.record(id) } }
    func resetStats() { change { $0.resetStats() } }

    /// Writes now instead of waiting: called when the app quits.
    func flush() {
        guard let pending else { return }
        pending.cancel()
        self.pending = nil
        write()
    }

    private func change(_ edit: (inout PromptVault) -> Void) {
        edit(&vault)
        scheduleSave()
    }

    private func scheduleSave() {
        guard file != nil else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.pending = nil; self?.write() } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func write() {
        guard let file else { return }
        do { try file.save(vault) } catch { NSLog("AgentsNotch: could not save prompts: \(error.localizedDescription)") }
    }
}
