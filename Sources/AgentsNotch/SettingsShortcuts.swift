import AppKit
import SwiftUI
import NotchCore

/// Captures only keys sent to this window, while Carbon shortcuts are suspended.
struct SettingsShortcuts: View {
    @ObservedObject var settings: AppSettings
    @State private var recording: ShortcutAction?
    @State private var monitor: Any?
    @State private var error: String?
    @State private var window: NSWindow?

    var body: some View {
        Section {
            ForEach(ShortcutAction.allCases, id: \.self) { action in
                LabeledContent(SettingsText.name(action == .list || action == .vault ? action.rawValue + ".key" : action.rawValue)) {
                    HStack {
                        Text(settings.shortcuts[action].display).font(.system(.body, design: .monospaced))
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                        Button(recording == action ? SettingsText.recording : SettingsText.record) { start(action) }
                            .frame(minWidth: 95)
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            if let error = settings.hotKeyError { Text(error).foregroundStyle(.red).font(.caption) }
        } header: {
            // One anchor view: modifiers on a Form section would repeat on every row.
            Text(SettingsText.keys)
                .background(SettingsWindowReader { if let found = $0 { window = found } })
                .onDisappear { stop() }
        } footer: {
            Text(recording == nil ? SettingsText.shortcutHelp : SettingsText.cancelRecord).font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            if let sender = notification.object as? NSWindow, sender === window { stop() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { notification in
            if let sender = notification.object as? NSWindow, sender === window { stop() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in stop() }
    }

    private func start(_ action: ShortcutAction) {
        stop()
        guard let window, window.isKeyWindow else { return }
        error = nil
        recording = action
        settings.isRecordingShortcut = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard settings.isRecordingShortcut, event.window === window else { return event }
            if event.keyCode == 53 { stop(); return nil }
            var modifiers: ShortcutModifiers = []
            if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
            if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
            if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
            if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
            let shortcut = NotchCore.KeyboardShortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers)
            if settings.setShortcut(shortcut, for: action) { stop() }
            else { error = SettingsText.invalidShortcut }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
        settings.isRecordingShortcut = false
    }
}

private struct SettingsWindowReader: NSViewRepresentable {
    let resolve: (NSWindow?) -> Void
    func makeNSView(context: Context) -> Reader { Reader(resolve: resolve) }
    func updateNSView(_ view: Reader, context: Context) {}
    final class Reader: NSView {
        let resolve: (NSWindow?) -> Void
        init(resolve: @escaping (NSWindow?) -> Void) { self.resolve = resolve; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let window = window
            DispatchQueue.main.async { [resolve] in resolve(window) }
        }
    }
}
