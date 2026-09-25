# Interface languages

Context Desk supports Russian (the existing default) and English. Open **Context Desk → Settings…** (`Cmd+,`) and choose a language in **Язык / Language**. The Help menu also contains **Язык / Language…**, which opens the same settings window.

Changes apply after quitting with `Cmd+Q` and reopening. The app never restarts itself or reconnects a running task to change language. A bilingual restart hint appears while the saved language differs from the active one.

`AppLanguage` stores `interfaceLanguage` and `AppleLanguages` in the application's own UserDefaults domain. The latter lets macOS localize standard menus and panels on the next launch. Invalid or missing preferences fall back to Russian. No Codex credentials, settings, or global language preferences are changed.

`L10n` freezes the language for the process lifetime so SwiftUI, AppKit, background errors, and notifications agree. App-owned strings use `L10n.text(russian, english)` with both translations required and interpolations checked by the compiler. Dates use `L10n.date`, and SwiftUI receives the active locale. These translations compile into ContextCore and work with both SwiftPM and the direct compiler fallback without resource-bundle lookup. The application bundle declares both supported localizations.

Keep user messages, project/chat names, server/tool output, protocol identifiers, and saved enum values unchanged. Translate app-owned labels and fallbacks only. Previously delivered macOS notifications retain their original text.

Validation: `zsh scripts/test.sh` includes isolated preference persistence and language-selection tests. `zsh scripts/build-app.sh` rebuilds and signs the application. For a UI check, launch each language and inspect Help, Settings, chat controls, usage dates, and a folder panel; change back and confirm the restart hint disappears. Do not quit an active user session automatically.
