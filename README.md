# CodexIntelApp

Native macOS (SwiftUI) GUI for driving Codex from CLI on Intel Macs.

## What it does

1. Open any project folder.
2. Send conversational prompts to Codex CLI in that folder so it can inspect and modify files.
3. Open the selected project in VS Code.
4. Automatically run dependency setup when a project folder is selected.
5. Auto-commit and auto-push after each chat turn (plus manual `Push` / `Commit + Push` buttons).
6. Stream live Codex activity ("thinking", tool events, errors) while each turn runs.
7. Show added/removed line summary with file-level stats and line previews after each run.

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

The app runs Codex directly (not through a shell `codex` command) with:
- `exec --json --full-auto --skip-git-repo-check --output-last-message <temp file>`

It passes recent conversation context + your latest chat message. Commands run with the selected project as the working directory, and Codex is instructed to implement changes directly (not suggestion-only mode).

It auto-searches for executable names (`codex`, `codex-x86_64-apple-darwin`, `codex-aarch64-apple-darwin`) in:
- `/Applications/Codex.app/Contents/Resources/codex`
- `/Applications/Codex.app/Contents/MacOS/codex`
- `/usr/local/bin/codex`

The app also injects a fallback PATH (`/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin` + Codex app paths) to avoid GUI PATH issues that cause exit code `127`.
If needed, set `Codex Path (optional override)` in the app or use env var `CODEX_BINARY=/absolute/path/to/codex`.
When selecting/running a project, the app also runs `chmod u+rwx <project_dir>` to ensure directory access.
If git remote/branch are not configured, git actions stay disabled, but Codex still runs in the project folder.

## Automatic setup

Every time a project folder is selected, the app automatically:
- verifies trust/read-write access for that folder (`chmod u+rwx`, read/write probe, and `git safe.directory` best-effort)
- attempts to install everything needed via Homebrew:
- Homebrew (if missing)
- `git`
- `ripgrep`
- `codex` (Homebrew cask)
- Visual Studio Code (best-effort)

This runs inside the app; no manual CLI commands are required once Homebrew is present.
When you send a chat and Codex is missing, the app also attempts an automatic one-time Codex CLI install (`brew install --cask codex`) and retries.
If Homebrew is missing, the app opens `https://brew.sh` and asks you to install it first.

## Git behavior

- Git actions are enabled only when both `Remote` and `Branch` fields are filled in.
- After each chat turn, the app runs:
  - `git add -A`
  - commit only if there are staged changes
  - `git push -u <remote> <branch>`
- `Push`: runs `git push <remote> <branch>`
- `Commit + Push`: runs `git add -A && git commit -m "<message>" && git push ...`

You can run git actions before starting the conversation or at any point later.
