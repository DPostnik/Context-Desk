# Interface languages

Context Desk supports Russian (the existing default) and English. Open **Context Desk → Settings…** (`Cmd+,`) and choose a language in **Язык / Language**. The Help menu also contains **Язык / Language…**, which opens the same settings window.

Changes apply after quitting with `Cmd+Q` and reopening. The app never restarts itself or reconnects a running task to change language. A bilingual restart hint appears while the saved language differs from the active one.

`AppLanguage` stores `interfaceLanguage` and `AppleLanguages` in the application's own UserDefaults domain. The latter lets macOS localize standard menus and panels on the next launch. Invalid or missing preferences fall back to Russian. No Codex credentials, settings, or global language preferences are changed.

`L10n` freezes the language for the process lifetime so SwiftUI, AppKit, background errors, and notifications agree. App-owned strings use `L10n.text(russian, english)` with both translations required and interpolations checked by the compiler. Dates use `L10n.date`, and SwiftUI receives the active locale. These translations compile into ContextCore and work with both SwiftPM and the direct compiler fallback without resource-bundle lookup. The application bundle declares both supported localizations.

Keep user messages, project/chat names, server/tool output, protocol identifiers, and saved enum values unchanged. Translate app-owned labels and fallbacks only. Previously delivered macOS notifications retain their original text.

Validation: `zsh scripts/test.sh` includes isolated preference persistence and language-selection tests. `zsh scripts/build-app.sh` rebuilds and signs the application. For a UI check, launch each language and inspect Help, Settings, chat controls, usage dates, and a folder panel; change back and confirm the restart hint disappears. Do not quit an active user session automatically.

## Required for every change

Ship Russian and English together for all new/changed app-owned copy, including first-party plugin descriptions, status messages, counters and errors. `AGENTS.md` records this as a release requirement. Keep both language checks in the same task; do not defer English until a later release.

Provider protocol v1 supports optional `titleTranslations`, `descriptionTranslations` and `detailTranslations` objects with required `ru` and `en` members when present. The host selects the active app language. Older third-party plugins remain compatible and keep their unmodified fallback strings; first-party plugins must supply both translations. Plugin identity and user/server content are not translated.

The plugin settings section is **Плагины / Plugins**, with **Без плагина / No plugin** for Direct mode, descriptions from each plugin, explicit installed/unused/missing/connecting status, and **Применить выбор / Apply selection** beside the new-chat selection. Applying reconnects Codex and is disabled while work is active; existing chat routes stay unchanged.
