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

struct CodexModelsCache: Decodable {
    let models: [CodexModelDescriptor]
}

struct CodexModelDescriptor: Decodable {
    let slug: String
    let visibility: String?
    let defaultReasoningLevel: String?
    let supportedReasoningLevels: [CodexReasoningDescriptor]?

    enum CodingKeys: String, CodingKey {
        case slug
        case visibility
        case defaultReasoningLevel = "default_reasoning_level"
        case supportedReasoningLevels = "supported_reasoning_levels"
    }
}

struct CodexReasoningDescriptor: Decodable {
    let effort: String
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
    @Published var codexCliVersion = "Detecting..."
    @Published var codexSessionState = "Not started"
    @Published var selectedModel = "gpt-5.3-codex"
    @Published var selectedReasoningEffort = "xhigh"
    @Published var availableModels = ["gpt-5.3-codex"]
    @Published var availableReasoningEfforts = ["low", "medium", "high", "xhigh"]

    @Published var gitRemote = ""
    @Published var gitBranch = ""
    @Published var commitMessage = "Update via CodexIntelApp"
    @Published var showGitSetup = false
    @Published var showPowerUserPanel = false
    @Published var showChangesAccordion = false

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
    private var activeSessionID: String?
    private var sessionBootInProgress = false
    private var modelEffortsBySlug: [String: [String]] = [:]
    private var currentRunAssistantDeltas = ""
    private var currentRunAssistantCompletions: [String] = []
    private var detectedStaleSessionErrorInCurrentRun = false

    init() {
        applyModelDefaultsFromConfig()
        loadModelCatalogFromCache()
        updateReasoningOptionsForSelectedModel()
        Task {
            await refreshCodexVersion()
        }
    }

    var isGitConfigured: Bool {
        !gitRemote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !gitBranch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var currentModelSummary: String {
        "\(selectedModel) | \(reasoningDisplayName(for: selectedReasoningEffort))"
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
            resetSession(reason: nil)
            log("Selected project: \(projectPath)")
            Task {
                await ensureProjectDirectoryTrustAndAccess()
                await runDependencyInstaller(autoTriggered: true)
                await refreshCodexVersion()
                do {
                    let codexExecutable = try await ensureCodexExecutableAvailable()
                    await startPersistentAutonomousSessionIfNeeded(executablePath: codexExecutable)
                } catch {
                    log("Unable to start persistent session after folder select: \(error.localizedDescription)")
                }
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
            resetSession(reason: "Codex path changed. Starting a fresh autonomous session.")
            log("Configured Codex path override: \(url.path)")
        }
    }

    func modelSelectionDidChange() {
        updateReasoningOptionsForSelectedModel()
        resetSession(reason: "Model changed. Starting a fresh autonomous session.")
        Task {
            await maybeStartSessionForCurrentProject()
        }
    }

    func reasoningSelectionDidChange() {
        resetSession(reason: "Reasoning effort changed. Starting a fresh autonomous session.")
        Task {
            await maybeStartSessionForCurrentProject()
        }
    }

    func reasoningDisplayName(for effort: String) -> String {
        switch effort.lowercased() {
        case "low":
            return "Low"
        case "medium":
            return "Medium"
        case "high":
            return "High"
        case "xhigh":
            return "Extra High"
        default:
            return effort
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
        resetAssistantCapture()

        do {
            try validateProjectAndTemplate(prompt: userPrompt)
            let codexExecutable = try await ensureCodexExecutableAvailable()
            await ensureProjectDirectoryTrustAndAccess()
            await startPersistentAutonomousSessionIfNeeded(executablePath: codexExecutable)

            resetAssistantCapture()
            let prompt = buildPromptWithHistory(newPrompt: userPrompt)
            thinkingStatus = "Thinking..."
            appendActivity("Running autonomous Codex turn")

            let codexArguments = buildCodexTurnArguments(prompt: prompt)
            var output = try await executeBusyExecutableStreaming(
                label: "Running Codex",
                executablePath: codexExecutable,
                arguments: codexArguments
            ) { [weak self] source, line in
                Task { @MainActor in
                    self?.handleCodexStreamLine(source: source, line: line)
                }
            }

            if output.exitCode != 0 && shouldRetryWithFreshSession(output) {
                log("Detected stale Codex session state. Retrying with a fresh session.")
                appendActivity("Session state stale. Retrying with a fresh session.")
                resetSession(reason: "Recovered from stale session state.")
                resetAssistantCapture()
                detectedStaleSessionErrorInCurrentRun = false
                thinkingStatus = "Retrying..."

                output = try await executeBusyExecutableStreaming(
                    label: "Running Codex (retry)",
                    executablePath: codexExecutable,
                    arguments: buildCodexExecArguments(prompt: prompt)
                ) { [weak self] source, line in
                    Task { @MainActor in
                        self?.handleCodexStreamLine(source: source, line: line)
                    }
                }
            }

            if output.exitCode != 0 {
                log("Codex exited with code \(output.exitCode)")
                let errorText = conversationSafePlainEnglish(preferredFailureText(output))
                messages.append(ChatMessage(role: .assistant, content: "Codex failed (\(output.exitCode)). \(errorText)"))
                appendActivity("Codex exited with code \(output.exitCode)")
                thinkingStatus = ""
                return
            }
            let rawResponse = resolvedAssistantResponse(fallback: cleanOutput(output.stdout, fallback: output.stderr))
            let response = conversationSafePlainEnglish(rawResponse)
            messages.append(ChatMessage(role: .assistant, content: response))
            appendActivity("Codex response complete")
            thinkingStatus = ""
            await refreshChangeSummary()
        } catch {
            let text = error.localizedDescription
            messages.append(ChatMessage(role: .assistant, content: conversationSafePlainEnglish("Error: \(text)")))
            log("Error: \(text)")
            appendActivity("Error: \(text)")
            thinkingStatus = ""
        }
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
                let response = conversationSafePlainEnglish(cleanOutput(output.stdout, fallback: output.stderr))
                messages.append(ChatMessage(role: .assistant, content: response))
            }

            if output.exitCode != 0 {
                log("\(label) exited with code \(output.exitCode)")
            }
        } catch {
            log("Error: \(error.localizedDescription)")
            messages.append(ChatMessage(role: .assistant, content: conversationSafePlainEnglish("Error: \(error.localizedDescription)")))
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
        let recentHistory = messages.suffix(6).map { message in
            let normalized = message.content.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            let clipped = normalized.count > 500 ? String(normalized.prefix(500)) + "..." : normalized
            return "\(message.role.rawValue): \(clipped)"
        }.joined(separator: "\n")

        return """
        You are operating as an autonomous coding agent in the selected project folder.
        Implement requested changes directly in files and run needed commands.
        Do not stop at suggestions when you can safely make the change in this workspace.
        Keep your final response concise and action-focused.
        Final response format: plain English only for non-technical readers.
        Do not include code blocks, diffs, file contents, or command snippets in the response.
        Summarize what changed in a short user-friendly update.
        If a command fails, debug and retry with a concrete fix.

        Latest user request:
        \(newPrompt)

        Recent conversation:
        \(recentHistory)
        """
    }

    private func maybeStartSessionForCurrentProject() async {
        let path = projectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }
        do {
            let codexExecutable = try await ensureCodexExecutableAvailable()
            await startPersistentAutonomousSessionIfNeeded(executablePath: codexExecutable)
        } catch {
            log("Unable to start session for current project: \(error.localizedDescription)")
        }
    }

    private func startPersistentAutonomousSessionIfNeeded(executablePath: String) async {
        if let activeSessionID, !activeSessionID.isEmpty {
            codexSessionState = "Active (\(shortSessionID(activeSessionID)))"
            return
        }
        guard !sessionBootInProgress else { return }
        sessionBootInProgress = true
        defer { sessionBootInProgress = false }

        codexSessionState = "Starting..."
        thinkingStatus = "Starting session..."
        appendActivity("Starting persistent autonomous session")
        resetAssistantCapture()

        let bootstrapPrompt = """
        Start a persistent autonomous coding session in this project directory.
        Do not modify files in this bootstrap turn.
        Reply exactly: SESSION_READY
        """

        do {
            let output = try await executeBusyExecutableStreaming(
                label: "Starting Codex Session",
                executablePath: executablePath,
                arguments: buildCodexExecArguments(prompt: bootstrapPrompt)
            ) { [weak self] source, line in
                Task { @MainActor in
                    self?.handleCodexStreamLine(source: source, line: line)
                }
            }

            if output.exitCode != 0 {
                codexSessionState = "Start failed"
                appendActivity("Session start failed (\(output.exitCode))")
                thinkingStatus = ""
                return
            }

            if let activeSessionID, !activeSessionID.isEmpty {
                codexSessionState = "Active (\(shortSessionID(activeSessionID)))"
                appendActivity("Session active.")
            } else {
                codexSessionState = "Ready"
                appendActivity("Session ready.")
            }
        } catch {
            codexSessionState = "Start failed"
            appendActivity("Session start error: \(error.localizedDescription)")
        }
        thinkingStatus = ""
    }

    private func buildCodexTurnArguments(prompt: String) -> [String] {
        if let activeSessionID, !activeSessionID.isEmpty {
            return buildCodexResumeArguments(sessionID: activeSessionID, prompt: prompt)
        }
        return buildCodexExecArguments(prompt: prompt)
    }

    private func buildCodexExecArguments(prompt: String) -> [String] {
        ["exec"] + codexModelArguments() + [
            "--json",
            "--full-auto",
            "--skip-git-repo-check",
            prompt
        ]
    }

    private func buildCodexResumeArguments(sessionID: String, prompt: String) -> [String] {
        ["exec", "resume"] + codexModelArguments() + [
            "--json",
            "--full-auto",
            "--skip-git-repo-check",
            sessionID,
            prompt
        ]
    }

    private func codexModelArguments() -> [String] {
        let model = selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let effort = selectedReasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines)
        var args: [String] = []
        if !model.isEmpty {
            args += ["-m", model]
        }
        if !effort.isEmpty {
            args += ["-c", "model_reasoning_effort=\"\(effort)\""]
        }
        return args
    }

    private func resetSession(reason: String?) {
        activeSessionID = nil
        codexSessionState = "Not started"
        if let reason {
            appendActivity(reason)
        }
    }

    private func shortSessionID(_ id: String) -> String {
        String(id.prefix(8))
    }

    private func refreshCodexVersion() async {
        guard let output = try? await runner.run(command: "codex --version", workingDirectory: nil) else {
            codexCliVersion = "Not found"
            return
        }
        let version = cleanOutput(output.stdout, fallback: output.stderr)
        codexCliVersion = version.replacingOccurrences(of: "\n", with: " ")
    }

    private func applyModelDefaultsFromConfig() {
        let configPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/config.toml")
            .path
        guard let configText = try? String(contentsOfFile: configPath, encoding: .utf8) else { return }
        for rawLine in configText.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if let value = parseQuotedTOMLValue(line: line, key: "model") {
                selectedModel = value
            }
            if let value = parseQuotedTOMLValue(line: line, key: "model_reasoning_effort") {
                selectedReasoningEffort = value
            }
        }
    }

    private func loadModelCatalogFromCache() {
        let cachePath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/models_cache.json")
            .path
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: cachePath)) else { return }
        guard let cache = try? JSONDecoder().decode(CodexModelsCache.self, from: data) else { return }

        let visibleModels = cache.models.filter { model in
            guard let visibility = model.visibility else { return true }
            return visibility != "hidden"
        }

        let slugs = visibleModels.map(\.slug)
        if !slugs.isEmpty {
            availableModels = slugs
        }

        var effortMap: [String: [String]] = [:]
        for model in visibleModels {
            let efforts = model.supportedReasoningLevels?.map(\.effort).filter { !$0.isEmpty } ?? []
            let fallback = model.defaultReasoningLevel.map { [$0] } ?? ["medium"]
            effortMap[model.slug] = efforts.isEmpty ? fallback : efforts
        }
        modelEffortsBySlug = effortMap

        if !availableModels.contains(selectedModel), let first = availableModels.first {
            selectedModel = first
        }
        updateReasoningOptionsForSelectedModel()
    }

    private func updateReasoningOptionsForSelectedModel() {
        let options = modelEffortsBySlug[selectedModel] ?? ["low", "medium", "high", "xhigh"]
        availableReasoningEfforts = options
        if !options.contains(selectedReasoningEffort), let first = options.first {
            selectedReasoningEffort = first
        }
    }

    private func parseQuotedTOMLValue(line: String, key: String) -> String? {
        guard line.hasPrefix("\(key) =") else { return nil }
        guard let firstQuote = line.firstIndex(of: "\"") else { return nil }
        let rest = line[line.index(after: firstQuote)...]
        guard let lastQuote = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<lastQuote])
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
        showChangesAccordion = false
        detectedStaleSessionErrorInCurrentRun = false
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
                if isStaleSessionStateError(trimmed) {
                    detectedStaleSessionErrorInCurrentRun = true
                    appendActivity("Detected stale Codex session state.")
                }
                if trimmed.contains("WARN") || trimmed.contains("Error") || trimmed.contains("error") {
                    appendActivity(trimmed)
                }
            }
            return
        }

        let type = (event["type"] as? String) ?? "event"
        if type == "thread.started", let threadID = event["thread_id"] as? String, !threadID.isEmpty {
            activeSessionID = threadID
            codexSessionState = "Active (\(shortSessionID(threadID)))"
        }

        captureAssistantFromEvent(type: type, event: event)

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

    private func captureAssistantFromEvent(type: String, event: [String: Any]) {
        if type.contains("output_text.delta"), let delta = event["delta"] as? String, !delta.isEmpty {
            currentRunAssistantDeltas += delta
        }

        if let item = event["item"] as? [String: Any] {
            let role = (item["role"] as? String)?.lowercased()
            let itemType = (item["type"] as? String)?.lowercased()
            if role == "assistant" || (role == nil && itemType == "message") {
                let textSegments = extractAssistantTextSegments(from: item)
                let merged = textSegments.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !merged.isEmpty {
                    currentRunAssistantCompletions.append(merged)
                }
            }
        }
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

    private func isStaleSessionStateError(_ text: String) -> Bool {
        let lowered = text.lowercased()
        if lowered.contains("missing rollout path for thread") {
            return true
        }
        if lowered.contains("state db"), lowered.contains("missing rollout"), lowered.contains("thread") {
            return true
        }
        return false
    }

    private func shouldRetryWithFreshSession(_ output: CommandOutput) -> Bool {
        if detectedStaleSessionErrorInCurrentRun {
            return true
        }
        return isStaleSessionStateError(output.stderr + "\n" + output.stdout)
    }

    private func resetAssistantCapture() {
        currentRunAssistantDeltas = ""
        currentRunAssistantCompletions.removeAll()
    }

    private func resolvedAssistantResponse(fallback: String) -> String {
        if let last = currentRunAssistantCompletions.last {
            let trimmed = last.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        let delta = currentRunAssistantDeltas.trimmingCharacters(in: .whitespacesAndNewlines)
        if !delta.isEmpty {
            return delta
        }
        return fallback
    }

    private func conversationSafePlainEnglish(_ text: String) -> String {
        var sanitized = stripFencedCodeBlocks(from: text)
        sanitized = stripInlineCodeMarkers(from: sanitized)
        sanitized = stripLikelyCodeLines(from: sanitized)
        sanitized = sanitizeMarkdown(from: sanitized)
        sanitized = collapseBlankLines(in: sanitized).trimmingCharacters(in: .whitespacesAndNewlines)

        let summary = summarizePlainEnglish(sanitized)
        if summary.isEmpty {
            return "Completed. I applied updates to your project and summarized the result."
        }
        return summary
    }

    private func stripFencedCodeBlocks(from text: String) -> String {
        var lines: [String] = []
        var inFence = false

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            if !inFence {
                lines.append(line)
            }
        }

        return lines.joined(separator: "\n")
    }

    private func stripInlineCodeMarkers(from text: String) -> String {
        text.replacingOccurrences(of: "`", with: "")
    }

    private func stripLikelyCodeLines(from text: String) -> String {
        let output = text.split(separator: "\n", omittingEmptySubsequences: false).filter { rawLine in
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return true }
            if isLikelyCodeLine(trimmed) { return false }
            return true
        }
        return output.map(String.init).joined(separator: "\n")
    }

    private func isLikelyCodeLine(_ trimmed: String) -> Bool {
        if trimmed.hasPrefix("diff --git") || trimmed.hasPrefix("@@") { return true }
        if trimmed.hasPrefix("+++ ") || trimmed.hasPrefix("--- ") { return true }
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("}") { return true }
        if trimmed.hasPrefix("$ ") || trimmed.hasPrefix("> ") { return true }
        if trimmed.hasPrefix("func ") || trimmed.hasPrefix("class ") || trimmed.hasPrefix("struct ") { return true }
        if trimmed.hasPrefix("import ") || trimmed.hasPrefix("return ") || trimmed.hasPrefix("let ") || trimmed.hasPrefix("var ") { return true }
        if trimmed.hasPrefix("#include") || trimmed.hasPrefix("public ") || trimmed.hasPrefix("private ") { return true }
        if trimmed.contains("=>") || trimmed.contains("::") { return true }
        if trimmed.contains("{") && trimmed.contains("}") { return true }
        if trimmed.contains("(") && trimmed.contains(")") && trimmed.contains("{") { return true }
        if trimmed.contains(";") { return true }

        let punctuationCount = trimmed.filter { "{}[]();=<>".contains($0) }.count
        if punctuationCount >= 5 { return true }
        return false
    }

    private func sanitizeMarkdown(from text: String) -> String {
        let cleaned = text.split(separator: "\n", omittingEmptySubsequences: false).map { rawLine in
            sanitizeMarkdownLine(String(rawLine))
        }
        return cleaned.joined(separator: "\n")
    }

    private func sanitizeMarkdownLine(_ line: String) -> String {
        var value = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return "" }

        value = value.replacingOccurrences(
            of: "^[-*+]\\s+",
            with: "",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: "^\\d+\\.\\s+",
            with: "",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: "^#{1,6}\\s*",
            with: "",
            options: .regularExpression
        )
        return value
    }

    private func summarizePlainEnglish(_ text: String) -> String {
        let compact = text.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compact.isEmpty else { return "" }

        let sentenceCandidates = compact.replacingOccurrences(
            of: "(?<=[.!?])\\s+",
            with: "\n",
            options: .regularExpression
        ).split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }

        let proseSentences = sentenceCandidates.filter { sentence in
            guard !sentence.isEmpty else { return false }
            if isLikelyCodeLine(sentence) { return false }
            return true
        }

        let summarySource = proseSentences.isEmpty ? [compact] : proseSentences
        let summary = summarySource.prefix(4).joined(separator: " ")
        if summary.count <= 420 {
            return summary
        }
        return String(summary.prefix(420)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    private func collapseBlankLines(in text: String) -> String {
        var lines: [String] = []
        var previousBlank = false

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let blank = line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if blank && previousBlank {
                continue
            }
            lines.append(line)
            previousBlank = blank
        }

        return lines.joined(separator: "\n")
    }

    private func extractAssistantTextSegments(from value: Any) -> [String] {
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [trimmed]
        }

        if let array = value as? [Any] {
            return array.flatMap { extractAssistantTextSegments(from: $0) }
        }

        if let dictionary = value as? [String: Any] {
            var values: [String] = []

            if let text = dictionary["text"] as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    values.append(trimmed)
                }
            }
            if let delta = dictionary["delta"] as? String {
                let trimmed = delta.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    values.append(trimmed)
                }
            }
            if let content = dictionary["content"] {
                values += extractAssistantTextSegments(from: content)
            }
            if let output = dictionary["output"] {
                values += extractAssistantTextSegments(from: output)
            }
            if let message = dictionary["message"] as? String {
                let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    values.append(trimmed)
                }
            }
            return values
        }

        return []
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
        VStack(spacing: 0) {
            topMenuBar
            Divider()
            HStack(spacing: 0) {
                controlPanel
                    .frame(width: 360)
                    .background(Color(nsColor: .windowBackgroundColor))
                Divider()
                conversationPanel
            }
        }
    }

    private var topMenuBar: some View {
        HStack(spacing: 10) {
            Menu {
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
            } label: {
                Label("Project", systemImage: "folder")
            }

            Button(viewModel.showGitSetup ? "Hide Git Setup" : "Setup Git") {
                viewModel.showGitSetup.toggle()
            }

            Button(viewModel.showPowerUserPanel ? "Hide Power User" : "Power User") {
                viewModel.showPowerUserPanel.toggle()
            }

            Spacer()

            Text("Model")
                .font(.caption)
                .foregroundColor(.secondary)

            Picker("Model", selection: $viewModel.selectedModel) {
                ForEach(viewModel.availableModels, id: \.self) { model in
                    Text(model).tag(model)
                }
            }
            .labelsHidden()
            .frame(width: 180)

            Picker("Reasoning", selection: $viewModel.selectedReasoningEffort) {
                ForEach(viewModel.availableReasoningEfforts, id: \.self) { effort in
                    Text(viewModel.reasoningDisplayName(for: effort)).tag(effort)
                }
            }
            .labelsHidden()
            .frame(width: 130)

            Text(viewModel.codexCliVersion)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .textSelection(.enabled)
                .frame(maxWidth: 220, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .onChange(of: viewModel.selectedModel) { _ in
            viewModel.modelSelectionDidChange()
        }
        .onChange(of: viewModel.selectedReasoningEffort) { _ in
            viewModel.reasoningSelectionDidChange()
        }
    }

    private var controlPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Workspace")
                        .font(.headline)
                    Text(viewModel.projectPath.isEmpty ? "No folder selected" : viewModel.projectPath)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                    Text("Session: \(viewModel.codexSessionState)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("Current: \(viewModel.currentModelSummary)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    DisclosureGroup(isExpanded: $viewModel.showChangesAccordion) {
                        VStack(alignment: .leading, spacing: 10) {
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
                                .frame(minHeight: 90, maxHeight: 130)
                                .padding(8)
                                .background(Color(nsColor: .controlBackgroundColor))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }

                            if !viewModel.latestDiffLines.isEmpty {
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 6) {
                                        ForEach(viewModel.latestDiffLines) { line in
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
                                .frame(minHeight: 90, maxHeight: 170)
                                .padding(8)
                                .background(Color(nsColor: .controlBackgroundColor))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    } label: {
                        HStack {
                            Text("Changes (Last Run)")
                                .font(.headline)
                            Spacer()
                            Text("+\(viewModel.latestDiffAdded)")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.green)
                            Text("-\(viewModel.latestDiffRemoved)")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.red)
                        }
                    }
                }

                if viewModel.showGitSetup {
                    Divider()

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Git Setup")
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
                }

                if viewModel.showPowerUserPanel {
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Power User")
                            .font(.headline)
                        TextField("Codex Path (optional override)", text: $viewModel.codexPathOverride)
                            .textFieldStyle(.roundedBorder)
                            .disabled(viewModel.isBusy)

                        Text("Command Log")
                            .font(.subheadline.weight(.semibold))
                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(viewModel.commandLog.enumerated()), id: \.offset) { _, line in
                                    Text(line)
                                        .font(.caption2)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .frame(minHeight: 130, maxHeight: 190)
                        .padding(8)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                        Text("Live Activity")
                            .font(.subheadline.weight(.semibold))
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
                        .frame(minHeight: 130, maxHeight: 190)
                        .padding(8)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .padding(16)
        }
    }

    private var sendDisabled: Bool {
        viewModel.projectPath.isEmpty ||
            viewModel.isBusy ||
            viewModel.draftPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var inlineStatusText: String {
        if viewModel.isBusy {
            return viewModel.thinkingStatus.isEmpty ? viewModel.busyLabel : viewModel.thinkingStatus
        }
        if !viewModel.projectPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Session: \(viewModel.codexSessionState) | Model: \(viewModel.currentModelSummary)"
        }
        return "Select a project folder to start Codex."
    }

    private var conversationPanel: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Conversation")
                    .font(.title3.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)

            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(viewModel.messages) { message in
                            MessageBubble(message: message)
                        }
                    }
                    .padding(16)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack(spacing: 10) {
                    HStack(spacing: 8) {
                        if viewModel.isBusy {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(inlineStatusText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    HStack(alignment: .bottom, spacing: 12) {
                        TextField(
                            "Ask Codex to edit files, run commands, or implement features...",
                            text: $viewModel.draftPrompt,
                            axis: .vertical
                        )
                        .textFieldStyle(.plain)
                        .lineLimit(6...14)
                        .frame(minHeight: 110, alignment: .topLeading)
                        .padding(10)
                        .background(Color(nsColor: .windowBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .disabled(viewModel.isBusy)
                        .onSubmit {
                            viewModel.sendPrompt()
                        }

                        Button {
                            viewModel.sendPrompt()
                        } label: {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 32))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(sendDisabled ? .gray : .accentColor)
                        .disabled(sendDisabled)
                    }
                }
                .padding(12)
                .background(Color(nsColor: .controlBackgroundColor))
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    @State private var expanded = false

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
            Text(displayContent)
                .font(.body)
                .textSelection(.enabled)
                .lineLimit(shouldCollapse ? 2 : nil)
                .frame(maxWidth: .infinity, alignment: .leading)

            if canCollapse {
                Button(expanded ? "Show less" : "Show details") {
                    expanded.toggle()
                }
                .buttonStyle(.plain)
                .font(.caption2.weight(.semibold))
                .foregroundColor(.secondary)
            }
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

    private var canCollapse: Bool {
        message.role == .system &&
            message.content.split(separator: "\n", omittingEmptySubsequences: false).count > 2
    }

    private var shouldCollapse: Bool {
        canCollapse && !expanded
    }

    private var displayContent: String {
        guard shouldCollapse else { return message.content }
        let collapsed = message.content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(2)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? message.content : collapsed
    }
}
