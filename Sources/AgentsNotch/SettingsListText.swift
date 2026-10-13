import NotchCore

enum SettingsListText {
    static func empty(minutes: Int) -> String {
        Loc.t("No sessions in the last \(minutes) min. Claude Code and Codex agents will show up here.",
              "Нет сессий за последние \(minutes) мин. Здесь появятся агенты Claude Code и Codex.")
    }
    static func allow(hint: Bool, shortcut: NotchCore.KeyboardShortcut) -> String {
        let word = Loc.t("Allow", "Разрешить")
        return hint ? word + " " + shortcut.display : word
    }
    static func deny(hint: Bool, shortcut: NotchCore.KeyboardShortcut) -> String {
        let word = Loc.t("Deny", "Отклонить")
        return hint ? word + " " + shortcut.display : word
    }
}
