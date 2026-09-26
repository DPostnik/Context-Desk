# Browser / Браузер

## English

Chrome DevTools MCP 1.10.1 provides the browser executor. Context Desk adds compact
card extraction, readiness checks, verified pagination and private checkpoints.
Install Node.js 22.12 or later and Google Chrome, then run from the repository:

```sh
python3 BrowserRuntime/install.py
```

For an app-only installation, open Terminal, type `python3 `, drag `install.py`
from this folder into Terminal and press Return. The installer needs Node on PATH;
alternatively pass `--node /absolute/path/to/node`. It downloads the pinned archive,
verifies its SHA-512 and all extracted files, and runs no npm installation scripts.

In Settings → Browser, enable Use Chrome DevTools and select Apply browser setting
after current tasks finish. The agent opens a separate Chrome profile on first use.
Chrome starts separately in manual debugging mode, then the adapter attaches.
Sign in manually there. Google still decides whether to accept sign-in. Chrome
stays open across adapter reconnects; close its window yourself when finished.
This does not copy your normal Chrome or Codex credentials.
The component is disabled by default. Turning it off also requires Apply or restart.

Browser data lives in `~/Library/Application Support/Context Desk/browser/`.
`records/` contains private page checkpoints, action IDs and call/byte/time metrics.
Records persist until you delete them; they may contain job or other page data.
No automatic action replay or automatic continuation after reconnect is performed.
One task owns the work tab at a time. Other tasks must wait for it to close.
After Chrome exits, call `browser_open` explicitly to start a new task with the
same profile. Old session tokens are invalidated; actions are never replayed.
An uncertain transport failure still requires reconnecting the adapter.

## Русский

Исполнитель браузера — Chrome DevTools MCP 1.10.1. Context Desk добавляет компактное
чтение карточек, проверку загрузки и переходов, а также локальные контрольные точки.
Установи Node.js 22.12 или новее и Google Chrome, затем выполни из папки проекта:

```sh
python3 BrowserRuntime/install.py
```

Если есть только приложение: открой Терминал, набери `python3 `, перетащи в него
`install.py` из этой папки и нажми Return. Установщик ищет Node в PATH; можно указать
`--node /полный/путь/к/node`. Он скачивает закреплённый архив, проверяет SHA-512
и извлечённые файлы. Скрипты установки npm не выполняются.

В настройках → Браузер включи «Использовать Chrome DevTools» и нажми «Применить
настройку браузера» после завершения текущих задач. При первом обращении агента
откроется отдельный профиль Chrome в режиме ручной отладки; адаптер подключится
после запуска. Войди на сайты вручную. Решение о разрешении входа принимает Google.
Chrome остаётся открытым при переподключении адаптера; закрой его окно, когда закончишь. Данные входа
обычного Chrome и Codex не копируются. По умолчанию компонент выключен. Отключение
тоже применяется кнопкой или после перезапуска.

Данные находятся в `~/Library/Application Support/Context Desk/browser/`.
В `records/` сохраняются контрольные точки страниц, ID действий и счётчики
вызовов, объёма ответов и времени. Записи хранятся до ручного удаления и могут
содержать данные вакансий или других страниц. Действия не повторяются автоматически;
после переподключения задача не продолжается сама. Рабочей вкладкой владеет одна
задача; остальные ждут её закрытия.
После закрытия Chrome явно вызови `browser_open`, чтобы начать новую задачу
с тем же профилем. Старые session становятся недействительными; действия
не повторяются. При неопределённом сбое связи нужно переподключить адаптер.

## Development contract

- `browser_open` returns an opaque session token. Every subsequent call needs it.
- `browser_cards` accepts CSS selectors as data; at most 500 cards, bounded fields,
  explicit `truncated`, `complete`, `reason` and `next`. An empty/loading shell is
  partial without an explicit `empty` selector. Completion describes one page.
- `browser_next` needs a completed checkpoint and an observed snapshot UID. It
  clicks once and verifies changed IDs; no-op returns partial without a replay.
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
