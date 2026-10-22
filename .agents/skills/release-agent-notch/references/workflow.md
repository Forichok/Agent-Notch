# Порядок выпуска

Команды ниже выполняются из корня Agent Notch, кроме явно указанного checkout tap. Значения version и revision — подтверждённая версия X.Y.Z и полный SHA проверенного исходника. Этот документ не является разрешением на публикацию.

## 1. Исходник и версия

Прочитай AGENTS.md. Проверь gh auth status и remote URL обоих репозиториев. Используй изолированный checkout, сохраняя чужие изменения.

    git fetch origin
    git symbolic-ref refs/remotes/origin/HEAD
    git merge-base --is-ancestor origin/HEAD HEAD
    git status --short --branch
    git rev-parse HEAD

Если origin/HEAD отсутствует, разреши default branch через remote и обнови его symbolic ref. Не подставляй master по памяти. При отставании интегрируй изменения до сборки.

Подготовь секцию стабильной версии в CHANGELOG.md и значение VERSION по умолчанию в scripts/build.sh. Проверь извлечение описания:

    python3 scripts/release-notes.py "$version"

Версионный коммит должен быть проверен и интегрирован по правилам проекта, доступен на GitHub, рабочее дерево — чистое. Сохрани revision и дерево исходников. Для billing-only сбоя Actions нужны аннотации с подтверждённой причиной, соответствующие локальные проверки и независимое ревью. Отказ сервера в merge не обходить.

## 2. Локальная подготовка

На этом Mac нужны Xcode command-line tools, gh и существующий ключ Sparkle в Keychain. Открытый ключ закреплён в packaging/updates-public-key.txt; аккаунт закрытого ключа — com.forichok.agents-notch. GitHub secret и release Actions не используются.

    sh scripts/prepare-release.sh "$version"

Запускать через exec_command с tty:true и коротким yield_time_ms, затем ждать существующую session_id. Так macOS может показать запрос generate_appcast. Обычный headless-запуск в этой среде возвращал −128 без доступного владельцу запроса. Не отменяй ожидающую сессию по истечении одного tool timeout.

Объясни запрос до подтверждения: это подпись архива издателя. Пользователь подтверждает системный диалог и вводит пароль только в нём. Если управление SecurityAgent заблокировано инструментом, передай диалог владельцу; не открывай его обходным способом. При отказе останови подпись/публикацию и не повторяй запрос без нового разрешения.

Успешная подготовка с exit 0 создаёт в dist/ ZIP, DMG, ZIP заставки (AgentNotchHouse-$version.saver.zip), SHA256SUMS.txt, appcast.xml, notes.md и agent-notch.rb. Файлы с подходящими именами от прежней попытки не являются доказательством: важны исходный SHA в ZIP, версия, подпись и суммы.

### Возобновление только подписи

Если тесты и сборка прошли, ZIP/DMG проверены, а остановилась только подпись, сначала докажи, что исходник, версия и архивы не изменились и включают свежий origin/HEAD. При изменениях требуется новая подготовка. При неизменившихся артефактах продолжи в PTY:

    set -eu
    if [ "${UPDATE_TEST_BUNDLE:-}" = 1 ] || [ "${UPDATE_PUBLIC_KEY+x}" = x ] || [ "${UPDATE_FEED_URL+x}" = x ]; then
      echo "unset test updater overrides before production signing" >&2
      exit 1
    fi
    unset SPARKLE_PRIVATE_KEY
    sh scripts/appcast.sh "$version"

После него обязательно выполни хвост подготовки: appcast.sh сам не создаёт cask.

    checksum_result=$(shasum -a 256 "dist/AgentNotch-$version.zip")
    checksum=${checksum_result%% *}
    sed -e "s/__VERSION__/$version/" -e "s/__SHA256__/$checksum/" packaging/agent-notch.rb > dist/agent-notch.rb

Далее в обоих путях:

    python3 .agents/skills/release-agent-notch/scripts/release_audit.py "$version" --revision "$revision" --local-dist dist

Аудит проверяет все семь выходов, исходник в ZIP и в заставке, режим только по кнопке, закреплённый ключ, подпись CryptoKit, метаданные и описание ленты, cask и суммы. Монтирует DMG read-only, сравнивает весь bundle с подписанным ZIP и проверяет codesign обоих; приложение при этом не запускается. Он не обращается к Keychain и ничего не публикует. Независимое ревью должно осмотреть финальный комплект; старое ревью другого ZIP не подходит.

## 3. Черновик, тег и публикация

Проверь состояние версии:

    gh release view "v$version" --repo Forichok/Agent-Notch --json isDraft,targetCommitish,assets,url
    git ls-remote origin "refs/tags/v$version" "refs/tags/v$version^{}"

Отсутствие релиза подтверждается именно Not Found; ошибка сети/авторизации не означает его отсутствие. Существующий тег, включая аннотированный, должен разрешаться в revision. Установка target у Release не перемещает тег. Если существующий тег указывает на другой коммит — остановись; не удаляй и не передвигай его автоматически.

Если релиз уже публичный, только проверь его. Несовпадение опубликованного содержимого с кандидатом требует новой версии или отдельного решения владельца, а не clobber.

Для новой версии создай черновик:

    gh release create "v$version" --repo Forichok/Agent-Notch --target "$revision" --draft --title "Agent Notch $version" --notes-file dist/notes.md

Для существующего черновика обнови target/notes и явно сохрани draft:true. Заменять известные файлы можно только после проверки, что релиз всё ещё черновик:

    gh release edit "v$version" --repo Forichok/Agent-Notch --draft=true --target "$revision" --title "Agent Notch $version" --notes-file dist/notes.md
    gh release upload "v$version" --repo Forichok/Agent-Notch --clobber "dist/AgentNotch-$version.zip" "dist/AgentNotch-$version.dmg" "dist/AgentNotchHouse-$version.saver.zip" dist/SHA256SUMS.txt dist/appcast.xml

Сверь загруженные SHA256 digest с локальными файлами; если API не даёт digest, скачай assets черновика в отдельный временный каталог и сравни. Устаревшие дополнительные assets требуют явного решения, а не массового удаления. Проверь target/tag и наличие всех пяти файлов перед публикацией.

    gh release edit "v$version" --repo Forichok/Agent-Notch --draft=false --prerelease=false --latest

Проверь isDraft:false, опубликованный URL, дату и разрешение тега в revision. Приватный URL untagged-* ещё не является публичной загрузкой.

## 4. Публичная доступность

    public_dir=$(mktemp -d)
    python3 .agents/skills/release-agent-notch/scripts/release_audit.py "$version" --revision "$revision" --output-dir "$public_dir"

Скрипт без авторизации скачивает ZIP, DMG, ZIP заставки и суммы по URL версии, а appcast.xml — именно по production latest/download URL, который читает приложение. Проверяет pinned Ed25519, SHA, источник, версию и отсутствие автоматического режима. Он печатает JSON только после успеха. Запиши public_dir: это проверенные файлы для установки.

Проверка включает codesign и сравнение содержимого DMG с подписанным ZIP. При временной ошибке публичного HTTP разрешены до трёх повторных read-only проверок; не повторяй публикацию и не подменяй production feed тестовым. При устойчивом 404 выпуск ещё не проверен.

## 5. Homebrew tap

Нужно разрешение именно на Forichok/homebrew-tap. Если оно уже дано в этой задаче, не спрашивай снова. Если автоматическая проверка разрешений отклонила push, останови его, объясни причину и запроси недостающее разрешение; не меняй CLI на API ради обхода.

В отдельном чистом checkout tap обнови origin, разреши origin/HEAD, интегрируй его без force/reset и прочитай правила репозитория. Скопируй dist/agent-notch.rb в Casks/agent-notch.rb. Сверь diff: версия, URL и SHA ZIP; auto_updates true — декларация встроенного обновлятора для Homebrew, она не включает фоновые проверки приложения.

    ruby -c Casks/agent-notch.rb
    git diff --check

Закоммить и опубликуй только разрешённое изменение в default branch tap, проверяя branch/HEAD после git-шагов. Проверь опубликованный commit и содержимое cask в GitHub, затем:

    python3 .agents/skills/release-agent-notch/scripts/release_audit.py "$version" --revision "$revision" --output-dir "$public_dir" --check-tap

Эта проверка читает cask из default branch публичного репозитория через GitHub API и сравнивает его с публичным ZIP.

## 6. Установленная копия и итог

Если запрошена замена /Applications/Agent Notch.app, повторно fetch-проверь origin/HEAD непосредственно до неё. Выполни все требования AGENTS.md. Если master ушёл вперёд после публикации, не передвигай тег и не заменяй релиз: старая сборка не подходит для установки по правилам проекта. Укажи недостающую свежую сборку.

Распакуй подписанный ZIP из public_dir. До установки сохрани backup приложения, текущие настройки (особенно вкладки card) и суммы файлов пользовательской библиотеки звуков. Отрисуй Prompts из настоящего session log и посмотри изображение:

    "$artifact/Contents/MacOS/AgentsNotch" --snapshot-card "$verification_dir/prompts.png" --card-tab prompts --card-log "$session_log"

Останови только установленную копию, замени её проверенным bundle, сверив executable, notch-hook и Info.plist с артефактом; проверь codesign. Перезапусти именно /Applications/Agent Notch.app. Убедись, что настоящая карточка, Prompts, пользовательские звуки, журнал Codex и Keep awake сохранились. При сравнении настроек декодируй JSON-значения: порядок ключей может меняться без изменения предпочтений.

Нажми Check for Updates в установленной копии. Ожидается окно новой версии либо You're up to date, а не Update Error. Проверка актуальности не является доказательством, что в этом прогоне была выполнена установка через Sparkle: описывай только реально проверенный путь.

Итог: публичная ссылка, source revision, состояние tap и локальной копии; последняя строка — где и как проверено. Отдельно назови незавершённые шаги. Не объявляй полный выпуск на стадии архива или черновика.
