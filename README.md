# CodexIntelApp

Native macOS (SwiftUI) GUI for driving Codex from CLI on Intel Macs.

## What it does

1. Open any project folder.
2. Send conversational prompts to Codex CLI in that folder so it can inspect and modify files.
3. Open the selected project in VS Code.
4. Automatically run dependency setup when a project folder is selected.
5. Auto-commit and auto-push after each chat turn (plus manual `Push` / `Commit + Push` buttons).
6. Start and keep a persistent autonomous Codex session per project (reused across prompts via `exec resume`).
7. Show changes in a collapsed accordion (`+/-` summary, file stats, and line previews on expand).
8. Keep power-user logs hidden by default (toggle `Power User`).
9. Keep git controls hidden by default (toggle `Setup Git`).
10. Show current model + reasoning effort and let you switch both from the top bar.
11. Keep conversation output user-friendly (plain-English summary, no raw code dumps).
12. Auto-collapse long system messages in conversation (expand on demand).

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

The build script uses `Assets/CodexIntel.icns` for the app icon.

## Codex command and session behavior

The app runs Codex directly (not through a shell `codex` command) with:
- `exec --json --full-auto --skip-git-repo-check` (session bootstrap)
- `exec resume --json --full-auto --skip-git-repo-check <session-id> "<prompt>"` (follow-up turns)

It passes recent conversation context + your latest chat message. Commands run with the selected project as the working directory, and Codex is instructed to implement changes directly (not suggestion-only mode). The app keeps a persistent autonomous session active and reuses it for subsequent prompts.

It auto-searches for executable names (`codex`, `codex-x86_64-apple-darwin`, `codex-aarch64-apple-darwin`) in:
- `/Applications/Codex.app/Contents/Resources/codex`
- `/Applications/Codex.app/Contents/MacOS/codex`
- `/usr/local/bin/codex`

The app also injects a fallback PATH (`/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin` + Codex app paths) to avoid GUI PATH issues that cause exit code `127`.
If needed, set `Codex Path (optional override)` in the app or use env var `CODEX_BINARY=/absolute/path/to/codex`.
When selecting/running a project, the app also runs `chmod u+rwx <project_dir>` to ensure directory access.
If git remote/branch are not configured, git actions stay disabled, but Codex still runs in the project folder.

## UI behavior

- `Project` top menu contains `Open Folder`, `Locate Codex`, and `Open in VS Code`.
- `Power User` toggle reveals command log + live activity + codex path override.
- `Setup Git` toggle reveals git remote/branch controls and push buttons.
- The prompt composer is larger, inline with conversation, and Enter sends your next chat.

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
