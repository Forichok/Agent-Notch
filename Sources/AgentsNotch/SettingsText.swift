import Foundation
import SwiftUI
import NotchCore

/// English by default, Russian when the system is Russian (see `Loc`). Plain words: no hooks, chips, effort or worktree in what people read.
enum SettingsText {
    static var window: String { Loc.t("Settings…", "Настройки…") }
    static var title: String { Loc.t("Settings", "Настройки") }

    // Внешний вид
    static var presetHelp: String { Loc.t("A preset sets up the row, the list, limits and the card at once.", "Пресет сразу настраивает строку, список, лимиты и карточку.") }
    static var own: String { Loc.t("Custom", "Своё") }
    static var marks: String { Loc.t("Agent icons", "Значки агентов") }
    static var markSize: String { Loc.t("Size", "Размер") }
    static var inRow: String { Loc.t("In the agent row", "В строке агента") }
    static var order: String { Loc.t("Order…", "Порядок…") }
    static var orderTitle: String { Loc.t("Row order", "Порядок в строке") }
    static var cardOrderTitle: String { Loc.t("Card order", "Порядок в карточке") }
    static var orderHelp: String { Loc.t("Turn on what you need and arrange it with the arrows.", "Включите нужное и расставьте стрелками.") }
    static var doneButton: String { Loc.t("Done", "Готово") }
    static var card: String { Loc.t("Agent card", "Карточка агента") }
    static var cardHelp: String { Loc.t("Opens when you click an agent.", "Открывается по клику на агента.") }
    static var cardBlocks: String { Loc.t("Blocks…", "Блоки…") }
    static var rowHints: [RowPart: String] { Loc.isRussian ? [
        .model: "Например, opus или gpt-6.1",
        .activity: "Последняя команда или файл",
        .branch: "Ветка git, в которой работает агент",
        .runningTime: "Сколько агент уже работает",
        .context: "Кольцо: сколько памяти разговора занято",
        .cost: "Примерная цена сессии",
    ] : [
        .model: "For example, opus or gpt-6.1",
        .activity: "The latest command or file",
        .branch: "The git branch the agent works in",
        .runningTime: "How long the agent has been working",
        .context: "Ring: how much of the conversation memory is used",
        .cost: "Approximate session cost",
    ] }

    // Список
    static var sorting: String { Loc.t("Agent order", "Порядок агентов") }
    static var groupProjects: String { Loc.t("Group by project", "Группировать по проектам") }
    static var tree: String { Loc.t("Subagents", "Субагенты") }
    static var treeHelp: String { Loc.t("Helpers the agent started on its own", "Помощники, которых агент запустил сам") }
    static var showFinished: String { Loc.t("Show finished agents", "Показывать завершённых") }
    static var finished: String { Loc.t("Keep finished agents for", "Сколько держать завершённых") }
    static func minutes(_ n: Int) -> String { "\(n) " + Loc.t("min", "мин") }
    static var titleSource: String { Loc.t("Agent name", "Название агента") }
    static var vendors: String { Loc.t("Whose agents to show", "Чьих агентов показывать") }
    static var wing: String { Loc.t("Next to the notch", "Рядом с чёлкой") }
    static var wingContent: String { Loc.t("What is shown", "Что видно") }
    static var maxMarks: String { Loc.t("Icons before a counter", "Значков до счётчика") }
    static var maxMarksHelp: String { Loc.t("With more agents than this, a number replaces the icons", "Если агентов больше, вместо значков появится число") }
    static var grouping: String { Loc.t("Group icons", "Группировать значки") }
    static var separate: String { Loc.t("Subagents as separate icons", "Субагенты отдельными значками") }

    // Запросы
    static var answer: String { Loc.t("Answer right in the notch", "Отвечать прямо в чёлке") }
    static var answerHelp: String { Loc.t("Allow or deny without switching to the terminal", "Разрешить или отклонить, не переключаясь в терминал") }
    static var openRequest: String { Loc.t("Open the list when an agent is waiting", "Открывать список, когда агент ждёт") }
    static var sounds: String { Loc.t("Sound when an agent is waiting", "Звук, когда агент ждёт") }
    static var sound: String { Loc.t("Which sound", "Какой звук") }
    static var listen: String { Loc.t("Play", "Послушать") }
    static var keys: String { Loc.t("Keyboard shortcuts", "Горячие клавиши") }
    static var record: String { Loc.t("Record", "Записать") }
    static var recording: String { Loc.t("Press a shortcut…", "Нажмите сочетание…") }
    static var cancelRecord: String { Loc.t("Esc to cancel", "Esc — отмена") }
    static var invalidShortcut: String { Loc.t("Use a key with ⌃, ⌥ or ⌘; shortcuts must not repeat.", "Нужна клавиша с ⌃, ⌥ или ⌘; сочетания не должны повторяться.") }
    static var shortcutHelp: String { Loc.t("Shortcuts only answer the request shown in the notch. Dangerous commands need a click.", "Клавиши отвечают только на запрос, который виден в чёлке. Опасные команды — только кликом.") }
    static var hotKeyFailed: String { Loc.t("Could not register the shortcut. Another app may be using it.", "Не удалось занять сочетание. Возможно, его использует другое приложение.") }

    // Лимиты
    static var chips: String { Loc.t("Show remaining limit", "Показывать остаток лимита") }
    static var warning: String { Loc.t("Warn when used up to", "Предупреждать, когда израсходовано") }
    static var windows: String { Loc.t("Which limits", "Какие лимиты") }
    static var limitVendors: String { Loc.t("For whom", "Для кого") }

    // Подключение
    static var connected: String { Loc.t("Connected", "Подключено") }
    static var notConnected: String { Loc.t("Not connected", "Не подключено") }
    static var connect: String { Loc.t("Connect", "Подключить") }
    static var disconnect: String { Loc.t("Disconnect", "Отключить") }
    static var connectHelp: String { Loc.t("Without a connection agents are visible, but you can't answer requests from the notch.", "Без подключения агенты видны, но отвечать на запросы из чёлки нельзя.") }
    static var trust: String { Loc.t("In Codex, type /hooks once and mark notch-hook as trusted.", "В Codex один раз наберите /hooks и отметьте notch-hook как доверенный.") }
    static var windowsAccess: String { Loc.t("Window access", "Доступ к окнам") }
    static var windowsAccessHelp: String { Loc.t("Needed so «Open» switches to the agent's window", "Нужен, чтобы «Открыть» переключал на окно агента") }
    static var granted: String { Loc.t("Granted", "Разрешён") }
    static var requestAccess: String { Loc.t("Allow…", "Разрешить…") }
    static var hidden: String { Loc.t("Hidden projects", "Скрытые проекты") }
    static var hiddenHelp: String { Loc.t("Agents from these folders are not shown anywhere", "Агенты из этих папок не показываются нигде") }
    static var emptyHidden: String { Loc.t("Nothing hidden yet", "Пока ничего не скрыто") }
    static var projectPath: String { Loc.t("Project folder path", "Путь к папке проекта") }
    static var add: String { Loc.t("Add", "Добавить") }
    static var remove: String { Loc.t("Remove", "Убрать") }
    static var operationFailed: String { Loc.t("Could not change the settings", "Не получилось изменить настройки") }

    // Общие
    static var login: String { Loc.t("Open at login", "Запускать при входе в систему") }
    static var loginApproval: String { Loc.t("Approve the login item in System Settings.", "Подтвердите автозапуск в системных настройках.") }
    static var resetAll: String { Loc.t("Reset all settings", "Сбросить все настройки") }
    static var resetAllHelp: String { Loc.t("Returns everything to the first launch, except the connection", "Вернёт всё как при первом запуске, кроме подключения") }
    static var resetButton: String { Loc.t("Reset…", "Сбросить…") }
    static var resetConfirm: String { Loc.t("Reset all settings?", "Сбросить все настройки?") }
    static var resetConfirmButton: String { Loc.t("Reset", "Сбросить") }
    static var cancel: String { Loc.t("Cancel", "Отмена") }
    static var about: String { Loc.t("About", "О приложении") }
    static var license: String { Loc.t("MIT License", "Лицензия MIT") }
    static var github: String { Loc.t("GitHub link coming later", "Ссылка на GitHub появится позже") }
    static var version: String { Loc.t("Version", "Версия") }

    static var moveUp: String { Loc.t("Up", "Выше") }
    static var moveDown: String { Loc.t("Down", "Ниже") }
    static let claude = "Claude"
    static let codex = "Codex"
    static let claudeCode = "Claude Code"
    static var light: String { Loc.t("Light model", "Лёгкая модель") }
    static var regular: String { Loc.t("Regular model", "Обычная модель") }

    static let namesRu = [
        "appearance": "Внешний вид", "list": "Список", "requests": "Запросы", "limits": "Лимиты",
        "connection": "Подключение", "general": "Общие",
        "brief": "Кратко", "detailed": "Подробно", "everything": "Всё",
        "dots": "Точки", "logos": "Логотипы", "logosMono": "Логотипы цветом состояния", "letters": "Буквы",
        "small": "Мелкий", "medium": "Средний", "large": "Крупный", "always": "Всегда", "nearLimit": "Когда мало", "never": "Никогда",
        "marks": "Только значки", "counts": "Значки и числа", "projects": "Названия проектов",
        "project": "Проект", "vendor": "Агент", "session": "Имя сессии", "firstPrompt": "Первый запрос", "branch": "Ветка",
        "attention": "Сначала ждущие", "recent": "Сначала новые", "name": "По имени",
        "auto": "Авто", "expanded": "Все", "collapsed": "Свёрнуты", "hidden": "Не показывать",
        "short": "5 часов", "weekly": "Неделя",
        "allow": "Разрешить", "deny": "Отклонить", "list.key": "Открыть список",
        "statusMark": "Значок", "title": "Название", "model": "Модель", "effort": "Режим размышлений", "worktree": "Папка и ветка",
        "activity": "Что агент делает сейчас", "runningTime": "Время работы", "context": "Контекст", "cost": "Стоимость",
        "done": "Сделано", "remaining": "Осталось", "files": "Файлы", "log": "Лог", "commands": "Команды и тесты",
        "lastMessage": "Последнее сообщение", "errors": "Ошибки", "modelTime": "Модель и время", "contextCost": "Контекст и стоимость",
        "working": "Работает", "waiting": "Ждёт", "error": "Ошибка",
    ]
    static let namesEn = [
        "appearance": "Appearance", "list": "List", "requests": "Requests", "limits": "Limits",
        "connection": "Connection", "general": "General",
        "brief": "Brief", "detailed": "Detailed", "everything": "Everything",
        "dots": "Dots", "logos": "Logos", "logosMono": "Logos in status color", "letters": "Letters",
        "small": "Small", "medium": "Medium", "large": "Large", "always": "Always", "nearLimit": "When low", "never": "Never",
        "marks": "Icons only", "counts": "Icons and numbers", "projects": "Project names",
        "project": "Project", "vendor": "Agent", "session": "Session name", "firstPrompt": "First prompt", "branch": "Branch",
        "attention": "Waiting first", "recent": "Newest first", "name": "By name",
        "auto": "Auto", "expanded": "All", "collapsed": "Collapsed", "hidden": "Hidden",
        "short": "5 hours", "weekly": "Week",
        "allow": "Allow", "deny": "Deny", "list.key": "Open the list",
        "statusMark": "Icon", "title": "Name", "model": "Model", "effort": "Thinking mode", "worktree": "Folder and branch",
        "activity": "What the agent is doing", "runningTime": "Running time", "context": "Context", "cost": "Cost",
        "done": "Done", "remaining": "Remaining", "files": "Files", "log": "Log", "commands": "Commands and tests",
        "lastMessage": "Last message", "errors": "Errors", "modelTime": "Model and time", "contextCost": "Context and cost",
        "working": "Working", "waiting": "Waiting", "error": "Error",
    ]
    static var names: [String: String] { Loc.isRussian ? namesRu : namesEn }
    static func name(_ key: String) -> String { names[key] ?? key }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case appearance, list, requests, limits, connection, general
    var id: String { rawValue }
    var title: String { SettingsText.name(rawValue) }
    var icon: String {
        switch self {
        case .appearance: "circle.lefthalf.filled"
        case .list: "list.bullet"
        case .requests: "questionmark"
        case .limits: "gauge.with.dots.needle.33percent"
        case .connection: "powerplug.fill"
        case .general: "gearshape.fill"
        }
    }
    var tint: Color {
        switch self {
        case .appearance: Color(red: 0.04, green: 0.52, blue: 1)
        case .list: Color(red: 0.37, green: 0.36, blue: 0.9)
        case .requests: Color(red: 1, green: 0.62, blue: 0.04)
        case .limits: Color(red: 0.19, green: 0.69, blue: 0.78)
        case .connection: Color(red: 0.2, green: 0.78, blue: 0.35)
        case .general: Color(white: 0.56)
        }
    }
}
