import Foundation
import NotchCore

/// Words of the prompt vault: the picker under the notch and the «Промпты» settings section.
enum PromptText {
    static var menu: String { Loc.t("Insert a prompt…", "Вставить промпт…") }
    static var search: String { Loc.t("Search prompts", "Поиск промптов") }
    static var empty: String { Loc.t("No prompts yet. Press ⌘N to add one.", "Промптов пока нет. ⌘N — добавить.") }
    static var nothingFound: String { Loc.t("Nothing found", "Ничего не нашлось") }
    static var insert: String { Loc.t("insert", "вставить") }
    static var copy: String { Loc.t("copy", "копировать") }
    static var edit: String { Loc.t("edit", "изменить") }
    static var title: String { Loc.t("Prompts", "Промпты") }
    static var details: String { Loc.t("details", "подробнее") }
    static var close: String { Loc.t("close", "закрыть") }
    static var copied: String { Loc.t("Copied. Press ⌘V to paste.", "Скопировано. Нажмите ⌘V, чтобы вставить.") }
    static var needsAccess: String {
        Loc.t("To paste on its own, Agent Notch needs Accessibility access; for now it copies. Already on? After an update macOS may keep the switch on for the old build: remove Agent Notch with − and allow again.",
              "Чтобы вставлять сам, Agent Notch нужно разрешение в «Универсальном доступе»; пока промпт копируется. Уже включено? После обновления macOS может держать переключатель для старой сборки: удалите Agent Notch кнопкой − и разрешите снова.")
    }
    static var grant: String { Loc.t("Allow…", "Разрешить…") }
    static func uses(_ n: Int) -> String { "×\(n)" }

    // Settings
    static var library: String { Loc.t("Library", "Библиотека") }
    static var stats: String { Loc.t("Statistics", "Статистика") }
    static var untitled: String { Loc.t("New prompt", "Новый промпт") }
    static var copySuffix: String { Loc.t(" copy", " (копия)") }
    static var titleField: String { Loc.t("Name", "Название") }
    static var textField: String { Loc.t("Text that gets pasted", "Текст, который вставится") }
    static var add: String { Loc.t("Add a prompt", "Добавить промпт") }
    static var remove: String { Loc.t("Delete", "Удалить") }
    static var duplicate: String { Loc.t("Duplicate", "Дублировать") }
    static var noneSelected: String { Loc.t("Pick a prompt on the left or add a new one.", "Выберите промпт слева или добавьте новый.") }
    static func characters(_ n: Int) -> String { Loc.t("\(n) characters", "\(n) симв.") }
    static func used(_ n: Int, last: String?) -> String {
        let base = Loc.t(n == 1 ? "Inserted once" : "Inserted \(n) times", "Вставлен \(n) " + ruTimes(n))
        return last.map { base + " · " + Loc.t("last \($0)", "последний раз \($0)") } ?? base
    }
    /// 1 раз, 2 раза, 5 раз, 11 раз, 22 раза.
    static func ruTimes(_ n: Int) -> String {
        let tens = n % 100, ones = n % 10
        return (2...4).contains(ones) && !(12...14).contains(tens) ? "раза" : "раз"
    }
    static func hotkeyHint(_ key: String) -> String {
        Loc.t("\(key) opens the picker over any app; ↩ pastes into the field that has focus.",
              "\(key) открывает выбор поверх любого приложения; ↩ вставляет в поле, где стоит курсор.")
    }
    static var restore: String { Loc.t("Put the clipboard back after pasting", "Возвращать буфер обмена после вставки") }
    static var restoreHelp: String { Loc.t("The prompt goes through the clipboard for a moment", "Промпт на мгновение проходит через буфер обмена") }
    static var dragHint: String { Loc.t("Drag to reorder. Most used lately go first in the picker.", "Порядок — перетаскиванием. В выборе первыми идут частые за последнее время.") }

    static var total: String { Loc.t("Inserted in total", "Вставлено всего") }
    static var week: String { Loc.t("Last 7 days", "За 7 дней") }
    static var count: String { Loc.t("Prompts in the vault", "Промптов в хранилище") }
    static var activity: String { Loc.t("Last 14 days", "Последние 14 дней") }
    static var top: String { Loc.t("Used most", "Чаще всего") }
    static var never: String { Loc.t("Never used", "Ни разу не использованы") }
    static var noStats: String { Loc.t("Nothing inserted yet. Stats appear after the first prompt.", "Пока ничего не вставлено. Статистика появится после первого промпта.") }
    static func thisWeek(_ n: Int) -> String { Loc.t("+\(n) this week", "+\(n) за неделю") }
    static var resetStats: String { Loc.t("Reset statistics", "Сбросить статистику") }
    static var resetStatsConfirm: String { Loc.t("Forget every insertion? The prompts stay.", "Забыть все вставки? Сами промпты останутся.") }
    static var file: String { Loc.t("Stored in", "Хранится в") }
}
