import AppKit
import Combine
import SwiftUI
import NotchCore

@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()
    /// Opens a section in a window that may already be on screen.
    static let route = PassthroughSubject<SettingsSection, Never>()
    private var window: NSWindow?

    func open(_ section: SettingsSection) {
        show()
        DispatchQueue.main.async { Self.route.send(section) }
    }

    @objc func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: SettingsView.size),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = SettingsText.title
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.contentView = NSHostingView(rootView: SettingsView().environmentObject(AppSettings.shared))
            window.minSize = NSSize(width: 720, height: 560)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        let wasVisible = window?.isVisible ?? false
        window?.makeKeyAndOrderFront(nil)
        if !wasVisible { SoundPlayer.shared.play(.settingsOpened) }
    }

    func windowWillClose(_ notification: Notification) { SoundPlayer.shared.play(.settingsClosed) }
}

/// System Settings layout with a sidebar and grouped forms.
struct SettingsView: View {
    static let size = NSSize(width: 780, height: 640)
    @EnvironmentObject private var settings: AppSettings
    @State var selection: SettingsSection = .appearance
    /// Snapshots pass an isolated vault; the app shows the real one.
    var prompts: PromptStore = .shared
    var skills: SkillStore = .shared

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsSection.allCases) { section in
                    Button {
                        if selection != section { selection = section; SoundPlayer.shared.play(.settingsSectionChanged, settings: settings) }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: section.icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                                .frame(width: 20, height: 20).background(section.tint, in: RoundedRectangle(cornerRadius: 5))
                            Text(section.title).foregroundStyle(selection == section ? Color.white : Color.primary)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(selection == section ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 10).padding(.top, 46).frame(width: 210)
            .background(Color.primary.opacity(0.035))
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                Text(selection.title).font(.system(size: 15, weight: .semibold)).padding(.leading, 30).padding(.top, 15).padding(.bottom, 2)
                Group {
                    switch selection {
                    case .appearance: SettingsAppearance(settings: settings)
                    case .list: SettingsListSection(settings: settings)
                    case .requests: SettingsRequests(settings: settings)
                    case .sounds: SettingsSounds(settings: settings)
                    case .vault: SettingsPrompts(settings: settings, prompts: prompts, skills: skills)
                    case .limits: SettingsLimits(settings: settings)
                    case .connection: SettingsConnection(settings: settings)
                    case .general: SettingsGeneral(settings: settings)
                    }
                }
                .formStyle(.grouped).scrollContentBackground(.hidden)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 720, minHeight: 560)
        .onReceive(SettingsWindow.route) { selection = $0 }
    }
}

/// A row title with one grey line of explanation under it.
struct SettingsLabel: View {
    let title: String
    var hint: String?
    init(_ title: String, hint: String? = nil) { self.title = title; self.hint = hint }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let hint { Text(hint).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
        }
    }
}

struct SettingsChoice<Choice: RawRepresentable & Hashable & CaseIterable>: View where Choice.RawValue == String {
    let title: String
    var hint: String?
    @Binding var value: Choice
    var only: [Choice]?
    var body: some View {
        Picker(selection: $value) {
            ForEach(only ?? Array(Choice.allCases), id: \.self) { choice in Text(SettingsText.name(choice.rawValue)).tag(choice) }
        } label: { SettingsLabel(title, hint: hint) }
    }
}

struct SettingsOrderEditor<P: RawRepresentable & Codable & Hashable & CaseIterable>: View where P.RawValue == String {
    @Binding var parts: [DisplayPart<P>]
    var body: some View {
        VStack(spacing: 9) {
            ForEach(Array(parts.enumerated()), id: \.element.id) { i, item in
                HStack {
                    Toggle(SettingsText.name(item.part.rawValue), isOn: Binding(
                        get: { parts.first { $0.part == item.part }?.enabled ?? false },
                        set: { value in
                            if let index = parts.firstIndex(where: { $0.part == item.part }) { parts[index].enabled = value }
                        }))
                    Spacer()
                    Button { parts = DisplayOrder.move(parts, from: i, to: i - 1) } label: { Image(systemName: "chevron.up") }
                        .disabled(i == 0).accessibilityLabel(SettingsText.moveUp)
                    Button { parts = DisplayOrder.move(parts, from: i, to: i + 1) } label: { Image(systemName: "chevron.down") }
                        .disabled(i == parts.count - 1).accessibilityLabel(SettingsText.moveDown)
                }
            }
        }.controlSize(.small)
    }
}

/// «Порядок…» opens this sheet over the section.
struct SettingsOrderSheet<P: RawRepresentable & Codable & Hashable & CaseIterable>: View where P.RawValue == String {
    let title: String
    @Binding var parts: [DisplayPart<P>]
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            Text(SettingsText.orderHelp).font(.caption).foregroundStyle(.secondary)
            SettingsOrderEditor(parts: $parts)
            HStack { Spacer(); Button(SettingsText.doneButton) { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20).frame(width: 340)
    }
}
