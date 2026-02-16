# CodexIntelApp

Native macOS (SwiftUI) GUI for driving Codex from CLI on Intel Macs.

## What it does

1. Open any project folder.
2. Send conversational prompts to Codex CLI in that folder so it can inspect and modify files.
3. Open the selected project in VS Code and run a test command.
4. Push with git before or after conversation turns (`Push` or `Commit + Push`).

## Requirements

- macOS 13+ (Intel or Apple Silicon)
- Xcode 15+ (or recent Swift toolchain with SwiftUI support)
- Codex CLI installed and on `PATH`
- VS Code CLI (`code`) installed for the "Open in VS Code" button
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

## Codex CLI template

Default template is:

```text
codex exec {prompt}
```

If your Codex CLI uses different syntax, update the "Codex CLI" field in the app.

Notes:
- `{prompt}` is required and will be replaced with the conversation payload.
- Do not wrap `{prompt}` in extra quotes, the app already shell-quotes it.
- Commands run with the selected project as the working directory.

## Git behavior

- `Push`: runs `git push <remote> <branch>` (or only remote if branch is blank)
- `Commit + Push`: runs `git add -A && git commit -m "<message>" && git push ...`

You can run git actions before starting the conversation or at any point later.
