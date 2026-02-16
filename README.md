# CodexIntelApp

Native macOS (SwiftUI) GUI for driving Codex from CLI on Intel Macs.

## What it does

1. Open any project folder.
2. Send conversational prompts to Codex CLI in that folder so it can inspect and modify files.
3. Open the selected project in VS Code.
4. Run one-click dependency setup from the app (`Setup Dependencies`).
5. Auto-commit and auto-push after each chat turn (plus manual `Push` / `Commit + Push` buttons).

## Requirements

- macOS 13+ (Intel or Apple Silicon)
- Xcode 15+ (or recent Swift toolchain with SwiftUI support)
- Internet access for one-click dependency setup
- Git installed and configured

## Build and run

```bash
cd "/Users/tedcolegrove/Desktop/Move to Dev/Dev/Codex for Intel"
swift build
swift run CodexIntelApp
```

No Xcode is required.

## Terminal scripts (no Xcode)

Run directly:

```bash
cd "/Users/tedcolegrove/Desktop/Move to Dev/Dev/Codex for Intel"
./scripts/run.sh
```

Build a standalone `.app` bundle:

```bash
cd "/Users/tedcolegrove/Desktop/Move to Dev/Dev/Codex for Intel"
./scripts/build_app.sh
open dist/CodexIntelApp.app
```

## Codex command

The app runs Codex directly (not through a shell `codex` command) with `exec`, then passes conversation context + your latest chat message. Commands run with the selected project as the working directory.

It auto-searches for executable names (`codex`, `codex-x86_64-apple-darwin`, `codex-aarch64-apple-darwin`) in:
- `/Applications/Codex.app/Contents/Resources/codex`
- `/Applications/Codex.app/Contents/MacOS/codex`
- `/usr/local/bin/codex`

## One-click setup

`Setup Dependencies` attempts to install everything needed via Homebrew:
- Homebrew (if missing)
- `git`
- `ripgrep`
- `codex` (Homebrew cask)
- Visual Studio Code (best-effort)

This runs inside the app; no manual CLI commands are required. On some systems, macOS may still prompt for permission/password during installs.

## Git behavior

- Git actions are enabled only when both `Remote` and `Branch` fields are filled in.
- After each chat turn, the app runs:
  - `git add -A`
  - commit only if there are staged changes
  - `git push -u <remote> <branch>`
- `Push`: runs `git push <remote> <branch>`
- `Commit + Push`: runs `git add -A && git commit -m "<message>" && git push ...`

You can run git actions before starting the conversation or at any point later.
