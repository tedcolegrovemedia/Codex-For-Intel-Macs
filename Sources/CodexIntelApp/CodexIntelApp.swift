import AppKit
import Foundation
import SwiftUI

@main
struct CodexIntelApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 1100, minHeight: 700)
        }
    }
}

enum MessageRole: String {
    case user = "User"
    case assistant = "Codex"
    case system = "System"
}

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: MessageRole
    let content: String
    let timestamp = Date()
}

struct CommandOutput {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

enum StreamSource {
    case stdout
    case stderr
}

struct DiffFileStat: Identifiable {
    let id = UUID()
    let path: String
    let added: Int
    let removed: Int
}

enum DiffLineKind {
    case added
    case removed
}

struct DiffLine: Identifiable {
    let id = UUID()
    let file: String
    let kind: DiffLineKind
    let text: String
}

enum ViewModelError: LocalizedError {
    case projectNotSelected
    case emptyPrompt
    case codexNotFound

    var errorDescription: String? {
        switch self {
        case .projectNotSelected:
            return "Select a project folder first."
        case .emptyPrompt:
            return "Prompt is empty."
        case .codexNotFound:
            return "Codex CLI not found. Select a project folder to trigger automatic setup, or set Codex Path in the app."
        }
    }
}

struct ShellRunner {
    func run(
        command: String,
        workingDirectory: String?,
        environment: [String: String]? = nil
    ) async throws -> CommandOutput {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let output = try ShellRunner.runSync(
                        command: command,
                        workingDirectory: workingDirectory,
                        environment: environment
                    )
                    continuation.resume(returning: output)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func run(
        executablePath: String,
        arguments: [String],
        workingDirectory: String?,
        environment: [String: String]? = nil
    ) async throws -> CommandOutput {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let output = try ShellRunner.runSync(
                        executablePath: executablePath,
                        arguments: arguments,
                        workingDirectory: workingDirectory,
                        environment: environment
                    )
                    continuation.resume(returning: output)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func runStreaming(
        executablePath: String,
        arguments: [String],
        workingDirectory: String?,
        environment: [String: String]? = nil,
        onLine: @escaping @Sendable (StreamSource, String) -> Void
    ) async throws -> CommandOutput {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let output = try ShellRunner.runSyncStreaming(
                        executablePath: executablePath,
                        arguments: arguments,
                        workingDirectory: workingDirectory,
                        environment: environment,
                        onLine: onLine
                    )
                    continuation.resume(returning: output)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func runSync(
        command: String,
        workingDirectory: String?,
        environment: [String: String]? = nil
    ) throws -> CommandOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        if let workingDirectory, !workingDirectory.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        }

        let env = environment ?? enrichedEnvironment()
        return try runProcess(process, environment: env)
    }

    private static func runSync(
        executablePath: String,
        arguments: [String],
        workingDirectory: String?,
        environment: [String: String]? = nil
    ) throws -> CommandOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        if let workingDirectory, !workingDirectory.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        }

        let executableDirectory = URL(fileURLWithPath: executablePath).deletingLastPathComponent().path
        let env = environment ?? enrichedEnvironment(extraPathDirectories: [executableDirectory])
        return try runProcess(process, environment: env)
    }

    private static func runSyncStreaming(
        executablePath: String,
        arguments: [String],
        workingDirectory: String?,
        environment: [String: String]? = nil,
        onLine: @escaping @Sendable (StreamSource, String) -> Void
    ) throws -> CommandOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        if let workingDirectory, !workingDirectory.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        }

        let executableDirectory = URL(fileURLWithPath: executablePath).deletingLastPathComponent().path
        let env = environment ?? enrichedEnvironment(extraPathDirectories: [executableDirectory])
        return try runProcessStreaming(process, environment: env, onLine: onLine)
    }

    private static func runProcess(_ process: Process, environment: [String: String]) throws -> CommandOutput {
        process.environment = environment

        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let stdoutURL = tempDirectory.appendingPathComponent("codex-intel-\(UUID().uuidString)-stdout.log")
        let stderrURL = tempDirectory.appendingPathComponent("codex-intel-\(UUID().uuidString)-stderr.log")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)

        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdoutHandle.close()
            try? stderrHandle.close()
            try? FileManager.default.removeItem(at: stdoutURL)
            try? FileManager.default.removeItem(at: stderrURL)
        }

        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle

        try process.run()
        process.waitUntilExit()

        let stdout = (try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? ""
        let stderr = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
        return CommandOutput(stdout: stdout, stderr: stderr, exitCode: process.terminationStatus)
    }

    private static func runProcessStreaming(
        _ process: Process,
        environment: [String: String],
        onLine: @escaping @Sendable (StreamSource, String) -> Void
    ) throws -> CommandOutput {
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let lock = NSLock()
        var stdoutText = ""
        var stderrText = ""
        var stdoutBuffer = ""
        var stderrBuffer = ""

        func appendChunk(_ text: String, source: StreamSource) {
            guard !text.isEmpty else { return }
            lock.lock()
            switch source {
            case .stdout:
                stdoutText += text
                stdoutBuffer += text
                let parts = stdoutBuffer.components(separatedBy: "\n")
                for line in parts.dropLast() {
                    let trimmed = line.trimmingCharacters(in: .newlines)
                    if !trimmed.isEmpty {
                        onLine(.stdout, trimmed)
                    }
                }
                stdoutBuffer = parts.last ?? ""
            case .stderr:
                stderrText += text
                stderrBuffer += text
                let parts = stderrBuffer.components(separatedBy: "\n")
                for line in parts.dropLast() {
                    let trimmed = line.trimmingCharacters(in: .newlines)
                    if !trimmed.isEmpty {
                        onLine(.stderr, trimmed)
                    }
                }
                stderrBuffer = parts.last ?? ""
            }
            lock.unlock()
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            appendChunk(text, source: .stdout)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            appendChunk(text, source: .stderr)
        }

        try process.run()
        process.waitUntilExit()

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        let remainingOut = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        if let text = String(data: remainingOut, encoding: .utf8), !text.isEmpty {
            appendChunk(text, source: .stdout)
        }
        let remainingErr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        if let text = String(data: remainingErr, encoding: .utf8), !text.isEmpty {
            appendChunk(text, source: .stderr)
        }

        lock.lock()
        if !stdoutBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            onLine(.stdout, stdoutBuffer.trimmingCharacters(in: .newlines))
        }
        if !stderrBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            onLine(.stderr, stderrBuffer.trimmingCharacters(in: .newlines))
        }
        stdoutBuffer = ""
        stderrBuffer = ""
        let output = CommandOutput(stdout: stdoutText, stderr: stderrText, exitCode: process.terminationStatus)
        lock.unlock()
        return output
    }

    private static func enrichedEnvironment(extraPathDirectories: [String] = []) -> [String: String] {
        var env = ProcessInfo.processInfo.environment

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let currentPath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let existing = currentPath.split(separator: ":").map(String.init)

        let defaults = [
            "/Applications/Codex.app/Contents/Resources",
            "/Applications/Codex.app/Contents/MacOS",
            "\(home)/Applications/Codex.app/Contents/Resources",
            "\(home)/Applications/Codex.app/Contents/MacOS",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]

        let combined = extraPathDirectories + existing + defaults
        var seen = Set<String>()
        let deduped = combined.filter { entry in
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return false }
            return seen.insert(trimmed).inserted
        }

        env["PATH"] = deduped.joined(separator: ":")
        return env
    }
}

@MainActor
final class AppViewModel: ObservableObject {
    @Published var projectPath = ""
    @Published var codexPathOverride = ""
    @Published var gitRemote = ""
    @Published var gitBranch = ""
    @Published var commitMessage = "Update via CodexIntelApp"
    @Published var draftPrompt = ""

    @Published var messages: [ChatMessage] = [
        ChatMessage(
            role: .system,
            content: "Select a project folder, then send prompts. Codex runs in autonomous edit mode in that directory."
        )
    ]
    @Published var commandLog: [String] = []
    @Published var isBusy = false
    @Published var busyLabel = ""
    @Published var thinkingStatus = ""
    @Published var liveActivity: [String] = []
    @Published var latestDiffAdded = 0
    @Published var latestDiffRemoved = 0
    @Published var latestDiffFiles: [DiffFileStat] = []
    @Published var latestDiffLines: [DiffLine] = []

    private let runner = ShellRunner()
    private var resolvedCodexExecutable: String?
    private var didAttemptAutoInstallCodex = false
    private let missingBrewMarker = "__BREW_MISSING__"
    var isGitConfigured: Bool {
        !gitRemote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !gitBranch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func chooseProjectFolder() {
        let panel = NSOpenPanel()
        panel.title = "Select Project Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true

        if panel.runModal() == .OK, let url = panel.url {
            projectPath = url.path
            log("Selected project: \(projectPath)")
            Task {
                await ensureProjectDirectoryTrustAndAccess()
                await runDependencyInstaller(autoTriggered: true)
            }
        }
    }

    func chooseCodexBinary() {
        let panel = NSOpenPanel()
        panel.title = "Select Codex Binary"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true

        if panel.runModal() == .OK, let url = panel.url {
            codexPathOverride = url.path
            resolvedCodexExecutable = nil
            log("Configured Codex path override: \(url.path)")
        }
    }

    func sendPrompt() {
        let prompt = draftPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        draftPrompt = ""
        messages.append(ChatMessage(role: .user, content: prompt))

        Task {
            await runCodex(for: prompt)
        }
    }

    func openInVSCode() {
        Task {
            await runUtilityCommand(
                label: "Opening in VS Code",
                command: "if command -v code >/dev/null 2>&1; then code .; else open -a \"Visual Studio Code\" .; fi",
                includeAsAssistantMessage: false
            )
        }
    }

    func gitPush() {
        guard let target = configuredGitTarget() else { return }
        let pushCommand = "git push \(shellQuote(target.remote)) \(shellQuote(target.branch))"

        Task {
            await runUtilityCommand(
                label: "Pushing git branch",
                command: pushCommand,
                includeAsAssistantMessage: true
            )
        }
    }

    func gitCommitAndPush() {
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let commit = message.isEmpty ? "Update via CodexIntelApp" : message
        guard let target = configuredGitTarget() else { return }

        let command = "git add -A && git commit -m \(shellQuote(commit)) && git push \(shellQuote(target.remote)) \(shellQuote(target.branch))"

        Task {
            await runUtilityCommand(
                label: "Committing and pushing",
                command: command,
                includeAsAssistantMessage: true
            )
        }
    }

    private func runCodex(for userPrompt: String) async {
        resetRunFeedback()
        let lastMessageURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("codex-intel-last-\(UUID().uuidString).txt")

        do {
            try validateProjectAndTemplate(prompt: userPrompt)
            let codexExecutable = try await ensureCodexExecutableAvailable()
            await ensureProjectDirectoryTrustAndAccess()
            let enrichedPrompt = buildPromptWithHistory(newPrompt: userPrompt)
            thinkingStatus = "Thinking..."
            appendActivity("Starting Codex in autonomous mode")

            let codexArguments: [String] = [
                "exec",
                "--json",
                "--full-auto",
                "--skip-git-repo-check",
                "--output-last-message", lastMessageURL.path,
                enrichedPrompt
            ]
            let output = try await executeBusyExecutableStreaming(
                label: "Running Codex",
                executablePath: codexExecutable,
                arguments: codexArguments
            ) { [weak self] source, line in
                Task { @MainActor in
                    self?.handleCodexStreamLine(source: source, line: line)
                }
            }
            if output.exitCode != 0 {
                log("Codex exited with code \(output.exitCode)")
                let errorText = preferredFailureText(output)
                messages.append(ChatMessage(role: .assistant, content: "Codex failed (\(output.exitCode)).\n\(errorText)"))
                appendActivity("Codex exited with code \(output.exitCode)")
                thinkingStatus = ""
                return
            }
            let response = readAssistantOutput(from: lastMessageURL, fallback: cleanOutput(output.stdout, fallback: output.stderr))
            messages.append(ChatMessage(role: .assistant, content: response))
            appendActivity("Codex response complete")
            thinkingStatus = ""
            await refreshChangeSummary()
        } catch {
            let text = error.localizedDescription
            messages.append(ChatMessage(role: .assistant, content: "Error: \(text)"))
            log("Error: \(text)")
            appendActivity("Error: \(text)")
            thinkingStatus = ""
        }
        try? FileManager.default.removeItem(at: lastMessageURL)
        await autoCommitAndPushAfterChat()
    }

    private func ensureCodexExecutableAvailable() async throws -> String {
        do {
            return try await resolveCodexExecutable()
        } catch ViewModelError.codexNotFound {
            guard !didAttemptAutoInstallCodex else { throw ViewModelError.codexNotFound }
            didAttemptAutoInstallCodex = true
            log("Codex not found. Attempting automatic Codex CLI installation.")

            do {
                let output = try await installCodexCliOnly()
                if indicatesMissingBrew(output) {
                    handleMissingHomebrew()
                    throw ViewModelError.codexNotFound
                }
                if output.exitCode != 0 {
                    let details = preferredFailureText(output)
                    log("Codex auto-install command failed (\(output.exitCode)): \(details)")
                    messages.append(ChatMessage(role: .system, content: "Codex auto-install failed (\(output.exitCode)).\n\(details)"))
                    throw ViewModelError.codexNotFound
                }
                let details = cleanOutput(output.stdout, fallback: output.stderr)
                log("Codex auto-install finished: \(details)")
                resolvedCodexExecutable = nil
                let executable = try await resolveCodexExecutable()
                messages.append(ChatMessage(role: .system, content: "Codex CLI installed automatically."))
                return executable
            } catch {
                log("Codex auto-install failed: \(error.localizedDescription)")
                throw ViewModelError.codexNotFound
            }
        }
    }

    private func runUtilityCommand(
        label: String,
        command: String,
        includeAsAssistantMessage: Bool
    ) async {
        do {
            try validateProjectSelected()
            let output = try await executeBusyCommand(label: label, command: command)

            if includeAsAssistantMessage {
                let response = cleanOutput(output.stdout, fallback: output.stderr)
                messages.append(ChatMessage(role: .assistant, content: response))
            }

            if output.exitCode != 0 {
                log("\(label) exited with code \(output.exitCode)")
            }
        } catch {
            log("Error: \(error.localizedDescription)")
            messages.append(ChatMessage(role: .assistant, content: "Error: \(error.localizedDescription)"))
        }
    }

    private func executeBusyCommand(
        label: String,
        command: String,
        workingDirectory: String? = nil,
        environment: [String: String]? = nil
    ) async throws -> CommandOutput {
        isBusy = true
        busyLabel = label
        log("[\(label)] \(commandPreview(command))")
        defer {
            isBusy = false
            busyLabel = ""
        }
        let directory = workingDirectory ?? projectPath
        return try await runner.run(
            command: command,
            workingDirectory: directory,
            environment: environment
        )
    }

    private func executeBusyExecutable(
        label: String,
        executablePath: String,
        arguments: [String],
        workingDirectory: String? = nil,
        environment: [String: String]? = nil
    ) async throws -> CommandOutput {
        isBusy = true
        busyLabel = label
        let rendered = ([shellQuote(executablePath)] + arguments.map { shellQuote($0) }).joined(separator: " ")
        log("[\(label)] \(rendered)")
        defer {
            isBusy = false
            busyLabel = ""
        }
        let directory = workingDirectory ?? projectPath
        return try await runner.run(
            executablePath: executablePath,
            arguments: arguments,
            workingDirectory: directory,
            environment: environment
        )
    }

    private func executeBusyExecutableStreaming(
        label: String,
        executablePath: String,
        arguments: [String],
        workingDirectory: String? = nil,
        environment: [String: String]? = nil,
        onLine: @escaping @Sendable (StreamSource, String) -> Void
    ) async throws -> CommandOutput {
        isBusy = true
        busyLabel = label
        let rendered = ([shellQuote(executablePath)] + arguments.map { shellQuote($0) }).joined(separator: " ")
        log("[\(label)] \(rendered)")
        defer {
            isBusy = false
            busyLabel = ""
        }
        let directory = workingDirectory ?? projectPath
        return try await runner.runStreaming(
            executablePath: executablePath,
            arguments: arguments,
            workingDirectory: directory,
            environment: environment,
            onLine: onLine
        )
    }

    private func validateProjectAndTemplate(prompt: String) throws {
        try validateProjectSelected()
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ViewModelError.emptyPrompt
        }
    }

    private func validateProjectSelected() throws {
        guard !projectPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ViewModelError.projectNotSelected
        }
    }

    private func buildPromptWithHistory(newPrompt: String) -> String {
        let recentHistory = messages.suffix(8).map { message in
            let normalized = message.content.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            let clipped = normalized.count > 700 ? String(normalized.prefix(700)) + "..." : normalized
            return "\(message.role.rawValue): \(clipped)"
        }.joined(separator: "\n")

        return """
        You are operating as an autonomous coding agent in the selected project folder.
        Implement requested changes directly in files and run needed commands.
        Do not stop at suggestions when you can safely make the change in this workspace.
        Keep your final response concise and action-focused.
        Recent conversation:
        \(recentHistory)

        Latest user request:
        \(newPrompt)
        """
    }

    private func resolveCodexExecutable() async throws -> String {
        if let resolvedCodexExecutable, FileManager.default.isExecutableFile(atPath: resolvedCodexExecutable) {
            return resolvedCodexExecutable
        }
        resolvedCodexExecutable = nil

        let codexNames = ["codex", "codex-x86_64-apple-darwin", "codex-aarch64-apple-darwin"]
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        let overridePath = (codexPathOverride as NSString).expandingTildeInPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !overridePath.isEmpty {
            if FileManager.default.isExecutableFile(atPath: overridePath) {
                resolvedCodexExecutable = overridePath
                log("Using Codex override: \(overridePath)")
                return overridePath
            }
            log("Configured Codex path is not executable: \(overridePath)")
        }

        let envOverride = (ProcessInfo.processInfo.environment["CODEX_BINARY"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !envOverride.isEmpty && FileManager.default.isExecutableFile(atPath: envOverride) {
            resolvedCodexExecutable = envOverride
            log("Using Codex from CODEX_BINARY: \(envOverride)")
            return envOverride
        }

        var candidates: [String] = []
        if let resources = Bundle.main.resourceURL?.path {
            for name in codexNames {
                candidates.append("\(resources)/\(name)")
            }
        }

        let fixedDirectories = [
            "/Applications/Codex.app/Contents/Resources",
            "/Applications/Codex.app/Contents/MacOS",
            "\(home)/Applications/Codex.app/Contents/Resources",
            "\(home)/Applications/Codex.app/Contents/MacOS",
            "/usr/local/bin",
            "/opt/homebrew/bin",
            "/usr/bin",
            "/bin"
        ]
        for directory in fixedDirectories {
            for name in codexNames {
                candidates.append("\(directory)/\(name)")
            }
        }

        let envPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        for directory in envPath.split(separator: ":").map(String.init) where !directory.isEmpty {
            for name in codexNames {
                candidates.append("\(directory)/\(name)")
            }
        }

        let caskRoots = [
            "/usr/local/Caskroom/codex",
            "/opt/homebrew/Caskroom/codex"
        ]
        for root in caskRoots {
            if let versions = try? FileManager.default.contentsOfDirectory(atPath: root) {
                for version in versions {
                    for name in codexNames {
                        candidates.append("\(root)/\(version)/\(name)")
                    }
                }
            }
        }

        let appBases = [
            "/Applications",
            "\(home)/Applications"
        ]
        for appBase in appBases {
            if let entries = try? FileManager.default.contentsOfDirectory(atPath: appBase) {
                for entry in entries where entry.lowercased().contains("codex") && entry.hasSuffix(".app") {
                    for subDirectory in ["Contents/Resources", "Contents/MacOS"] {
                        for name in codexNames {
                            candidates.append("\(appBase)/\(entry)/\(subDirectory)/\(name)")
                        }
                    }
                }
            }
        }

        var seen = Set<String>()
        let orderedCandidates = candidates.filter { seen.insert($0).inserted }

        for candidate in orderedCandidates where FileManager.default.isExecutableFile(atPath: candidate) {
            resolvedCodexExecutable = candidate
            log("Using Codex binary: \(candidate)")
            return candidate
        }

        log("Codex search failed across \(orderedCandidates.count) candidate paths.")
        throw ViewModelError.codexNotFound
    }

    private func autoCommitAndPushAfterChat() async {
        guard isGitConfigured else { return }
        let project = projectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !project.isEmpty else { return }
        guard let target = configuredGitTarget() else { return }

        let commit = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Update via CodexIntelApp"
            : commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = "git add -A && (git diff --cached --quiet || git commit -m \(shellQuote(commit))) && git push -u \(shellQuote(target.remote)) \(shellQuote(target.branch))"

        do {
            let output = try await executeBusyCommand(label: "Auto commit + push", command: command)
            if output.exitCode != 0 {
                let details = cleanOutput(output.stdout, fallback: output.stderr)
                log("Auto push failed with code \(output.exitCode): \(details)")
                messages.append(ChatMessage(role: .system, content: "Auto push failed: \(details)"))
            } else {
                log("Auto push completed for \(target.remote)/\(target.branch).")
            }
        } catch {
            log("Auto push error: \(error.localizedDescription)")
            messages.append(ChatMessage(role: .system, content: "Auto push error: \(error.localizedDescription)"))
        }
    }

    private func configuredGitTarget() -> (remote: String, branch: String)? {
        let remote = gitRemote.trimmingCharacters(in: .whitespacesAndNewlines)
        let branch = gitBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remote.isEmpty && !branch.isEmpty else { return nil }
        return (remote, branch)
    }

    private func ensureProjectDirectoryTrustAndAccess() async {
        let path = projectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }
        let probeFile = "\(path)/.codexintelapp_rw_probe"
        let command = """
        chmod u+rwx \(shellQuote(path)) &&
        test -r \(shellQuote(path)) &&
        test -w \(shellQuote(path)) &&
        touch \(shellQuote(probeFile)) &&
        rm -f \(shellQuote(probeFile)) &&
        if command -v git >/dev/null 2>&1; then git config --global --add safe.directory \(shellQuote(path)) || true; fi
        """
        guard let output = try? await runner.run(command: command, workingDirectory: nil) else {
            log("Unable to verify project directory trust/read-write access.")
            return
        }
        if output.exitCode == 0 {
            log("Project directory trust/read-write verified.")
        } else {
            let details = preferredFailureText(output)
            log("Project directory access verification failed (\(output.exitCode)): \(details)")
            messages.append(ChatMessage(role: .system, content: "Project directory access check failed (\(output.exitCode)).\n\(details)"))
        }
    }

    private func runDependencyInstaller(autoTriggered: Bool = false) async {
        let command = dependencyInstallScript(includeExtras: true)

        do {
            let output = try await executeBusyCommand(
                label: autoTriggered ? "Auto setup dependencies" : "Installing dependencies",
                command: command,
                workingDirectory: nil
            )
            if indicatesMissingBrew(output) {
                handleMissingHomebrew()
                return
            }
            if output.exitCode != 0 {
                let details = preferredFailureText(output)
                messages.append(ChatMessage(role: .system, content: "Dependency setup failed (\(output.exitCode)).\n\(details)"))
                log("Dependency setup failed with code \(output.exitCode): \(details)")
                return
            }
            resolvedCodexExecutable = nil
            let details = cleanOutput(output.stdout, fallback: output.stderr)
            let completionMessage = autoTriggered
                ? "Automatic dependency setup complete.\n\(details)"
                : "Dependency setup complete.\n\(details)"
            messages.append(ChatMessage(role: .system, content: completionMessage))
            log("Dependency setup completed.")
        } catch {
            let text = error.localizedDescription
            messages.append(ChatMessage(role: .system, content: "Dependency setup failed: \(text)"))
            log("Dependency setup failed: \(text)")
        }
    }

    private func installCodexCliOnly() async throws -> CommandOutput {
        let command = dependencyInstallScript(includeExtras: false)
        return try await executeBusyCommand(
            label: "Auto-installing Codex CLI",
            command: command,
            workingDirectory: nil
        )
    }

    private func dependencyInstallScript(includeExtras: Bool) -> String {
        let extraInstalls = includeExtras
            ? """
            if ! "$BREW_BIN" list git >/dev/null 2>&1; then "$BREW_BIN" install git; fi
            if ! "$BREW_BIN" list --cask visual-studio-code >/dev/null 2>&1; then "$BREW_BIN" install --cask visual-studio-code || true; fi
            """
            : ""

        return """
        set -e
        export NONINTERACTIVE=1

        BREW_BIN="$(command -v brew || true)"
        if [ -z "$BREW_BIN" ] && [ -x /opt/homebrew/bin/brew ]; then BREW_BIN=/opt/homebrew/bin/brew; fi
        if [ -z "$BREW_BIN" ] && [ -x /usr/local/bin/brew ]; then BREW_BIN=/usr/local/bin/brew; fi
        if [ -z "$BREW_BIN" ]; then
          echo "\(missingBrewMarker)"
          exit 86
        fi

        eval "$("$BREW_BIN" shellenv)"

        if ! "$BREW_BIN" list ripgrep >/dev/null 2>&1; then "$BREW_BIN" install ripgrep; fi
        if ! "$BREW_BIN" list --cask codex >/dev/null 2>&1; then "$BREW_BIN" install --cask codex; fi
        \(extraInstalls)
        echo "Dependency setup finished."
        """
    }

    private func indicatesMissingBrew(_ output: CommandOutput) -> Bool {
        let combined = output.stdout + "\n" + output.stderr
        return combined.contains(missingBrewMarker)
    }

    private func handleMissingHomebrew() {
        log("Homebrew missing. Opening https://brew.sh")
        if let url = URL(string: "https://brew.sh") {
            NSWorkspace.shared.open(url)
        }
        messages.append(
            ChatMessage(
                role: .system,
                content: "Homebrew is required to auto-install Codex CLI. I opened brew.sh. Install Homebrew, then re-select the project folder or send the chat again."
            )
        )
    }

    private func resetRunFeedback() {
        thinkingStatus = ""
        liveActivity.removeAll()
        latestDiffAdded = 0
        latestDiffRemoved = 0
        latestDiffFiles.removeAll()
        latestDiffLines.removeAll()
    }

    private func appendActivity(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        liveActivity.append(trimmed)
        if liveActivity.count > 220 {
            liveActivity.removeFirst(liveActivity.count - 220)
        }
    }

    private func handleCodexStreamLine(source: StreamSource, line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard let event = parseCodexJSONEvent(from: trimmed) else {
            if source == .stderr {
                log("[codex] \(trimmed)")
                if trimmed.contains("WARN") || trimmed.contains("Error") || trimmed.contains("error") {
                    appendActivity(trimmed)
                }
            }
            return
        }

        let type = (event["type"] as? String) ?? "event"
        if type.contains("delta") {
            return
        }

        switch type {
        case "turn.started":
            thinkingStatus = "Thinking..."
            appendActivity("Thinking...")
        case "turn.completed":
            thinkingStatus = "Applying changes..."
            appendActivity("Applying edits...")
        case "turn.failed":
            thinkingStatus = ""
            appendActivity("Codex failed")
        default:
            if let summary = summarizeCodexEvent(type: type, event: event) {
                appendActivity(summary)
            }
        }
    }

    private func parseCodexJSONEvent(from line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return object as? [String: Any]
    }

    private func summarizeCodexEvent(type: String, event: [String: Any]) -> String? {
        if type == "thread.started" || type == "thread.completed" {
            return nil
        }
        if type == "error" {
            let message = (event["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown error"
            return "Error: \(message)"
        }

        if let command = event["command"] as? String, !command.isEmpty {
            return "Running: \(command)"
        }

        if let message = event["message"] as? String, !message.isEmpty {
            return message
        }

        if let item = event["item"] as? [String: Any] {
            if let toolName = item["tool_name"] as? String, !toolName.isEmpty {
                return "Tool: \(toolName)"
            }
            if let content = item["content"] {
                let values = flattenedStrings(from: content)
                if let first = values.first(where: { !$0.isEmpty }) {
                    return first
                }
            }
        }

        if let content = event["content"] {
            let values = flattenedStrings(from: content)
            if let first = values.first(where: { !$0.isEmpty }) {
                return first
            }
        }

        if type.contains("tool") {
            return "Tool event: \(type)"
        }
        if type.contains("turn") {
            return "Turn event: \(type)"
        }
        return nil
    }

    private func flattenedStrings(from value: Any) -> [String] {
        if let text = value as? String {
            return [text.trimmingCharacters(in: .whitespacesAndNewlines)]
        }
        if let array = value as? [Any] {
            return array.flatMap { flattenedStrings(from: $0) }
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.values.flatMap { flattenedStrings(from: $0) }
        }
        return []
    }

    private func readAssistantOutput(from url: URL, fallback: String) -> String {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            return fallback
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private func refreshChangeSummary() async {
        guard await isGitWorkspace() else {
            appendActivity("No git repository detected. Change summary is unavailable.")
            return
        }

        do {
            let numstatOutput = try await runner.run(
                command: "git diff --numstat -- .",
                workingDirectory: projectPath
            )
            let patchOutput = try await runner.run(
                command: "git diff --no-color --unified=0 -- .",
                workingDirectory: projectPath
            )
            let untrackedOutput = try await runner.run(
                command: """
                git ls-files --others --exclude-standard -z | while IFS= read -r -d '' f; do
                  lines="$(wc -l < "$f" | tr -d '[:space:]')"
                  if [ -z "$lines" ]; then lines=0; fi
                  printf "%s\\t0\\t%s\\n" "$lines" "$f"
                done
                """,
                workingDirectory: projectPath
            )

            var statsByFile: [String: (added: Int, removed: Int)] = [:]
            for file in parseNumstat(numstatOutput.stdout + "\n" + untrackedOutput.stdout) {
                let existing = statsByFile[file.path] ?? (0, 0)
                statsByFile[file.path] = (existing.added + file.added, existing.removed + file.removed)
            }

            let files = statsByFile.keys.sorted().map { path in
                let value = statsByFile[path] ?? (0, 0)
                return DiffFileStat(path: path, added: value.added, removed: value.removed)
            }

            latestDiffFiles = files
            latestDiffAdded = files.reduce(0) { $0 + $1.added }
            latestDiffRemoved = files.reduce(0) { $0 + $1.removed }
            latestDiffLines = parseDiffLines(patchOutput.stdout, limit: 200)

            if files.isEmpty {
                appendActivity("No working tree changes detected.")
            } else {
                appendActivity("Changed lines: +\(latestDiffAdded) / -\(latestDiffRemoved) across \(files.count) file(s).")
            }
        } catch {
            log("Unable to build change summary: \(error.localizedDescription)")
            appendActivity("Unable to build change summary: \(error.localizedDescription)")
        }
    }

    private func isGitWorkspace() async -> Bool {
        guard !projectPath.isEmpty else { return false }
        guard let output = try? await runner.run(
            command: "git rev-parse --is-inside-work-tree",
            workingDirectory: projectPath
        ) else { return false }
        guard output.exitCode == 0 else { return false }
        let text = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return text == "true"
    }

    private func parseNumstat(_ text: String) -> [DiffFileStat] {
        text
            .split(separator: "\n")
            .compactMap { rawLine in
                let parts = rawLine.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
                guard parts.count == 3 else { return nil }
                let added = Int(parts[0]) ?? 0
                let removed = Int(parts[1]) ?? 0
                let path = String(parts[2]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !path.isEmpty else { return nil }
                return DiffFileStat(path: path, added: added, removed: removed)
            }
    }

    private func parseDiffLines(_ diffText: String, limit: Int) -> [DiffLine] {
        var currentFile = "(unknown)"
        var lines: [DiffLine] = []

        for raw in diffText.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)

            if line.hasPrefix("diff --git ") {
                let parts = line.split(separator: " ")
                if let candidate = parts.last {
                    let value = String(candidate)
                    currentFile = value.hasPrefix("b/") ? String(value.dropFirst(2)) : value
                }
                continue
            }
            if line.hasPrefix("+++ b/") {
                currentFile = String(line.dropFirst(6))
                continue
            }
            if line.hasPrefix("--- ") || line.hasPrefix("index ") || line.hasPrefix("@@") || line.hasPrefix("new file mode") || line.hasPrefix("deleted file mode") {
                continue
            }

            if line.hasPrefix("+"), !line.hasPrefix("+++") {
                lines.append(DiffLine(file: currentFile, kind: .added, text: String(line.dropFirst())))
            } else if line.hasPrefix("-"), !line.hasPrefix("---") {
                lines.append(DiffLine(file: currentFile, kind: .removed, text: String(line.dropFirst())))
            }

            if lines.count >= limit {
                break
            }
        }

        return lines
    }

    private func log(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let entry = "[\(formatter.string(from: Date()))] \(message)"
        commandLog.append(entry)
    }

    private func cleanOutput(_ stdout: String, fallback stderr: String) -> String {
        let out = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !out.isEmpty { return out }
        let err = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !err.isEmpty { return err }
        return "(No output)"
    }

    private func preferredFailureText(_ output: CommandOutput) -> String {
        let err = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !err.isEmpty { return err }
        let out = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !out.isEmpty { return out }
        return "(No error details)"
    }

    private func shellQuote(_ value: String) -> String {
        if value.isEmpty { return "''" }
        let escaped = value.replacingOccurrences(of: "'", with: "'\"'\"'")
        return "'\(escaped)'"
    }

    private func commandPreview(_ command: String) -> String {
        let compact = command.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "  ", with: " ")
        let maxLength = 180
        if compact.count <= maxLength { return compact }
        return String(compact.prefix(maxLength)) + "..."
    }
}

struct ContentView: View {
    @StateObject private var viewModel = AppViewModel()

    var body: some View {
        HStack(spacing: 0) {
            controlPanel
                .frame(width: 360)
                .background(Color(nsColor: .windowBackgroundColor))
            Divider()
            conversationPanel
        }
    }

    private var controlPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Project")
                        .font(.headline)
                    Text(viewModel.projectPath.isEmpty ? "No folder selected" : viewModel.projectPath)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                    HStack {
                        Button("Open Folder") {
                            viewModel.chooseProjectFolder()
                        }
                        Button("Locate Codex") {
                            viewModel.chooseCodexBinary()
                        }
                        .disabled(viewModel.isBusy)
                        Button("Open in VS Code") {
                            viewModel.openInVSCode()
                        }
                        .disabled(viewModel.projectPath.isEmpty || viewModel.isBusy)
                    }
                    TextField("Codex Path (optional override)", text: $viewModel.codexPathOverride)
                        .textFieldStyle(.roundedBorder)
                        .disabled(viewModel.isBusy)
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Git")
                        .font(.headline)
                    TextField("Remote", text: $viewModel.gitRemote)
                        .textFieldStyle(.roundedBorder)
                    TextField("Branch", text: $viewModel.gitBranch)
                        .textFieldStyle(.roundedBorder)
                    TextField("Commit Message", text: $viewModel.commitMessage)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button("Push") {
                            viewModel.gitPush()
                        }
                        .disabled(viewModel.projectPath.isEmpty || viewModel.isBusy || !viewModel.isGitConfigured)

                        Button("Commit + Push") {
                            viewModel.gitCommitAndPush()
                        }
                        .disabled(viewModel.projectPath.isEmpty || viewModel.isBusy || !viewModel.isGitConfigured)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Command Log")
                        .font(.headline)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(viewModel.commandLog.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.caption2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(minHeight: 180, maxHeight: 240)
                    .padding(8)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Live Activity")
                        .font(.headline)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            if viewModel.liveActivity.isEmpty {
                                Text("Activity appears here while Codex is running.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            } else {
                                ForEach(Array(viewModel.liveActivity.enumerated()), id: \.offset) { _, line in
                                    Text(line)
                                        .font(.caption2)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                    }
                    .frame(minHeight: 120, maxHeight: 180)
                    .padding(8)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Changes (Last Run)")
                        .font(.headline)
                    HStack(spacing: 10) {
                        Text("+\(viewModel.latestDiffAdded)")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.green)
                        Text("-\(viewModel.latestDiffRemoved)")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.red)
                    }

                    if viewModel.latestDiffFiles.isEmpty {
                        Text("No change summary available yet.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(viewModel.latestDiffFiles) { file in
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Text(file.path)
                                            .font(.caption2)
                                            .lineLimit(1)
                                        Spacer(minLength: 4)
                                        Text("+\(file.added)")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundColor(.green)
                                        Text("-\(file.removed)")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundColor(.red)
                                    }
                                }
                            }
                        }
                        .frame(minHeight: 90, maxHeight: 140)
                        .padding(8)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    if !viewModel.latestDiffLines.isEmpty {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(viewModel.latestDiffLines) { line in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(line.file)
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                        HStack(alignment: .top, spacing: 6) {
                                            Text(line.kind == .added ? "+" : "-")
                                                .font(.caption.weight(.semibold))
                                                .foregroundColor(line.kind == .added ? .green : .red)
                                            Text(line.text)
                                                .font(.system(.caption, design: .monospaced))
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                    }
                                }
                            }
                        }
                        .frame(minHeight: 120, maxHeight: 200)
                        .padding(8)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .padding(16)
        }
    }

    private var conversationPanel: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Conversation")
                    .font(.title3.weight(.semibold))
                Spacer()
                if viewModel.isBusy {
                    ProgressView()
                        .controlSize(.small)
                    Text(viewModel.thinkingStatus.isEmpty ? viewModel.busyLabel : viewModel.thinkingStatus)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(viewModel.messages) { message in
                        MessageBubble(message: message)
                    }
                }
                .padding(16)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 16)

            HStack(alignment: .bottom, spacing: 10) {
                TextField("Ask Codex to edit files, run commands, or implement features...", text: $viewModel.draftPrompt)
                    .textFieldStyle(.roundedBorder)
                    .disabled(viewModel.isBusy)
                    .onSubmit {
                        viewModel.sendPrompt()
                    }

                Button("Send") {
                    viewModel.sendPrompt()
                }
                .disabled(viewModel.projectPath.isEmpty || viewModel.isBusy || viewModel.draftPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }
}

struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(message.role.rawValue)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(roleColor)
                Spacer()
                Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Text(message.content)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(roleColor.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var roleColor: Color {
        switch message.role {
        case .user:
            return .blue
        case .assistant:
            return .green
        case .system:
            return .orange
        }
    }
}
