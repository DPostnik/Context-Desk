# Transcript hang — 2026-09-25

## Observed failure

The user reported an unresponsive app after using the first real conversation. At 13:31 Europe/Warsaw, the UI process consumed 97.0% CPU (roughly one core); its Codex child reported 0.0%. A three-second `sample` of PID 60741 repeatedly placed the main thread in SwiftUI graph transactions, `LazySubviewPlacements`, lazy-stack placement and text/layout measurement. Accessibility requests to the old window timed out.

The app's separate store contained two projects and one conversation; login and real model use had occurred since the initial prototype report. The transcript included long multiline commands produced while the agent edited the UI itself. Those edits were preserved. The UI process and its dedicated Codex child were terminated after diagnosis. No model turn was replayed, and no other Codex process was terminated.

## Fix

The transcript now uses an AppKit `NSScrollView` and read-only `NSTextView`, with width constrained to the viewport. SwiftUI's lazy-stack sizing and `scrollTo` transaction feedback no longer participate in transcript rendering. The empty state is outside the scrolling history.

Only the changed suffix is rendered; identical updates leave text storage untouched. Long code lines wrap. Tool commands are collapsed by default and can be expanded in place. Follow-output scrolling occurs after the native viewport has a valid size, rather than during SwiftUI layout.

This stabilizes the transcript with simpler presentation: selectable text and monospaced code, with Markdown punctuation preserved. The prior experimental per-message SwiftUI bubble/copy controls are not used by this renderer; selected text can be copied with Cmd+C. Sidebar/navigation and notification changes already present in the working tree were retained.

## Verification

- All nine Swift Testing tests passed; two new AppKit tests cover a long transcript, a 40,000-character code line, 50 streamed updates, 100 identical no-op updates, conversation switching and expanding/collapsing large commands without damaging later messages.
- Release bundle rebuilt and reopened; authenticated account/model list loaded, and the existing conversation opened without another model request. Accessibility and screenshot checks returned promptly; the viewport scrolled to the end.
- A 60-second CPU-time measurement with the saved conversation open is recorded in `cpu-after-fix.json`. This is an idle-after-history-load test, not a new live model generation or a battery benchmark.

The interval was 60.01 seconds: UI used 0.02 CPU-seconds (0.033% of one core), and its Codex child used 0.01 CPU-seconds (0.017%). Physical footprints at the end were 56.8 MB and 33.8 MB respectively. These are measured for this loaded transcript while idle; they do not describe peak generation load.

The earlier one-instant 0% CPU snapshot did not catch this layout failure. The fix's acceptance uses the real saved transcript plus a sustained interval instead.
