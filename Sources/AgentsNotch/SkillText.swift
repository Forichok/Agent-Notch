import Foundation
import NotchCore

/// Words of the «Скиллы» tab in «Промпты».
enum SkillText {
    static var tab: String { Loc.t("Skills", "Скиллы") }
    static var search: String { Loc.t("Search skills", "Поиск скиллов") }
    static var all: String { Loc.t("All", "Все") }
    static var none: String { Loc.t("No skills found in ~/.claude, ~/.codex or your projects.", "Скиллов не нашлось ни в ~/.claude, ни в ~/.codex, ни в проектах.") }
    static var noneSelected: String { Loc.t("Pick a skill on the left.", "Выберите скилл слева.") }
    static var scanning: String { Loc.t("Looking for skills…", "Ищу скиллы…") }
    static var counting: String { Loc.t("Counting calls in Claude Code logs…", "Считаю вызовы в логах Claude Code…") }
    static func count(_ n: Int) -> String { Loc.t("\(n) skills", "Скиллов: \(n)") }
    static var refresh: String { Loc.t("Refresh", "Обновить") }

    static func source(_ s: InstalledSkill.Source) -> String {
        switch s {
        case .user: Loc.t("Yours", "Свои")
        case .system: Loc.t("Built in", "Встроенные")
        case .plugin: Loc.t("Plugins", "Плагины")
        case .project: Loc.t("Project", "Проект")
        }
    }
    static func vendor(_ v: Vendor) -> String { v == .claude ? "Claude Code" : "Codex" }
    static var off: String { Loc.t("Plugin is off", "Плагин выключен") }

    static var call: String { Loc.t("Call it with", "Вызов") }
    static var used: String { Loc.t("Used", "Использован") }
    static func usedTimes(_ n: Int, last: String?) -> String {
        let base = Loc.t(n == 1 ? "once" : "\(n) times", "\(n) " + PromptText.ruTimes(n))
        return last.map { base + " · " + Loc.t("last \($0)", "последний раз \($0)") } ?? base
    }
    static var neverUsed: String { Loc.t("Not called yet", "Ещё не вызывался") }
    static var codexUsage: String { Loc.t("Codex does not log skill calls", "Codex не записывает вызовы скиллов") }
    static var plugin: String { Loc.t("Plugin", "Плагин") }
    static var project: String { Loc.t("Project", "Проект") }
    static var folder: String { Loc.t("Folder", "Папка") }
    static var files: String { Loc.t("Files", "Файлы") }
    static var changed: String { Loc.t("Changed", "Изменён") }
    static var contents: String { Loc.t("SKILL.md", "SKILL.md") }
    static var open: String { Loc.t("Open SKILL.md", "Открыть SKILL.md") }
    static var reveal: String { Loc.t("Show in Finder", "Показать в Finder") }
    static var copyCall: String { Loc.t("Copy the call", "Скопировать вызов") }
    static var toVault: String { Loc.t("Add to prompts", "В промпты") }
    static var added: String { Loc.t("Added to prompts", "Добавлено в промпты") }
    static var usageHint: String {
        Loc.t("Calls are counted from Claude Code logs: the Skill tool and typed /commands.",
              "Вызовы считаются по логам Claude Code: инструмент Skill и набранные /команды.")
    }
    static var truncated: String { Loc.t("… the rest is in the file", "… остальное — в файле") }
}
