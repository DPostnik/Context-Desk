# Browser / Браузер

## English

Chrome DevTools MCP 1.10.1 provides the browser executor. Context Desk adds compact
card extraction, readiness checks, verified pagination and private checkpoints.
Install Node.js 22.12 or later, then run from the repository:

```sh
python3 BrowserRuntime/install.py
```

For an app-only installation, open Terminal, type `python3 `, drag `install.py`
from this folder into Terminal and press Return. The installer needs Node on PATH;
alternatively pass `--node /absolute/path/to/node`. It downloads the pinned archive,
verifies its SHA-512 and all extracted files, and runs no npm installation scripts.
It also installs pinned Chrome for Testing (154.0.8037.57) in the app-owned browser
directory, checking the pinned archive SHA-256. ARM64 and Intel Macs are
supported. Chrome for Testing does not auto-update: a new release requires an
updated installer/lock and rerunning installation. Regular Chrome is never a fallback.

In Settings → Browser, enable Use Chrome DevTools and select Apply browser setting
after current tasks finish. The agent opens the separate Chrome for Testing app
on first use, in manual debugging mode, then the adapter attaches.
The Apply button remains disabled during chat or background tasks; wait for them
to finish or stop the relevant chat task before reconnecting. No actions are replayed.
Sign in manually in the new testing-profile. Existing agent profile data is left
in place, but is not migrated; site sign-ins and Google account sync are not guaranteed. Google still decides whether to accept sign-in. Chrome
stays open across adapter reconnects; close its window yourself when finished.
This does not copy your normal Chrome or Codex credentials.
The component is disabled by default. Turning it off also requires Apply or restart.

Browser data lives in `~/Library/Application Support/Context Desk/browser/`.
`records/` contains private page checkpoints, action IDs and call/byte/time metrics.
Records persist until you delete them; they may contain job or other page data.
No automatic action replay or automatic continuation after reconnect is performed.
Each task owns its own work tab. The shared executor serializes operations across tasks.
After Chrome exits, call `browser_open` explicitly to start a new task with the
same profile. Old session tokens are invalidated; actions are never replayed.
An uncertain transport failure still requires reconnecting the adapter.

## Русский

Исполнитель браузера — Chrome DevTools MCP 1.10.1. Context Desk добавляет компактное
чтение карточек, проверку загрузки и переходов, а также локальные контрольные точки.
Установи Node.js 22.12 или новее, затем выполни из папки проекта:

```sh
python3 BrowserRuntime/install.py
```

Если есть только приложение: открой Терминал, набери `python3 `, перетащи в него
`install.py` из этой папки и нажми Return. Установщик ищет Node в PATH; можно указать
`--node /полный/путь/к/node`. Он скачивает закреплённый архив, проверяет SHA-512
и извлечённые файлы. Скрипты установки npm не выполняются.
Также устанавливается закреплённый Chrome for Testing (154.0.8037.57) в папку
браузера приложения с проверкой закреплённой SHA-256 архива. Поддерживаются ARM64
и Intel Mac. Автообновления нет: для новой версии нужны обновлённый установщик
и файл версий, затем повторная установка. Обычный Chrome не используется как запасной.

В настройках → Браузер включи «Использовать Chrome DevTools» и нажми «Применить
настройку браузера» после завершения текущих задач. При первом обращении агента
откроется отдельное приложение Chrome for Testing в режиме ручной отладки;
адаптер подключится после запуска. Кнопка применения недоступна во время задач
в чатах и фоновой обработки: дождись завершения или останови нужную задачу
в её чате перед переподключением. Действия не повторяются.
Войди на сайты заново в testing-profile. Старый профиль агента остаётся на месте,
но не переносится. Вход на сайты и синхронизация Google не гарантируются.
Решение о разрешении входа принимает Google.
Chrome остаётся открытым при переподключении адаптера; закрой его окно, когда закончишь. Данные входа
обычного Chrome и Codex не копируются. По умолчанию компонент выключен. Отключение
тоже применяется кнопкой или после перезапуска.

Данные находятся в `~/Library/Application Support/Context Desk/browser/`.
В `records/` сохраняются контрольные точки страниц, ID действий и счётчики
вызовов, объёма ответов и времени. Записи хранятся до ручного удаления и могут
содержать данные вакансий или других страниц. Действия не повторяются автоматически;
после переподключения задача не продолжается сама. Рабочей вкладкой владеет одна
задача; операции разных задач выполняются последовательно.
После закрытия Chrome явно вызови `browser_open`, чтобы начать новую задачу
с тем же профилем. Старые session становятся недействительными; действия
не повторяются. При неопределённом сбое связи нужно переподключить адаптер.

## Development contract

- `browser_open` returns an opaque session token. Every subsequent call needs it.
- `browser_cards` accepts CSS selectors as data; at most 500 cards, bounded fields,
  explicit `truncated`, `complete`, `reason` and `next`. An empty/loading shell is
  partial without an explicit `empty` selector. Completion describes one page.
- `browser_next` needs a completed checkpoint and either an observed snapshot UID
  or nextToken. It dispatches once and verifies changed IDs; no-op returns partial.
- `browser_action` supports scoped native form/navigation actions. Supply an
  exact observed `expectedURL` and globally unique `actionID`. Its result is not
  a submission receipt. Use `browser_verify` for a visible text/URL postcondition.
- `browser_snapshot` is the explicit full-snapshot fallback. `browser_status`
  reports RPC latency, bytes and counts; these exclude model processing and do
  not claim model tokens, physical memory or an end-to-end performance gain.
- Checkpoints are private evidence, not an automatic resume queue. Project
  approval/sandbox settings remain at the Codex boundary and are not overridden.
- Upstream MCP is pinned to 2025-11-25; client protocols 2025-06-18 and 2025-11-25
  are explicitly supported. Unknown requests fail closed. Transport
  uncertainty or cancellation stops the executor; reconnect is manual.
- No interception of normal Chrome, inherited login state, remote debugging
  attachment to arbitrary browsers, or browsing of other tasks' tabs is exposed.

Run `python3 -m unittest discover -s BrowserRuntime -p 'test_*.py'` for offline
checks. Run `python3 BrowserRuntime/smoke.py` after installing for the real Chrome
fixture checks. App build and Swift checks use the repository's usual scripts.
See `BrowserRuntime/PLAN.md` in the repository for the delivery sequence.

The host records the dedicated Chrome PID, process birth, exact launch command and
browser endpoint ID. Attachment requires a matching process and an exclusively
loopback listener owned by that PID. It never uses autoConnect or launches with
`--enable-automation`, `--disable-sync` or a mock keychain.
Reference: https://github.com/ChromeDevTools/chrome-devtools-mcp/blob/main/docs/advanced-usage.md#connecting-to-a-running-chrome-instance

## Compact workflow / Компактный поиск

English: `browser_cards` accepts `date` and `excerpt` selectors. A complete page may
return `nextToken` for a visible same-origin Next target. Pass that token
instead of `uid` to `browser_next`; the adapter checks the link again and navigates
once. Use the snapshot/UID path for buttons or JavaScript click behavior. Full URLs
remain in private checkpoints and card data. `expectedCards` opts into a previously
audited static per-page count with stable, hydrated, unique cards; never use a
site-wide total or guess this from a lazy list. Mismatches use ordinary scrolling.
This does not change scheduled jobs or establish model-token savings.

Русский: `browser_cards` принимает селекторы `date` и `excerpt`. Полностью прочитанная
страница может вернуть `nextToken` для однозначной видимой ссылки «Далее» на том же
сайте. Передай его вместо `uid` в `browser_next`: адаптер повторно проверит ссылку и
выполнит один переход. Для кнопок и JavaScript-обработчиков используй снимок и UID.
Полные URL сохраняются в локальных контрольных точках и данных карточек.
`expectedCards` включает режим заранее проверенного статического списка с известным
числом карточек на странице; карточки должны быть уникальны, загружены и стабильны.
Не используй общее число вакансий сайта и не угадывай число по ленивому списку.
При несовпадении выполняется обычная прокрутка. Расписания не меняются; экономия
модельных токенов пока не измерена.

Development: `python3 -B BrowserRuntime/workflow_smoke.py` compares generic and
static traversal against an isolated two-page local fixture. See
`BrowserRuntime/WORKFLOW_PLAN.md` in the repository for staged rollout and measurement limits.

## Multiple MCP clients / Несколько MCP-клиентов

English: each chat/subagent keeps its own session, tab and project workspace. A
private shared executor serializes complete tool operations, including their
preconditions and verification. Idle sessions do not block other chats; closing a
tab is no longer required to let another chat work. Catalogs remain available
without starting Chrome. Disconnect stops only that client's upstream transport,
leaves its tab intact and never transfers its token to another client. The
executor exits after all clients disconnect; Chrome and user tabs are preserved.

A lost response, cancellation during dispatch or executor crash never causes a
reconnect-and-replay. A durable in-flight fence blocks new browser operations
when the previous outcome is unknown. Review the result, then close the dedicated
Chrome; only its confirmed exit allows fresh sessions (reconnect a stopped
client). Action-ID records remain and still prohibit replay. Queued requests from
disconnected clients are discarded before dispatch. Permissions and upload roots
remain separate for each client's project; no union of project access is created.

Русский: каждый чат и subagent сохраняет свою session, вкладку и каталог проекта.
Общий локальный исполнитель выполняет операции последовательно, вместе с их
предварительными проверками и подтверждением. Простаивающая сессия больше не
блокирует другие чаты; закрывать вкладку для передачи браузера не требуется.
Каталог доступен без запуска Chrome. Отключение останавливает только дочерний
транспорт своего клиента, сохраняя вкладку; её token не передаётся другому чату.
Исполнитель завершается после отключения всех клиентов, сохраняя Chrome и вкладки.

Потеря ответа, отмена выполняемой операции или падение исполнителя не приводят к
переподключению с повтором. Запись незавершённой операции блокирует новые действия,
если исход неизвестен. Проверь результат и закрой выделенный Chrome; только
подтверждённое завершение Chrome разрешает новые сессии (остановленному клиенту
нужно переподключение). Записи actionID сохраняются и запрещают повтор. Запросы
отключённых клиентов в очереди отбрасываются до отправки. Разрешения и каталоги
загрузки остаются отдельными для каждого проекта, без объединения доступа.

Activation / Активация: after active tasks finish, quit Context Desk with Cmd+Q
and reopen the rebuilt app. An old adapter may still hold the legacy lock; it is
never killed automatically. После завершения активных задач выйди через Cmd+Q и
открой собранное приложение. Старый адаптер может держать прежнюю блокировку;
автоматически он не завершается.

Development: `python3 -B BrowserRuntime/multi_client_smoke.py` exercises two real
MCP front ends and the auto-started executor against isolated local Chrome pages.
Set `BROWSER_RUNTIME_UNDER_TEST` to the bundled BrowserRuntime directory to test
built resources. Offline `test_multi_client.py` covers queueing, ownership,
disconnect/cancellation, protocol identity, crash fences and no replay.
