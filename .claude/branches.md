# Branches

A running log of the git branches in this repo and what each is for.

## Branching model

- **`main`** — pristine mirror of upstream (nathanborror/Heat). Only ever pulled into; no personal work committed here. Keeps upstream merges clean.
- **`dev`** — local integration branch and daily driver. All topic branches are merged here, and this is what gets built/run. Personal machine config lives only here.
- **Topic branches** — one focused, upstreamable change each, branched off `main` so they stay clean for future PRs. Merged into `dev` for everyday use.

## Branches

| Branch | Base | Purpose |
|--------|------|---------|
| `main` | — | Pristine upstream mirror. Pull upstream edits here; never commit personal work. |
| `get-up-and-running` | `main` | Everything needed just to build & launch on current Xcode/Swift: concurrency build errors (`static var shared` → `let`), concurrency/localization warnings, the fix for "New Conversation" silently failing on a fresh install (seed default instructions on startup + stop swallowing errors), and `@discardableResult` on the file-creation helpers to silence unused-result warnings. Future PR candidate. |
| `fix/surface-generation-errors` | `get-up-and-running` | Surface generation failures inline in the conversation as red error text (e.g. "No default chat service selected") instead of silently discarding the message. Future PR candidate. |
| `ui-fixes` | `main` | UI polish. (1) Replace the macOS message input with an auto-growing TextEditor (NSTextView): the NSTextField-backed vertical TextField wrapped at a stale intrinsic width on Sequoia, running under the send button; measured-width workarounds either pinned the window's min size or captured the width only once. Mirror-Text drives the height (1 line…240pt, then scrolls); Return submits, Shift+Return newlines; iOS keeps TextField. (2) Right-align user message bubbles. (3) Right-align suggested-reply chips. Future PR candidate. |
| `debug-logging` | `main` | Verbose chat-pipeline logging, Debug builds only (`#if DEBUG`): outgoing requests (model, tools, system prompt, user prompt), stream lifecycle, a post-stream dump of each message with its `shouldShowInRun` visibility, tool calls, suggestions, and titles. Unified log subsystem `ChatDebug` (Xcode console / Console.app). Added to diagnose responses that arrive but don't display. Future PR candidate (maybe). |
| `dev` | `main` | Integration branch — merges all topic branches above, plus a local-only commit with machine-specific Xcode signing config (`DEVELOPMENT_TEAM`, bundle id `run.alexanderlane.Heat`). Never pushed upstream. This is the branch to build/run from. |
