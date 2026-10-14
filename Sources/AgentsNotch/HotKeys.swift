import Carbon.HIToolbox
import Combine
import Foundation
import NotchCore

/// Carbon registration does not need Accessibility; edits replace the old registrations.
@MainActor
final class HotKeys {
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var changes: AnyCancellable?
    private static var actions: [UInt32: @MainActor () -> Void] = [:]

    init(settings supplied: AppSettings? = nil, allow: @escaping @MainActor () -> Void,
         deny: @escaping @MainActor () -> Void, list: @escaping @MainActor () -> Void, vault: @escaping @MainActor () -> Void) {
        let settings = supplied ?? .shared
        Self.actions = [1: allow, 2: deny, 3: list, 4: vault]
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                    MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                  id.signature == OSType(0x414E4F54) else { return OSStatus(eventNotHandledErr) }
            let n = id.id
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKeys.actions[n]?() } }
            return noErr
        }, 1, &spec, nil, &handler)
        changes = settings.$shortcuts.combineLatest(settings.$isRecordingShortcut)
            .sink { [weak self, weak settings] prefs, recording in
                guard let self, let settings else { return }
                self.unregister()
                guard !recording else { return }
                var failed = false
                for (i, action) in ShortcutAction.allCases.enumerated() {
                    let key = prefs[action]
                    guard key.isValid else { failed = true; continue }
                    var ref: EventHotKeyRef?
                    let status = RegisterEventHotKey(key.keyCode, Self.carbon(key.modifiers),
                        EventHotKeyID(signature: OSType(0x414E4F54), id: UInt32(i + 1)), GetApplicationEventTarget(), 0, &ref)
                    if status == noErr, let ref { self.refs.append(ref) } else { failed = true }
                }
                settings.hotKeyError = failed ? SettingsText.hotKeyFailed : nil
            }
    }

    private func unregister() { refs.forEach { UnregisterEventHotKey($0) }; refs.removeAll() }

    private static func carbon(_ modifiers: ShortcutModifiers) -> UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.control) { result |= UInt32(controlKey) }
        if modifiers.contains(.option) { result |= UInt32(optionKey) }
        if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        if modifiers.contains(.command) { result |= UInt32(cmdKey) }
        return result
    }

    deinit {
        refs.forEach { UnregisterEventHotKey($0) }
        if let handler { RemoveEventHandler(handler) }
    }
}

/// Reserve ⌘, only for the lifetime of the open list.
@MainActor
final class SettingsCommandKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private static var open: (@MainActor () -> Void)?

    init(open: @escaping @MainActor () -> Void) {
        Self.open = open
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                    MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                  id.signature == OSType(0x414E5347) else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async { MainActor.assumeIsolated { SettingsCommandKey.open?() } }
            return noErr
        }, 1, &spec, nil, &handler)
        RegisterEventHotKey(43, UInt32(cmdKey), EventHotKeyID(signature: OSType(0x414E5347), id: 1),
                           GetApplicationEventTarget(), 0, &ref)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }
}
