import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@main
struct CodexIntelApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 1100, minHeight: 700)
        }
    }
}

enum MessageRole: String, Codable {
    case user = "User"
    case assistant = "Codex"
    case system = "System"
}

struct ChatMessage: Identifiable, Codable {
    let id: UUID
    let role: MessageRole
    let content: String
    let timestamp: Date

    init(
        id: UUID = UUID(),
        role: MessageRole,
        content: String,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
    }
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
    let lineNumber: Int?
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

enum ValidationOutcome {
    case passed(String)
    case failed(String)
    case skipped(String)

    var summaryLine: String {
        switch self {
        case .passed(let text), .failed(let text), .skipped(let text):
            return text
        }
    }
}

struct ValidationPlan {
    let label: String
    let command: String
    let successMessage: String
}

struct GitRunSnapshot {
    let isGitWorkspace: Bool
    let startHeadCommit: String?
}

enum AutoPushOutcome {
    case pushed(commitShortSHA: String?, remoteDisplay: String, branch: String)
    case failed(String)
    case skipped(String)

    var summaryLines: [String] {
        switch self {
        case .pushed(let commitShortSHA, let remoteDisplay, let branch):
            var lines: [String] = []
            if let commitShortSHA, !commitShortSHA.isEmpty {
                lines.append("Commit \(commitShortSHA)")
            }
            lines.append("\(branch) updated on \(remoteDisplay)")
            return lines
        case .failed(let text):
            return [text]
        case .skipped(let text):
            return [text]
        }
    }
}

struct ShellRunner {
    private static let processLock = NSLock()
    private static var activeProcesses: [ObjectIdentifier: Process] = [:]

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

    func stopActiveProcesses() {
        ShellRunner.processLock.lock()
        let processes = Array(ShellRunner.activeProcesses.values)
        ShellRunner.processLock.unlock()

        for process in processes where process.isRunning {
            process.terminate()
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
        track(process)
        process.waitUntilExit()
        untrack(process)

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
        track(process)
        process.waitUntilExit()
        untrack(process)

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

    private static func track(_ process: Process) {
        processLock.lock()
        activeProcesses[ObjectIdentifier(process)] = process
        processLock.unlock()
    }

    private static func untrack(_ process: Process) {
        processLock.lock()
        activeProcesses.removeValue(forKey: ObjectIdentifier(process))
        processLock.unlock()
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
    @Published var codexAccountStatus = "Checking..."
    @Published var codexSessionState = "Not started"
    @Published var recentProjects: [String] = []
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
    ] {
        didSet {
            persistConversationHistoryIfNeeded()
        }
    }
    @Published var commandLog: [String] = []
    @Published var isBusy = false
    @Published var busyLabel = ""
    @Published var thinkingStatus = ""
    @Published var liveActivity: [String] = []
    @Published var thinkingHighlights: [String] = []
    @Published var latestDiffAdded = 0
    @Published var latestDiffRemoved = 0
    @Published var latestDiffFiles: [DiffFileStat] = []
    @Published var latestDiffLines: [DiffLine] = []

    private let runner = ShellRunner()
    private var resolvedCodexExecutable: String?
    private var didAttemptAutoInstallCodex = false
    private let missingBrewMarker = "__BREW_MISSING__"
    private let missingValidatorRuntimeMarker = "__VALIDATOR_RUNTIME_MISSING__"
    private var activeSessionID: String?
    private var sessionBootInProgress = false
    private var modelEffortsBySlug: [String: [String]] = [:]
    private var currentRunAssistantDeltas = ""
    private var currentRunAssistantCompletions: [String] = []
    private var detectedStaleSessionErrorInCurrentRun = false
    private var stopRequested = false
    private var didReportStopForCurrentRun = false
    private var fallbackChangedFiles: [String] = []
    private var preRunTextSnapshots: [String: String] = [:]
    private var loginFlowOpenedBrowser = false
    private var loginFlowSawDeviceCodePrompt = false
    private var loginFlowNeedsDeviceAuthEnablement = false
    private var loginFlowOpenedSecuritySettings = false
    private var runHeartbeatTask: Task<Void, Never>?
    private var runStartedAt: Date?
    private var lastProgressAt: Date?
    private let genericDoneFallback = "Completed. I applied updates to your project and summarized the result."
    private let recentProjectsDefaultsKey = "CodexIntelAppRecentProjects"
    private let maxRecentProjectsCount = 12
    private let maxPersistedConversationMessages = 400
    private let codexSecuritySettingsURL = "https://chatgpt.com/#settings/Security"
    private var suppressConversationPersistence = false

    init() {
        loadRecentProjects()
        applyModelDefaultsFromConfig()
        loadModelCatalogFromCache()
        updateReasoningOptionsForSelectedModel()
        Task {
            await refreshCodexVersion()
            await refreshCodexAccountStatus()
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
            activateProject(url.path, installDependencies: true)
        }
    }

    func selectRecentProject(_ path: String) {
        let value = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }

        var isDirectory = ObjCBool(false)
        if FileManager.default.fileExists(atPath: value, isDirectory: &isDirectory), isDirectory.boolValue {
            activateProject(value, installDependencies: false)
            return
        }

        recentProjects.removeAll { $0 == value }
        saveRecentProjects()
        messages.append(ChatMessage(role: .system, content: "Recent project path is no longer available: \(value)"))
    }

    private func activateProject(_ path: String, installDependencies: Bool) {
        projectPath = path
        addRecentProject(path)
        loadConversationHistory(for: path)
        resetSession(reason: nil)
        log("Selected project: \(projectPath)")
        Task {
            await ensureProjectDirectoryTrustAndAccess()
            if installDependencies {
                await runDependencyInstaller(autoTriggered: true)
            }
            await refreshCodexVersion()
            await refreshCodexAccountStatus()
            do {
                let codexExecutable = try await ensureCodexExecutableAvailable()
                await startPersistentAutonomousSessionIfNeeded(executablePath: codexExecutable)
            } catch {
                log("Unable to start persistent session after folder select: \(error.localizedDescription)")
            }
        }
    }

    private func loadRecentProjects() {
        let stored = UserDefaults.standard.stringArray(forKey: recentProjectsDefaultsKey) ?? []
        recentProjects = stored.filter { candidate in
            var isDirectory = ObjCBool(false)
            return FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        if recentProjects.count != stored.count {
            saveRecentProjects()
        }
    }

    private func saveRecentProjects() {
        UserDefaults.standard.set(recentProjects, forKey: recentProjectsDefaultsKey)
    }

    private func addRecentProject(_ path: String) {
        let value = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        var updated = recentProjects.filter { $0 != value }
        updated.insert(value, at: 0)
        if updated.count > maxRecentProjectsCount {
            updated = Array(updated.prefix(maxRecentProjectsCount))
        }
        recentProjects = updated
        saveRecentProjects()
    }

    private func loadConversationHistory(for project: String) {
        let value = project.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            replaceConversationMessages(with: [
                ChatMessage(
                    role: .system,
                    content: "Select a project folder, then send prompts. Codex runs in autonomous edit mode in that directory."
                )
            ])
            return
        }

        guard let url = conversationFileURL(for: value, createDirectory: false) else {
            replaceConversationMessages(with: [
                ChatMessage(
                    role: .system,
                    content: "Select a project folder, then send prompts. Codex runs in autonomous edit mode in that directory."
                )
            ])
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            replaceConversationMessages(with: [
                ChatMessage(
                    role: .system,
                    content: "Project loaded. Start chatting to create project-specific history."
                )
            ])
            return
        }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode([ChatMessage].self, from: data)
            if decoded.isEmpty {
                replaceConversationMessages(with: [
                    ChatMessage(
                        role: .system,
                        content: "Project loaded. Start chatting to create project-specific history."
                    )
                ])
            } else {
                replaceConversationMessages(with: decoded)
            }
            log("Loaded conversation history for project.")
        } catch {
            replaceConversationMessages(with: [
                ChatMessage(
                    role: .system,
                    content: "Project loaded. Start chatting to create project-specific history."
                )
            ])
            log("Unable to load conversation history: \(error.localizedDescription)")
        }
    }

    private func replaceConversationMessages(with newMessages: [ChatMessage]) {
        suppressConversationPersistence = true
        messages = newMessages
        suppressConversationPersistence = false
    }

    private func persistConversationHistoryIfNeeded() {
        guard !suppressConversationPersistence else { return }
        let project = projectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !project.isEmpty else { return }
        guard let url = conversationFileURL(for: project, createDirectory: true) else { return }

        do {
            let trimmed = Array(messages.suffix(maxPersistedConversationMessages))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(trimmed)
            try data.write(to: url, options: [.atomic])
        } catch {
            log("Unable to persist conversation history: \(error.localizedDescription)")
        }
    }

    private func conversationFileURL(for project: String, createDirectory: Bool) -> URL? {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        let directory = base
            .appendingPathComponent("CodexIntelApp", isDirectory: true)
            .appendingPathComponent("Conversations", isDirectory: true)

        if createDirectory {
            do {
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                log("Unable to create conversation history directory: \(error.localizedDescription)")
                return nil
            }
        }

        let fileName = safeConversationFileName(for: project)
        return directory.appendingPathComponent(fileName, isDirectory: false)
    }

    private func safeConversationFileName(for project: String) -> String {
        let encoded = Data(project.utf8).base64EncodedString()
        let safe = encoded
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return "\(safe).json"
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

    func stopActiveRun() {
        guard isBusy else { return }
        stopRequested = true
        thinkingStatus = "Stopping..."
        appendActivity("Stop requested by user.")
        runner.stopActiveProcesses()
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

    func connectChatGPTAccount() {
        Task {
            await runInAppBrowserLoginFlow()
        }
    }

    func refreshAccountStatus() {
        Task {
            await refreshCodexAccountStatus()
        }
    }

    func exportPowerUserLog() {
        let savePanel = NSSavePanel()
        savePanel.title = "Export Log"
        savePanel.canCreateDirectories = true
        savePanel.isExtensionHidden = false
        savePanel.allowedContentTypes = [.plainText]
        savePanel.nameFieldStringValue = "codexintel-log-\(timestampForFilename()).txt"

        guard savePanel.runModal() == .OK, let url = savePanel.url else { return }

        let content = powerUserLogExportText()
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            log("Exported power user log to \(url.path)")
            appendActivity("Exported log file.")
        } catch {
            log("Failed to export log: \(error.localizedDescription)")
            messages.append(ChatMessage(role: .system, content: "Log export failed: \(error.localizedDescription)"))
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
        stopRequested = false
        let runStartedAt = Date()
        beginRunHeartbeat(startedAt: runStartedAt)
        defer { stopRunHeartbeat() }

        do {
            try validateProjectAndTemplate(prompt: userPrompt)
            let gitSnapshot = await captureGitRunSnapshot()
            capturePreRunTextSnapshots()
            let codexExecutable = try await ensureCodexExecutableAvailable()
            await ensureProjectDirectoryTrustAndAccess()
            if finalizeStopIfNeeded() { return }
            await startPersistentAutonomousSessionIfNeeded(executablePath: codexExecutable)
            if finalizeStopIfNeeded() { return }

            resetAssistantCapture()
            let prompt = buildPromptWithHistory(newPrompt: userPrompt)
            thinkingStatus = "Analyzing your request..."
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
            if finalizeStopIfNeeded() { return }

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
                if finalizeStopIfNeeded() { return }
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
            let responseSummary = conversationSafePlainEnglish(rawResponse)
            appendActivity("Codex response complete")
            thinkingStatus = ""
            await refreshChangeSummary()
            if latestDiffFiles.isEmpty || !hasMeaningfulDiffStats() {
                let restored = await refreshChangeSummaryFromCommittedRange(snapshot: gitSnapshot)
                if !restored {
                    captureFilesystemChangeFallback(since: runStartedAt)
                }
            }
            await enrichFallbackChangeSummaryDetailsIfNeeded()
            if finalizeStopIfNeeded() { return }
            let doneSummary = resolvedDoneSummary(responseSummary)
            let validation = await runAutomaticValidationIfPossible()
            if finalizeStopIfNeeded() { return }
            let pushOutcome = await autoCommitAndPushAfterChat()
            if finalizeStopIfNeeded() { return }
            let summary = buildPostRunSummary(
                doneSummary: doneSummary,
                duration: Date().timeIntervalSince(runStartedAt),
                validation: validation,
                push: pushOutcome
            )
            messages.append(ChatMessage(role: .assistant, content: summary))
        } catch {
            if finalizeStopIfNeeded() { return }
            let text = error.localizedDescription
            messages.append(ChatMessage(role: .assistant, content: conversationSafePlainEnglish("Error: \(text)")))
            log("Error: \(text)")
            appendActivity("Error: \(text)")
            thinkingStatus = ""
            _ = await autoCommitAndPushAfterChat()
        }
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

    private func refreshCodexAccountStatus() async {
        let command = """
        if ! command -v codex >/dev/null 2>&1; then
          echo "__CODEX_NOT_FOUND__"
          exit 0
        fi
        codex login status 2>/dev/null || codex auth login status 2>/dev/null || codex whoami 2>/dev/null || true
        """

        guard let output = try? await runner.run(command: command, workingDirectory: nil) else {
            codexAccountStatus = "Unavailable"
            return
        }
        codexAccountStatus = parseCodexAccountStatus(stdout: output.stdout, stderr: output.stderr)
    }

    private func parseCodexAccountStatus(stdout: String, stderr: String) -> String {
        let combined = stripANSIEscapeCodes(from: stdout + "\n" + stderr)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if combined.contains("__CODEX_NOT_FOUND__") {
            return "CLI not found"
        }

        let rawLines = combined
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let lines = rawLines.filter { !isIgnorableAccountStatusLine($0) }
        let searchable = lines.isEmpty ? rawLines : lines

        let lowered = searchable.joined(separator: "\n").lowercased()
        if lowered.contains("not logged")
            || lowered.contains("not connected")
            || lowered.contains("unauthorized")
            || lowered.contains("sign in")
            || lowered.contains("log in")
            || lowered.contains("login required")
        {
            return "Not connected"
        }

        if let connectedLine = searchable.first(where: { isConnectedAccountStatusLine($0) }) {
            return truncateStatusLine(connectedLine)
        }

        if let first = searchable.first {
            return truncateStatusLine(first)
        }
        return "Unknown"
    }

    private func runInAppBrowserLoginFlow() async {
        do {
            let codexExecutable = try await ensureCodexExecutableAvailable()
            codexAccountStatus = "Connecting..."
            loginFlowOpenedBrowser = false
            loginFlowSawDeviceCodePrompt = false
            loginFlowNeedsDeviceAuthEnablement = false
            loginFlowOpenedSecuritySettings = false
            appendActivity("Starting browser login flow.")

            let output = try await executeBusyExecutableStreaming(
                label: "Connect ChatGPT Account",
                executablePath: codexExecutable,
                arguments: ["login", "--device-auth"],
                workingDirectory: nil
            ) { [weak self] source, line in
                Task { @MainActor in
                    self?.handleLoginStreamLine(source: source, line: line)
                }
            }

            if loginFlowNeedsDeviceAuthEnablement || indicatesDeviceAuthEnablementRequired(output.stdout + "\n" + output.stderr) {
                loginFlowNeedsDeviceAuthEnablement = true
                openSecuritySettingsForDeviceAuthIfNeeded(sourceLine: output.stdout + "\n" + output.stderr)
                codexAccountStatus = "Enable device auth in ChatGPT Security Settings"
                messages.append(
                    ChatMessage(
                        role: .system,
                        content: "Device code authorization for Codex is disabled. I opened ChatGPT Security Settings. Enable device code authorization, then click Connect ChatGPT Account again."
                    )
                )
                return
            }

            let waitSeconds = (loginFlowOpenedBrowser || loginFlowSawDeviceCodePrompt) ? 75 : 20
            let connected = await waitForAccountConnection(maxWaitSeconds: waitSeconds, pollIntervalSeconds: 3)
            if connected {
                appendActivity("ChatGPT account connected.")
                messages.append(ChatMessage(role: .system, content: "ChatGPT account connected."))
            } else {
                let details = sanitizedLoginFailureDetails(preferredFailureText(output) + "\n" + codexAccountStatus)
                messages.append(ChatMessage(role: .system, content: "Login ended before connection was confirmed. \(details)"))
            }
        } catch {
            await refreshCodexAccountStatus()
            messages.append(ChatMessage(role: .system, content: "Unable to start browser login flow: \(error.localizedDescription)"))
        }
    }

    private func handleLoginStreamLine(source: StreamSource, line: String) {
        let trimmed = stripANSIEscapeCodes(from: line).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if indicatesDeviceAuthEnablementRequired(trimmed) {
            loginFlowNeedsDeviceAuthEnablement = true
            codexAccountStatus = "Enable device auth in ChatGPT Security Settings"
            openSecuritySettingsForDeviceAuthIfNeeded(sourceLine: trimmed)
            appendActivity("Device code authorization is disabled in ChatGPT Security Settings.")
            return
        }

        if let url = firstURL(in: trimmed), !loginFlowOpenedBrowser {
            openBrowserForLogin(url)
            return
        }

        let lowered = trimmed.lowercased()
        if lowered.contains("never share this code") || lowered.contains("device code") || lowered.contains("enter code") {
            loginFlowSawDeviceCodePrompt = true
            openCanonicalDeviceAuthURLIfNeeded()
            appendActivity("Waiting for code confirmation in browser...")
            return
        }
        if lowered.contains("waiting") || lowered.contains("authorize") || lowered.contains("browser") {
            openCanonicalDeviceAuthURLIfNeeded()
            appendActivity("Waiting for browser sign-in...")
            return
        }

        if source == .stderr, (lowered.contains("error") || lowered.contains("failed")) {
            appendActivity(trimmed)
        }
    }

    private func firstURL(in text: String) -> URL? {
        let pattern = #"https?://[^\s\)\]\"]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }
        guard let matchRange = Range(match.range, in: text) else { return nil }
        let raw = String(text[matchRange])
        let cleaned = sanitizeCapturedURLString(raw)
        guard !cleaned.isEmpty else { return nil }
        return canonicalizedLoginURL(from: cleaned) ?? URL(string: cleaned)
    }

    private func sanitizeCapturedURLString(_ raw: String) -> String {
        var candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let encodedAnsiRange = candidate.range(of: "%1B%5B", options: [.caseInsensitive]) {
            candidate = String(candidate[..<encodedAnsiRange.lowerBound])
        }
        candidate = stripANSIEscapeCodes(from: candidate)
        candidate = candidate.replacingOccurrences(
            of: #"(?i)%1b%5b[0-9;]*[a-z]"#,
            with: "",
            options: .regularExpression
        )
        candidate = candidate.replacingOccurrences(
            of: #"(?i)\\u001b\[[0-9;]*[a-z]"#,
            with: "",
            options: .regularExpression
        )
        candidate = candidate.replacingOccurrences(of: "\u{001B}", with: "")
        candidate = candidate.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
        return candidate
    }

    private func canonicalizedLoginURL(from raw: String) -> URL? {
        guard var components = URLComponents(string: raw) else { return nil }
        let host = components.host?.lowercased() ?? ""
        let path = components.path.lowercased()
        guard host == "auth.openai.com", path.hasPrefix("/codex/device") else {
            return nil
        }

        // Normalize malformed device-auth URLs (e.g. ANSI fragments) to a stable endpoint.
        components.scheme = "https"
        components.host = "auth.openai.com"
        components.path = "/codex/device"
        return components.url
    }

    private func openCanonicalDeviceAuthURLIfNeeded() {
        guard !loginFlowOpenedBrowser else { return }
        guard let url = URL(string: "https://auth.openai.com/codex/device") else { return }
        openBrowserForLogin(url)
    }

    private func openSecuritySettingsForDeviceAuthIfNeeded(sourceLine: String? = nil) {
        guard !loginFlowOpenedSecuritySettings else { return }
        let candidate = sourceLine.flatMap { firstURL(in: $0) }
        let fallback = URL(string: codexSecuritySettingsURL)
        guard let url = candidate ?? fallback else { return }

        loginFlowOpenedSecuritySettings = true
        NSWorkspace.shared.open(url)
        appendActivity("Opened ChatGPT Security Settings.")
    }

    private func openBrowserForLogin(_ url: URL) {
        loginFlowOpenedBrowser = true
        NSWorkspace.shared.open(url)
        codexAccountStatus = "Waiting for browser sign-in..."
        appendActivity("Opened browser sign-in page.")
    }

    private func indicatesDeviceAuthEnablementRequired(_ text: String) -> Bool {
        let lowered = stripANSIEscapeCodes(from: text).lowercased()
        if lowered.contains("enable device code authorization") {
            return true
        }
        if lowered.contains("device code") && lowered.contains("security settings") {
            return true
        }
        return false
    }

    private func isConnectedAccountStatus(_ status: String) -> Bool {
        let lowered = status.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lowered.isEmpty { return false }
        if lowered.contains("not connected") || lowered.contains("cli not found") {
            return false
        }
        if lowered == "checking..." || lowered == "unavailable" || lowered == "unknown" || lowered.contains("connecting") {
            return false
        }
        if lowered.contains("logged in") || lowered.contains("connected") || lowered.contains("api key") {
            return true
        }
        return false
    }

    private func waitForAccountConnection(maxWaitSeconds: Int, pollIntervalSeconds: UInt64) async -> Bool {
        if loginFlowNeedsDeviceAuthEnablement {
            return false
        }
        let wait = max(3, maxWaitSeconds)
        let interval = max(1, Int(pollIntervalSeconds))
        let attempts = max(1, wait / interval)

        for attempt in 0...attempts {
            if loginFlowNeedsDeviceAuthEnablement {
                return false
            }
            await refreshCodexAccountStatus()
            if isConnectedAccountStatus(codexAccountStatus) {
                return true
            }
            if attempt < attempts {
                codexAccountStatus = "Waiting for browser sign-in..."
                try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
            }
        }
        return false
    }

    private func sanitizedLoginFailureDetails(_ raw: String) -> String {
        let clean = stripANSIEscapeCodes(from: raw).trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = clean.lowercased()
        if indicatesDeviceAuthEnablementRequired(clean) {
            return "Enable device code authorization for Codex in ChatGPT Security Settings, then click Connect ChatGPT Account again."
        }
        if lowered.contains("not connected") || lowered.contains("not logged") || lowered.contains("login required") {
            return "Browser login did not complete. Please finish sign-in in the browser window and try again."
        }
        if lowered.contains("never share this code") || lowered.contains("device code") {
            return "Browser login started, but the app could not confirm completion yet."
        }
        if clean.isEmpty || clean == "(No error details)" {
            return "Please finish sign-in in the browser, then click Refresh Account Status."
        }
        return conversationSafePlainEnglish(clean)
    }

    private func isIgnorableAccountStatusLine(_ line: String) -> Bool {
        let lowered = line.lowercased()
        if lowered.hasPrefix("warning:") || lowered.hasPrefix("tip:") {
            return true
        }
        if lowered.hasPrefix("usage:") || lowered.hasPrefix("for more information") {
            return true
        }
        return false
    }

    private func isConnectedAccountStatusLine(_ line: String) -> Bool {
        let lowered = line.lowercased()
        return lowered.contains("logged in") || lowered.contains("connected") || lowered.contains("api key")
    }

    private func truncateStatusLine(_ line: String, maxLength: Int = 80) -> String {
        if line.count <= maxLength {
            return line
        }
        return String(line.prefix(maxLength)) + "..."
    }

    private func stripANSIEscapeCodes(from text: String) -> String {
        var value = text.replacingOccurrences(
            of: #"\u{001B}\[[0-9;]*[A-Za-z]"#,
            with: "",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"\u{001B}\][^\u{0007}\u{001B}]*(?:\u{0007}|\u{001B}\\)"#,
            with: "",
            options: .regularExpression
        )
        return value
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

    private func autoCommitAndPushAfterChat() async -> AutoPushOutcome {
        guard isGitConfigured else {
            return .skipped("Git not configured.")
        }
        let project = projectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !project.isEmpty else {
            return .skipped("No project folder selected for git push.")
        }
        guard let target = configuredGitTarget() else {
            return .skipped("Git remote/branch not configured.")
        }

        let commit = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Update via CodexIntelApp"
            : commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = "git add -A && (git diff --cached --quiet || git commit -m \(shellQuote(commit))) && git push -u \(shellQuote(target.remote)) \(shellQuote(target.branch))"

        do {
            let output = try await executeBusyCommand(label: "Auto commit + push", command: command)
            if output.exitCode != 0 {
                let details = cleanOutput(output.stdout, fallback: output.stderr)
                log("Auto push failed with code \(output.exitCode): \(details)")
                return .failed("Auto push failed (\(output.exitCode)): \(conversationSafePlainEnglish(details))")
            }

            let commitShortSHA = await currentShortCommitSHA()
            let remoteDisplay = await resolveRemoteDisplayName(remote: target.remote)
            log("Auto push completed for \(target.remote)/\(target.branch).")
            return .pushed(commitShortSHA: commitShortSHA, remoteDisplay: remoteDisplay, branch: target.branch)
        } catch {
            log("Auto push error: \(error.localizedDescription)")
            return .failed("Auto push error: \(conversationSafePlainEnglish(error.localizedDescription))")
        }
    }

    private func runAutomaticValidationIfPossible() async -> ValidationOutcome {
        let project = projectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !project.isEmpty else {
            return .skipped("Validation skipped: no project folder selected.")
        }

        guard let plan = selectValidationPlan(for: project) else {
            return .skipped("Validation skipped: no automatic validator configured for this project type.")
        }

        appendActivity("Running validation: \(plan.label)")
        do {
            let output = try await executeBusyCommand(label: "Validation: \(plan.label)", command: plan.command)
            if output.exitCode == 0 {
                appendActivity("Validation passed: \(plan.label)")
                return .passed(plan.successMessage)
            }
            if validatorRuntimeMissing(output) {
                appendActivity("Validation skipped: runtime unavailable for \(plan.label)")
                return .skipped("Validation skipped: required runtime for \(plan.label) is not installed.")
            }
            let details = conversationSafePlainEnglish(preferredFailureText(output))
            appendActivity("Validation failed: \(plan.label) (\(output.exitCode))")
            return .failed("\(plan.label) failed (\(output.exitCode)). \(details)")
        } catch {
            appendActivity("Validation error: \(error.localizedDescription)")
            return .failed("\(plan.label) failed to run: \(conversationSafePlainEnglish(error.localizedDescription))")
        }
    }

    private func selectValidationPlan(for project: String) -> ValidationPlan? {
        let root = URL(fileURLWithPath: project, isDirectory: true)
        let fileManager = FileManager.default

        let packageManifest = root.appendingPathComponent("Package.swift").path
        if fileManager.fileExists(atPath: packageManifest) {
            return ValidationPlan(
                label: "swift build",
                command: "swift build",
                successMessage: "swift build passed."
            )
        }

        let packageJSON = root.appendingPathComponent("package.json").path
        if fileManager.fileExists(atPath: packageJSON) {
            let scripts = npmScriptNames(from: packageJSON)
            if scripts.contains("lint") {
                return ValidationPlan(
                    label: "npm run lint",
                    command: "if command -v npm >/dev/null 2>&1; then npm run -s lint; else echo \"\(missingValidatorRuntimeMarker):npm\"; exit 86; fi",
                    successMessage: "npm run lint passed."
                )
            }
            if scripts.contains("typecheck") {
                return ValidationPlan(
                    label: "npm run typecheck",
                    command: "if command -v npm >/dev/null 2>&1; then npm run -s typecheck; else echo \"\(missingValidatorRuntimeMarker):npm\"; exit 86; fi",
                    successMessage: "npm run typecheck passed."
                )
            }
            if scripts.contains("check") {
                return ValidationPlan(
                    label: "npm run check",
                    command: "if command -v npm >/dev/null 2>&1; then npm run -s check; else echo \"\(missingValidatorRuntimeMarker):npm\"; exit 86; fi",
                    successMessage: "npm run check passed."
                )
            }
            if scripts.contains("build") {
                return ValidationPlan(
                    label: "npm run build",
                    command: "if command -v npm >/dev/null 2>&1; then npm run -s build; else echo \"\(missingValidatorRuntimeMarker):npm\"; exit 86; fi",
                    successMessage: "npm run build passed."
                )
            }
        }

        let pyproject = root.appendingPathComponent("pyproject.toml").path
        let requirements = root.appendingPathComponent("requirements.txt").path
        if fileManager.fileExists(atPath: pyproject) || fileManager.fileExists(atPath: requirements) {
            return ValidationPlan(
                label: "python compile check",
                command: "if command -v python3 >/dev/null 2>&1; then python3 -m compileall -q .; else echo \"\(missingValidatorRuntimeMarker):python3\"; exit 86; fi",
                successMessage: "python compile check passed."
            )
        }

        return nil
    }

    private func npmScriptNames(from packageJSONPath: String) -> Set<String> {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: packageJSONPath)) else {
            return []
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        if let scripts = object["scripts"] as? [String: String] {
            return Set(scripts.keys)
        }
        if let scripts = object["scripts"] as? [String: Any] {
            return Set(scripts.keys)
        }
        return []
    }

    private func validatorRuntimeMissing(_ output: CommandOutput) -> Bool {
        let combined = output.stdout + "\n" + output.stderr
        return combined.contains(missingValidatorRuntimeMarker)
    }

    private func buildPostRunSummary(
        doneSummary: String,
        duration: TimeInterval,
        validation: ValidationOutcome,
        push: AutoPushOutcome
    ) -> String {
        var lines: [String] = []
        lines.append("Worked for \(formattedElapsedDuration(duration))")
        lines.append("")
        lines.append("Done. \(doneSummary)")

        lines.append("")
        lines.append("Changes:")
        for value in changedFileReferenceLines(limit: 8) {
            lines.append("• \(value)")
        }

        let detailedChanges = detailedChangeReferenceLines(fileLimit: 4, lineLimit: 4)
        if !detailedChanges.isEmpty {
            lines.append("")
            lines.append("Detailed changes:")
            lines.append(contentsOf: detailedChanges)
        }

        lines.append("")
        lines.append("Validation:")
        lines.append("• \(validation.summaryLine)")

        lines.append("")
        lines.append("Pushed:")
        for line in push.summaryLines {
            lines.append("• \(line)")
        }
        return lines.joined(separator: "\n")
    }

    private func changedFileReferenceLines(limit: Int) -> [String] {
        guard !latestDiffFiles.isEmpty else {
            return fallbackChangedReferenceLines(limit: limit)
        }

        var firstLineByFile: [String: Int] = [:]
        for line in latestDiffLines {
            guard let lineNumber = line.lineNumber else { continue }
            if firstLineByFile[line.file] == nil {
                firstLineByFile[line.file] = lineNumber
            }
        }

        var values: [String] = []
        for file in latestDiffFiles.prefix(limit) {
            let compactPath = compactSummaryPath(file.path)
            let stats = diffStatText(added: file.added, removed: file.removed)
            if let line = firstLineByFile[file.path] {
                values.append("\(compactPath) (line \(line), \(stats))")
            } else {
                values.append("\(compactPath) (\(stats))")
            }
        }

        let remaining = latestDiffFiles.count - values.count
        if remaining > 0 {
            values.append("+\(remaining) more file(s)")
        }
        return values
    }

    private func detailedChangeReferenceLines(fileLimit: Int, lineLimit: Int) -> [String] {
        guard !latestDiffFiles.isEmpty else {
            return fallbackDetailedChangeReferenceLines(limit: fileLimit)
        }

        var values: [String] = []
        for file in latestDiffFiles.prefix(fileLimit) {
            let compactPath = compactSummaryPath(file.path)
            values.append("• \(compactPath) (\(diffStatText(added: file.added, removed: file.removed)))")

            let linePreview = latestDiffLines
                .filter { $0.file == file.path }
                .prefix(lineLimit)

            if linePreview.isEmpty {
                values.append("  line preview unavailable")
            } else {
                for line in linePreview {
                    values.append("  \(formattedDetailedDiffLine(line))")
                }
            }
        }

        let remaining = latestDiffFiles.count - values.filter { $0.hasPrefix("• ") }.count
        if remaining > 0 {
            values.append("• +\(remaining) more file(s)")
        }
        return values
    }

    private func fallbackChangedReferenceLines(limit: Int) -> [String] {
        guard !fallbackChangedFiles.isEmpty else {
            return ["No file edits were detected in this run."]
        }

        let listed = fallbackChangedFiles.prefix(limit).map { path in
            "\(compactSummaryPath(path)) (changed)"
        }
        var values = Array(listed)
        let remaining = fallbackChangedFiles.count - listed.count
        if remaining > 0 {
            values.append("+\(remaining) more file(s)")
        }
        return values
    }

    private func fallbackDetailedChangeReferenceLines(limit: Int) -> [String] {
        guard !fallbackChangedFiles.isEmpty else { return [] }
        var values = fallbackChangedFiles.prefix(limit).map { "• \(compactSummaryPath($0)) (changed)" }
        let remaining = fallbackChangedFiles.count - values.count
        if remaining > 0 {
            values.append("• +\(remaining) more file(s)")
        }
        return values
    }

    private func formattedDetailedDiffLine(_ line: DiffLine) -> String {
        let sign = line.kind == .added ? "+" : "-"
        let preview = summarizedDiffPreviewText(line.text)
        if let lineNumber = line.lineNumber {
            return "\(sign) L\(lineNumber): \(preview)"
        }
        return "\(sign): \(preview)"
    }

    private func summarizedDiffPreviewText(_ text: String, maxLength: Int = 120) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            return "(blank line)"
        }
        value = value.replacingOccurrences(of: "\t", with: " ")
        value = value.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        if value.count > maxLength {
            return String(value.prefix(maxLength)) + "..."
        }
        return value
    }

    private func resolvedDoneSummary(_ summary: String) -> String {
        let normalized = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let generated = generatedSummaryFromChanges()

        if normalized.isEmpty || normalized == genericDoneFallback {
            return generated
        }
        if doneSummaryNeedsMoreDetail(normalized) {
            return "\(normalized) \(generated)"
        }
        return normalized
    }

    private func generatedSummaryFromChanges() -> String {
        if latestDiffFiles.isEmpty {
            if fallbackChangedFiles.isEmpty {
                return "No file edits were detected in this run."
            }
            let count = fallbackChangedFiles.count
            let fileLabel = count == 1 ? "file" : "files"
            let topFileSummaries = fallbackChangedFiles.prefix(5).map { "\(compactSummaryPath($0)) (changed)" }
            var summary = "Updated \(count) \(fileLabel)"
            if !topFileSummaries.isEmpty {
                summary += ": \(topFileSummaries.joined(separator: ", "))"
            }
            if count > topFileSummaries.count {
                summary += "; +\(count - topFileSummaries.count) more file(s)"
            }
            return summary + "."
        }

        let fileCount = latestDiffFiles.count
        let fileLabel = fileCount == 1 ? "file" : "files"
        let topFileSummaries = latestDiffFiles.prefix(5).map { file in
            "\(compactSummaryPath(file.path)) (\(diffStatText(added: file.added, removed: file.removed)))"
        }

        var summary = "Updated \(fileCount) \(fileLabel)"
        if !topFileSummaries.isEmpty {
            summary += ": \(topFileSummaries.joined(separator: "; "))"
        }
        if fileCount > topFileSummaries.count {
            summary += "; +\(fileCount - topFileSummaries.count) more file(s)"
        }
        return summary + "."
    }

    private func doneSummaryNeedsMoreDetail(_ summary: String) -> Bool {
        let words = summary.split(whereSeparator: \.isWhitespace).count
        if words < 18 {
            return true
        }
        let lowered = summary.lowercased()
        if lowered.contains("file") || lowered.contains("files") || lowered.contains("changed") || lowered.contains("updated") {
            return false
        }
        return true
    }

    private func compactSummaryPath(_ path: String) -> String {
        let components = path.split(separator: "/").map(String.init)
        guard components.count > 3 else { return path }
        return components.suffix(3).joined(separator: "/")
    }

    private func diffStatText(added: Int, removed: Int) -> String {
        if added == 0 && removed == 0 {
            return "changed"
        }
        return "+\(added)/-\(removed)"
    }

    private func hasMeaningfulDiffStats() -> Bool {
        latestDiffFiles.contains { $0.added > 0 || $0.removed > 0 }
    }

    private func formattedElapsedDuration(_ duration: TimeInterval) -> String {
        let seconds = max(1, Int(duration.rounded()))
        let minutes = seconds / 60
        let remainder = seconds % 60
        if minutes == 0 {
            return "\(seconds)s"
        }
        if remainder == 0 {
            return "\(minutes)m"
        }
        return "\(minutes)m \(remainder)s"
    }

    private func currentShortCommitSHA() async -> String? {
        guard let output = try? await runner.run(
            command: "git rev-parse --short HEAD",
            workingDirectory: projectPath
        ) else { return nil }
        guard output.exitCode == 0 else { return nil }
        let value = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func resolveRemoteDisplayName(remote: String) async -> String {
        if remote.contains("://") || remote.contains("@") {
            return remote
        }
        guard let output = try? await runner.run(
            command: "git remote get-url \(shellQuote(remote))",
            workingDirectory: projectPath
        ) else { return remote }
        guard output.exitCode == 0 else { return remote }
        let value = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? remote : value
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
        stopRunHeartbeat()
        thinkingStatus = ""
        liveActivity.removeAll()
        thinkingHighlights.removeAll()
        latestDiffAdded = 0
        latestDiffRemoved = 0
        latestDiffFiles.removeAll()
        latestDiffLines.removeAll()
        fallbackChangedFiles.removeAll()
        preRunTextSnapshots.removeAll()
        showChangesAccordion = false
        detectedStaleSessionErrorInCurrentRun = false
        didReportStopForCurrentRun = false
    }

    private func finalizeStopIfNeeded() -> Bool {
        guard stopRequested else { return false }
        guard !didReportStopForCurrentRun else { return true }
        didReportStopForCurrentRun = true
        stopRequested = false
        thinkingStatus = ""
        appendActivity("Run stopped.")
        messages.append(ChatMessage(role: .assistant, content: "Stopped. I halted the current run and skipped remaining steps."))
        return true
    }

    private func appendActivity(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        liveActivity.append(trimmed)
        if liveActivity.count > 220 {
            liveActivity.removeFirst(liveActivity.count - 220)
        }
        updateThinkingProgress(from: trimmed)
    }

    private func beginRunHeartbeat(startedAt: Date) {
        stopRunHeartbeat()
        runStartedAt = startedAt
        lastProgressAt = startedAt
        runHeartbeatTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self.updateHeartbeatProgress()
            }
        }
    }

    private func stopRunHeartbeat() {
        runHeartbeatTask?.cancel()
        runHeartbeatTask = nil
        runStartedAt = nil
        lastProgressAt = nil
    }

    private func updateHeartbeatProgress() {
        guard isBusy else { return }
        guard let runStartedAt else { return }

        let now = Date()
        let elapsed = max(1, Int(now.timeIntervalSince(runStartedAt)))
        let idleFor = max(0, Int(now.timeIntervalSince(lastProgressAt ?? runStartedAt)))
        let base = statusWithoutElapsedSuffix(thinkingStatus.isEmpty ? busyLabel : thinkingStatus)
        let normalizedBase = base.isEmpty ? "Working..." : base
        let withElapsed = "\(normalizedBase) (\(elapsed)s)"
        if thinkingStatus != withElapsed {
            thinkingStatus = withElapsed
        }

        if idleFor >= 8, elapsed % 8 == 0 {
            let hint = heartbeatHint(idleFor: idleFor)
            if thinkingHighlights.last != hint {
                thinkingHighlights.append(hint)
                if thinkingHighlights.count > 12 {
                    thinkingHighlights.removeFirst(thinkingHighlights.count - 12)
                }
            }
        }
    }

    private func heartbeatHint(idleFor: Int) -> String {
        let base = statusWithoutElapsedSuffix(thinkingStatus).lowercased()
        if base.contains("retrying") || base.contains("stale session") {
            return "Still retrying session startup (\(idleFor)s without new output)."
        }
        if base.contains("running command") {
            return "Command is still running (\(idleFor)s without new output)."
        }
        if base.contains("validation") {
            return "Validation is still in progress (\(idleFor)s without new output)."
        }
        if base.contains("pushing") {
            return "Push is still in progress (\(idleFor)s without new output)."
        }
        return "Still working in the project (\(idleFor)s without new output)."
    }

    private func statusWithoutElapsedSuffix(_ value: String) -> String {
        value
            .replacingOccurrences(
                of: "\\s*\\([0-9]+s\\)$",
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func updateThinkingProgress(from rawValue: String) {
        guard isBusy else { return }
        guard let status = summarizedProgressLine(from: rawValue) else { return }
        thinkingStatus = status
        lastProgressAt = Date()

        if thinkingHighlights.last != status {
            thinkingHighlights.append(status)
            if thinkingHighlights.count > 10 {
                thinkingHighlights.removeFirst(thinkingHighlights.count - 10)
            }
        }
    }

    private func summarizedProgressLine(from rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lowered = trimmed.lowercased()
        if lowered == "thinking..." || lowered == "running autonomous codex turn" {
            return "Reviewing your request and planning edits..."
        }
        if lowered == "applying edits..." || lowered == "applying file changes." {
            return "Applying edits to files..."
        }
        if lowered == "codex response complete" {
            return "Preparing your summary..."
        }
        if lowered.contains("stale codex session") {
            return "Refreshing stale session and retrying..."
        }
        if lowered.hasPrefix("running validation:") {
            return trimmed
        }
        if lowered.hasPrefix("validation passed:") {
            return trimmed
        }
        if lowered.hasPrefix("validation failed:") {
            return trimmed
        }
        if lowered.contains("auto commit + push") || lowered.contains("auto push") {
            return "Pushing updates to git..."
        }

        if trimmed.hasPrefix("Running: ") {
            let command = String(trimmed.dropFirst("Running: ".count))
            return "Running command: \(compactProgressCommand(command))"
        }

        if trimmed.hasPrefix("Tool: ") {
            let tool = String(trimmed.dropFirst("Tool: ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !tool.isEmpty {
                return "Using tool: \(tool)"
            }
            return nil
        }

        if trimmed.hasPrefix("Error: ") {
            return "Handling an issue and retrying..."
        }

        if trimmed.hasPrefix("Changed lines:") {
            return "Collecting change summary..."
        }

        if trimmed.hasPrefix("Session ") {
            return trimmed
        }

        return nil
    }

    private func compactProgressCommand(_ command: String) -> String {
        let compact = command
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compact.isEmpty else { return "(command)" }
        if compact.count <= 72 {
            return compact
        }
        return String(compact.prefix(69)) + "..."
    }

    private func handleCodexStreamLine(source: StreamSource, line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard let event = parseCodexJSONEvent(from: trimmed) else {
            if source == .stderr {
                let staleState = isStaleSessionStateError(trimmed)
                if staleState {
                    detectedStaleSessionErrorInCurrentRun = true
                    appendActivity("Detected stale Codex session state.")
                    log("[codex] stale session state detected; retrying with a fresh session")
                } else {
                    log("[codex] \(trimmed)")
                }
                if !staleState && (trimmed.contains("WARN") || trimmed.contains("Error") || trimmed.contains("error")) {
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
            appendActivity("Reviewing request and planning edits.")
        case "turn.completed":
            appendActivity("Applying file changes.")
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
            return genericDoneFallback
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
            let hasHeadCommit = await currentGitHeadCommit() != nil
            let numstatText: String
            let patchText: String
            if hasHeadCommit {
                let numstatOutput = try await runner.run(
                    command: "git diff --numstat HEAD -- .",
                    workingDirectory: projectPath
                )
                let patchOutput = try await runner.run(
                    command: "git diff --no-color --unified=0 HEAD -- .",
                    workingDirectory: projectPath
                )
                numstatText = numstatOutput.stdout
                patchText = patchOutput.stdout
            } else {
                let unstagedNumstatOutput = try await runner.run(
                    command: "git diff --numstat -- .",
                    workingDirectory: projectPath
                )
                let stagedNumstatOutput = try await runner.run(
                    command: "git diff --numstat --cached -- .",
                    workingDirectory: projectPath
                )
                numstatText = unstagedNumstatOutput.stdout + "\n" + stagedNumstatOutput.stdout

                let unstagedPatchOutput = try await runner.run(
                    command: "git diff --no-color --unified=0 -- .",
                    workingDirectory: projectPath
                )
                let stagedPatchOutput = try await runner.run(
                    command: "git diff --no-color --unified=0 --cached -- .",
                    workingDirectory: projectPath
                )
                patchText = unstagedPatchOutput.stdout + "\n" + stagedPatchOutput.stdout
            }
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
            for file in parseNumstat(numstatText + "\n" + untrackedOutput.stdout) {
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
            latestDiffLines = parseDiffLines(patchText, limit: 200)

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

    private func captureFilesystemChangeFallback(since runStartedAt: Date) {
        let rootPath = projectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rootPath.isEmpty else {
            fallbackChangedFiles = []
            return
        }

        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsPackageDescendants, .skipsHiddenFiles]
        ) else {
            fallbackChangedFiles = []
            return
        }

        let threshold = runStartedAt.addingTimeInterval(-2)
        let excludedPrefixes = [
            ".git/",
            ".build/",
            "dist/",
            "node_modules/",
            ".swiftpm/",
            "DerivedData/",
            "Library/"
        ]

        var found: [String] = []
        while let fileURL = enumerator.nextObject() as? URL {
            guard let values = try? fileURL.resourceValues(forKeys: resourceKeys) else { continue }
            guard values.isRegularFile == true else { continue }
            guard let modifiedAt = values.contentModificationDate, modifiedAt >= threshold else { continue }

            var relativePath = fileURL.path
            if relativePath.hasPrefix(rootURL.path) {
                relativePath = String(relativePath.dropFirst(rootURL.path.count))
                if relativePath.hasPrefix("/") {
                    relativePath.removeFirst()
                }
            }
            guard !relativePath.isEmpty else { continue }
            guard !excludedPrefixes.contains(where: { relativePath.hasPrefix($0) }) else { continue }

            found.append(relativePath)
        }

        fallbackChangedFiles = Array(Set(found)).sorted()
        if !fallbackChangedFiles.isEmpty {
            appendActivity("Filesystem fallback detected \(fallbackChangedFiles.count) changed file(s).")
        }
    }

    private func capturePreRunTextSnapshots() {
        preRunTextSnapshots.removeAll()

        let rootPath = projectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rootPath.isEmpty else { return }

        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        let resourceKeys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileSizeKey
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsPackageDescendants, .skipsHiddenFiles]
        ) else {
            return
        }

        let excludedPrefixes = [
            ".git/",
            ".build/",
            "dist/",
            "node_modules/",
            ".swiftpm/",
            "DerivedData/",
            "Library/"
        ]

        var fileCount = 0
        var capturedBytes = 0
        let maxFiles = 500
        let maxTotalBytes = 18_000_000
        let maxFileBytes = 900_000

        while let fileURL = enumerator.nextObject() as? URL {
            guard fileCount < maxFiles else { break }
            guard capturedBytes < maxTotalBytes else { break }
            guard let values = try? fileURL.resourceValues(forKeys: resourceKeys) else { continue }
            guard values.isRegularFile == true else { continue }
            let size = values.fileSize ?? 0
            guard size > 0, size <= maxFileBytes else { continue }

            var relativePath = fileURL.path
            if relativePath.hasPrefix(rootURL.path) {
                relativePath = String(relativePath.dropFirst(rootURL.path.count))
                if relativePath.hasPrefix("/") {
                    relativePath.removeFirst()
                }
            }
            guard !relativePath.isEmpty else { continue }
            guard !excludedPrefixes.contains(where: { relativePath.hasPrefix($0) }) else { continue }

            guard let text = readFileTextLossy(at: fileURL) else { continue }

            preRunTextSnapshots[relativePath] = text
            fileCount += 1
            capturedBytes += size
        }
    }

    private func enrichFallbackChangeSummaryDetailsIfNeeded() async {
        guard !fallbackChangedFiles.isEmpty else { return }
        if hasMeaningfulDiffStats(), !latestDiffLines.isEmpty {
            return
        }

        let maxFiles = 6
        var derivedStats: [String: (added: Int, removed: Int)] = [:]
        var derivedLines: [DiffLine] = []

        for path in fallbackChangedFiles.prefix(maxFiles) {
            guard let value = await deriveFallbackDiff(for: path) else { continue }
            if value.added > 0 || value.removed > 0 || !value.lines.isEmpty {
                derivedStats[path] = (value.added, value.removed)
            }
            if !value.lines.isEmpty, derivedLines.count < 220 {
                let remaining = max(0, 220 - derivedLines.count)
                derivedLines.append(contentsOf: value.lines.prefix(remaining))
            }
        }

        guard !derivedStats.isEmpty else { return }

        let combined = fallbackChangedFiles.map { path in
            let stats = derivedStats[path] ?? (0, 0)
            return DiffFileStat(path: path, added: stats.added, removed: stats.removed)
        }

        latestDiffFiles = combined
        latestDiffAdded = combined.reduce(0) { $0 + $1.added }
        latestDiffRemoved = combined.reduce(0) { $0 + $1.removed }
        if !derivedLines.isEmpty {
            latestDiffLines = derivedLines
        }
        appendActivity("Derived line-level fallback changes for \(derivedStats.count) file(s).")
    }

    private func deriveFallbackDiff(for relativePath: String) async -> (added: Int, removed: Int, lines: [DiffLine])? {
        let rootPath = projectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rootPath.isEmpty else { return nil }

        let beforeText = preRunTextSnapshots[relativePath] ?? ""
        let fileURL = URL(fileURLWithPath: rootPath, isDirectory: true).appendingPathComponent(relativePath)
        let afterText = readFileTextLossy(at: fileURL) ?? ""

        if beforeText == afterText {
            return nil
        }

        let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let oldURL = temporaryDirectory.appendingPathComponent("codexintel-before-\(UUID().uuidString).txt")
        let newURL = temporaryDirectory.appendingPathComponent("codexintel-after-\(UUID().uuidString).txt")
        do {
            try beforeText.write(to: oldURL, atomically: true, encoding: .utf8)
            try afterText.write(to: newURL, atomically: true, encoding: .utf8)
            defer {
                try? FileManager.default.removeItem(at: oldURL)
                try? FileManager.default.removeItem(at: newURL)
            }

            let command = "git diff --no-index --no-color --unified=0 -- \(shellQuote(oldURL.path)) \(shellQuote(newURL.path)) || true"
            guard let patchOutput = try? await runner.run(command: command, workingDirectory: nil) else {
                return nil
            }

            var patchText = patchOutput.stdout
            patchText = patchText.replacingOccurrences(of: "a\(oldURL.path)", with: "a/\(relativePath)")
            patchText = patchText.replacingOccurrences(of: "b\(newURL.path)", with: "b/\(relativePath)")

            let fullLines = parseDiffLines(patchText, limit: 8_000).filter { $0.file == relativePath }
            if !fullLines.isEmpty {
                let added = fullLines.filter { $0.kind == .added }.count
                let removed = fullLines.filter { $0.kind == .removed }.count
                let preview = Array(fullLines.prefix(80))
                return (added: added, removed: removed, lines: preview)
            }

            return deriveSimpleLineDiff(beforeText: beforeText, afterText: afterText, file: relativePath, previewLimit: 80)
        } catch {
            return deriveSimpleLineDiff(beforeText: beforeText, afterText: afterText, file: relativePath, previewLimit: 80)
        }
    }

    private func deriveSimpleLineDiff(
        beforeText: String,
        afterText: String,
        file: String,
        previewLimit: Int
    ) -> (added: Int, removed: Int, lines: [DiffLine])? {
        let beforeLines = beforeText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let afterLines = afterText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        var prefix = 0
        while prefix < beforeLines.count && prefix < afterLines.count && beforeLines[prefix] == afterLines[prefix] {
            prefix += 1
        }

        var suffix = 0
        while suffix < beforeLines.count - prefix &&
                suffix < afterLines.count - prefix &&
                beforeLines[beforeLines.count - 1 - suffix] == afterLines[afterLines.count - 1 - suffix] {
            suffix += 1
        }

        let removedStart = prefix
        let removedEnd = max(prefix, beforeLines.count - suffix)
        let addedStart = prefix
        let addedEnd = max(prefix, afterLines.count - suffix)

        let removedCount = max(0, removedEnd - removedStart)
        let addedCount = max(0, addedEnd - addedStart)

        if removedCount == 0 && addedCount == 0 {
            return nil
        }

        var lines: [DiffLine] = []
        for index in removedStart..<min(removedEnd, removedStart + previewLimit) {
            lines.append(
                DiffLine(
                    file: file,
                    kind: .removed,
                    lineNumber: index + 1,
                    text: beforeLines[index]
                )
            )
        }

        let remaining = max(0, previewLimit - lines.count)
        if remaining > 0 {
            for index in addedStart..<min(addedEnd, addedStart + remaining) {
                lines.append(
                    DiffLine(
                        file: file,
                        kind: .added,
                        lineNumber: index + 1,
                        text: afterLines[index]
                    )
                )
            }
        }

        return (added: addedCount, removed: removedCount, lines: lines)
    }

    private func readFileTextLossy(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if !isLikelyText(data) {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func isLikelyText(_ data: Data) -> Bool {
        if data.isEmpty { return true }
        let sampleSize = min(4096, data.count)
        let sample = data.prefix(sampleSize)
        let nulCount = sample.filter { $0 == 0 }.count
        return nulCount == 0
    }

    private func captureGitRunSnapshot() async -> GitRunSnapshot {
        guard await isGitWorkspace() else {
            return GitRunSnapshot(isGitWorkspace: false, startHeadCommit: nil)
        }
        let head = await currentGitHeadCommit()
        return GitRunSnapshot(isGitWorkspace: true, startHeadCommit: head)
    }

    private func currentGitHeadCommit() async -> String? {
        guard !projectPath.isEmpty else { return nil }
        guard let output = try? await runner.run(
            command: "git rev-parse HEAD",
            workingDirectory: projectPath
        ) else { return nil }
        guard output.exitCode == 0 else { return nil }
        let commit = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return commit.isEmpty ? nil : commit
    }

    private func refreshChangeSummaryFromCommittedRange(snapshot: GitRunSnapshot) async -> Bool {
        guard snapshot.isGitWorkspace else { return false }
        guard let start = snapshot.startHeadCommit, !start.isEmpty else { return false }
        guard let end = await currentGitHeadCommit(), !end.isEmpty else { return false }
        guard start != end else { return false }

        do {
            let numstatOutput = try await runner.run(
                command: "git diff --numstat --no-renames \(shellQuote(start))..\(shellQuote(end))",
                workingDirectory: projectPath
            )
            let patchOutput = try await runner.run(
                command: "git diff --no-color --unified=0 --no-renames \(shellQuote(start))..\(shellQuote(end))",
                workingDirectory: projectPath
            )
            guard numstatOutput.exitCode == 0, patchOutput.exitCode == 0 else { return false }

            let files = parseNumstat(numstatOutput.stdout).sorted { $0.path < $1.path }
            guard !files.isEmpty else { return false }

            latestDiffFiles = files
            latestDiffAdded = files.reduce(0) { $0 + $1.added }
            latestDiffRemoved = files.reduce(0) { $0 + $1.removed }
            latestDiffLines = parseDiffLines(patchOutput.stdout, limit: 200)
            appendActivity("Detected committed changes: +\(latestDiffAdded) / -\(latestDiffRemoved) across \(files.count) file(s).")
            return true
        } catch {
            log("Unable to derive committed range changes: \(error.localizedDescription)")
            return false
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
        var oldLineCursor: Int?
        var newLineCursor: Int?

        for raw in diffText.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)

            if line.hasPrefix("diff --git ") {
                let parts = line.split(separator: " ")
                if let candidate = parts.last {
                    let value = String(candidate)
                    currentFile = value.hasPrefix("b/") ? String(value.dropFirst(2)) : value
                }
                oldLineCursor = nil
                newLineCursor = nil
                continue
            }
            if line.hasPrefix("+++ b/") {
                currentFile = String(line.dropFirst(6))
                continue
            }
            if line.hasPrefix("--- ") || line.hasPrefix("index ") || line.hasPrefix("new file mode") || line.hasPrefix("deleted file mode") {
                continue
            }
            if line.hasPrefix("@@") {
                if let hunk = parseDiffHunkHeader(line) {
                    oldLineCursor = hunk.oldStart
                    newLineCursor = hunk.newStart
                }
                continue
            }

            if line.hasPrefix("+"), !line.hasPrefix("+++") {
                lines.append(
                    DiffLine(
                        file: currentFile,
                        kind: .added,
                        lineNumber: newLineCursor,
                        text: String(line.dropFirst())
                    )
                )
                if let value = newLineCursor {
                    newLineCursor = value + 1
                }
            } else if line.hasPrefix("-"), !line.hasPrefix("---") {
                lines.append(
                    DiffLine(
                        file: currentFile,
                        kind: .removed,
                        lineNumber: oldLineCursor,
                        text: String(line.dropFirst())
                    )
                )
                if let value = oldLineCursor {
                    oldLineCursor = value + 1
                }
            } else if !line.hasPrefix("\\ No newline at end of file") {
                if let value = oldLineCursor {
                    oldLineCursor = value + 1
                }
                if let value = newLineCursor {
                    newLineCursor = value + 1
                }
            }

            if lines.count >= limit {
                break
            }
        }

        return lines
    }

    private func parseDiffHunkHeader(_ line: String) -> (oldStart: Int, newStart: Int)? {
        let pattern = "^@@ -([0-9]+)(?:,[0-9]+)? \\+([0-9]+)(?:,[0-9]+)? @@"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let fullRange = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, options: [], range: fullRange) else { return nil }
        guard
            let oldRange = Range(match.range(at: 1), in: line),
            let newRange = Range(match.range(at: 2), in: line),
            let oldStart = Int(line[oldRange]),
            let newStart = Int(line[newRange])
        else {
            return nil
        }
        return (oldStart: oldStart, newStart: newStart)
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

    private func powerUserLogExportText() -> String {
        var lines: [String] = []
        lines.append("CodexIntelApp Log Export")
        lines.append("Generated: \(iso8601Timestamp(Date()))")
        lines.append("Project: \(projectPath.isEmpty ? "(none)" : projectPath)")
        lines.append("Session: \(codexSessionState)")
        lines.append("Model: \(currentModelSummary)")
        lines.append("")

        lines.append("Command Log")
        if commandLog.isEmpty {
            lines.append("(empty)")
        } else {
            lines.append(contentsOf: commandLog)
        }

        lines.append("")
        lines.append("Live Activity")
        if liveActivity.isEmpty {
            lines.append("(empty)")
        } else {
            lines.append(contentsOf: liveActivity)
        }
        lines.append("")

        return lines.joined(separator: "\n")
    }

    private func timestampForFilename() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private func iso8601Timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: date)
    }
}

struct ContentView: View {
    @StateObject private var viewModel = AppViewModel()
    @State private var collapsedChangeFiles: Set<String> = []

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
                Divider()
                Button("Connect ChatGPT Account") {
                    viewModel.connectChatGPTAccount()
                }
                .disabled(viewModel.isBusy)
                Button("Refresh Account Status") {
                    viewModel.refreshAccountStatus()
                }
                .disabled(viewModel.isBusy)
            } label: {
                topBarFlatLabel("Project", systemImage: "folder")
            }
            .menuStyle(.borderlessButton)

            Button(viewModel.showGitSetup ? "Hide Git Setup" : "Setup Git") {
                viewModel.showGitSetup.toggle()
            }
            .buttonStyle(.plain)
            .modifier(TopBarFlatChip())

            Button(viewModel.showPowerUserPanel ? "Hide Power User" : "Power User") {
                viewModel.showPowerUserPanel.toggle()
            }
            .buttonStyle(.plain)
            .modifier(TopBarFlatChip())

            Spacer()
            modelSelectionChip
            reasoningSelectionChip

            Text(viewModel.codexCliVersion)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .textSelection(.enabled)
                .frame(maxWidth: 220, alignment: .trailing)

            Text("Account: \(viewModel.codexAccountStatus)")
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

    private var modelSelectionChip: some View {
        Menu {
            ForEach(viewModel.availableModels, id: \.self) { model in
                Button {
                    viewModel.selectedModel = model
                } label: {
                    if model == viewModel.selectedModel {
                        Label(model, systemImage: "checkmark")
                    } else {
                        Text(model)
                    }
                }
            }
        } label: {
            topBarSelectionLabel(title: "Model", value: viewModel.selectedModel, width: 180)
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
    }

    private var reasoningSelectionChip: some View {
        Menu {
            ForEach(viewModel.availableReasoningEfforts, id: \.self) { effort in
                Button {
                    viewModel.selectedReasoningEffort = effort
                } label: {
                    let display = viewModel.reasoningDisplayName(for: effort)
                    if effort == viewModel.selectedReasoningEffort {
                        Label(display, systemImage: "checkmark")
                    } else {
                        Text(display)
                    }
                }
            }
        } label: {
            topBarSelectionLabel(
                title: "Reasoning",
                value: viewModel.reasoningDisplayName(for: viewModel.selectedReasoningEffort),
                width: 130
            )
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
    }

    private func topBarSelectionLabel(title: String, value: String, width: CGFloat) -> some View {
        HStack(spacing: 8) {
            Text("\(title): \(value)")
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: width, alignment: .leading)
            Image(systemName: "chevron.down")
                .font(.caption2.weight(.semibold))
                .foregroundColor(.secondary)
        }
        .modifier(TopBarFlatChip())
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
                    Text("Account: \(viewModel.codexAccountStatus)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("Current: \(viewModel.currentModelSummary)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if !viewModel.recentProjects.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Recent Projects")
                            .font(.subheadline.weight(.semibold))
                        ForEach(viewModel.recentProjects, id: \.self) { path in
                            Button {
                                viewModel.selectRecentProject(path)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(URL(fileURLWithPath: path).lastPathComponent)
                                        .font(.caption.weight(.semibold))
                                        .lineLimit(1)
                                    Text(path)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .background(
                                    (path == viewModel.projectPath ? Color.accentColor.opacity(0.14) : Color(nsColor: .controlBackgroundColor))
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                            .disabled(viewModel.isBusy)
                        }
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    DisclosureGroup(isExpanded: $viewModel.showChangesAccordion) {
                        VStack(alignment: .leading, spacing: 10) {
                            if viewModel.latestDiffFiles.isEmpty {
                                Text("No line updates available yet.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            } else {
                                Text("\(viewModel.latestDiffFiles.count) \(viewModel.latestDiffFiles.count == 1 ? "file" : "files") changed")
                                    .font(.caption.weight(.semibold))
                                    .foregroundColor(.secondary)

                                ScrollView {
                                    VStack(alignment: .leading, spacing: 10) {
                                        ForEach(viewModel.latestDiffFiles) { file in
                                            DisclosureGroup(isExpanded: changeFileExpandedBinding(for: file.path)) {
                                                let previewLines = diffLinesPreview(for: file.path, limit: 90)
                                                if previewLines.isEmpty {
                                                    Text("No line-level preview available for this file.")
                                                        .font(.caption2)
                                                        .foregroundColor(.secondary)
                                                        .padding(.vertical, 4)
                                                } else {
                                                    VStack(spacing: 0) {
                                                        ForEach(previewLines) { line in
                                                            diffLinePreviewRow(line)
                                                        }
                                                    }
                                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                                }
                                            } label: {
                                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                                    Text(file.path)
                                                        .font(.caption.weight(.semibold))
                                                        .lineLimit(1)
                                                    Spacer(minLength: 4)
                                                    if file.added == 0 && file.removed == 0 {
                                                        Text("changed")
                                                            .font(.caption.weight(.semibold))
                                                            .foregroundColor(.secondary)
                                                    } else {
                                                        Text("+\(file.added)")
                                                            .font(.caption.weight(.semibold))
                                                            .foregroundColor(.green)
                                                        Text("-\(file.removed)")
                                                            .font(.caption.weight(.semibold))
                                                            .foregroundColor(.red)
                                                    }
                                                }
                                            }
                                            .padding(8)
                                            .background(Color(nsColor: .controlBackgroundColor))
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                        }
                                    }
                                    .padding(.vertical, 2)
                                }
                                .frame(minHeight: 180, maxHeight: 360)
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

                        HStack {
                            Text("Command Log")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Button("Export Log") {
                                viewModel.exportPowerUserLog()
                            }
                            .buttonStyle(.plain)
                            .modifier(TopBarFlatChip())
                            .font(.caption.weight(.semibold))
                        }
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

    private var composerActionIconName: String {
        viewModel.isBusy ? "stop.circle.fill" : "arrow.up.circle.fill"
    }

    private var composerActionColor: Color {
        viewModel.isBusy ? .red : (sendDisabled ? .gray : .accentColor)
    }

    private var composerActionDisabled: Bool {
        viewModel.isBusy ? false : sendDisabled
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

    private var visibleThinkingHighlights: [String] {
        let current = normalizedStatusForComparison(viewModel.thinkingStatus)
        let filtered = viewModel.thinkingHighlights.filter { item in
            let normalized = normalizedStatusForComparison(item)
            return !normalized.isEmpty && normalized != current
        }
        return Array(filtered.suffix(3))
    }

    private var latestAssistantMessageID: UUID? {
        viewModel.messages.last(where: { $0.role == .assistant })?.id
    }

    private func inlineChangeData(for message: ChatMessage) -> (files: [DiffFileStat], lines: [DiffLine]) {
        guard message.role == .assistant else { return ([], []) }
        guard message.id == latestAssistantMessageID else { return ([], []) }
        return (viewModel.latestDiffFiles, viewModel.latestDiffLines)
    }

    private func normalizedStatusForComparison(_ value: String) -> String {
        value
            .replacingOccurrences(
                of: "\\s*\\([0-9]+s(?:\\s+without\\s+new\\s+output)?\\)$",
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
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
                            let inline = inlineChangeData(for: message)
                            MessageBubble(
                                message: message,
                                inlineDiffFiles: inline.files,
                                inlineDiffLines: inline.lines
                            )
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

                    if viewModel.isBusy, !visibleThinkingHighlights.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(visibleThinkingHighlights.enumerated()), id: \.offset) { _, item in
                                Text("• \(item)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
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
                            if viewModel.isBusy {
                                viewModel.stopActiveRun()
                            } else {
                                viewModel.sendPrompt()
                            }
                        } label: {
                            Image(systemName: composerActionIconName)
                                .font(.system(size: 32))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(composerActionColor)
                        .disabled(composerActionDisabled)
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

    private func changeFileExpandedBinding(for path: String) -> Binding<Bool> {
        Binding(
            get: { !collapsedChangeFiles.contains(path) },
            set: { expanded in
                if expanded {
                    collapsedChangeFiles.remove(path)
                } else {
                    collapsedChangeFiles.insert(path)
                }
            }
        )
    }

    private func diffLinesPreview(for filePath: String, limit: Int) -> [DiffLine] {
        Array(viewModel.latestDiffLines.filter { $0.file == filePath }.prefix(limit))
    }

    private func diffLinePreviewRow(_ line: DiffLine) -> some View {
        let isAdded = line.kind == .added
        let sign = isAdded ? "+" : "-"
        let lineText = line.text.isEmpty ? " " : line.text

        return HStack(spacing: 0) {
            Text(line.lineNumber.map(String.init) ?? "·")
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 52, alignment: .trailing)
                .padding(.trailing, 8)
                .padding(.vertical, 2)
                .background(Color.black.opacity(0.18))

            HStack(spacing: 6) {
                Text(sign)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(isAdded ? .green : .red)
                Text(lineText)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background((isAdded ? Color.green : Color.red).opacity(0.16))
        }
        .overlay(alignment: .leading) {
            Rectangle()
                .fill((isAdded ? Color.green : Color.red).opacity(0.95))
                .frame(width: 3)
        }
    }
}

private struct TopBarFlatChip: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

@ViewBuilder
private func topBarFlatLabel(_ text: String, systemImage: String? = nil) -> some View {
    if let systemImage {
        Label(text, systemImage: systemImage)
            .modifier(TopBarFlatChip())
    } else {
        Text(text)
            .modifier(TopBarFlatChip())
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    let inlineDiffFiles: [DiffFileStat]
    let inlineDiffLines: [DiffLine]
    @State private var expanded = false
    @State private var showInlineChanges = false

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

            if hasInlineDiff {
                Button(showInlineChanges ? "Hide changes" : "Show changes") {
                    showInlineChanges.toggle()
                }
                .buttonStyle(.plain)
                .font(.caption2.weight(.semibold))
                .foregroundColor(.secondary)

                if showInlineChanges {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(inlineDiffFiles.prefix(6)) { file in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Text(file.path)
                                        .font(.caption2.weight(.semibold))
                                        .lineLimit(1)
                                    Spacer(minLength: 4)
                                    if file.added == 0 && file.removed == 0 {
                                        Text("changed")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundColor(.secondary)
                                    } else {
                                        Text("+\(file.added)")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundColor(.green)
                                        Text("-\(file.removed)")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundColor(.red)
                                    }
                                }

                                let rows = linePreviewForFile(file.path, limit: 20)
                                if rows.isEmpty {
                                    Text("No line preview available.")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                } else {
                                    VStack(spacing: 0) {
                                        ForEach(rows) { row in
                                            inlineDiffRow(row)
                                        }
                                    }
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                }
                            }
                            .padding(8)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }

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

    private var hasInlineDiff: Bool {
        message.role == .assistant && !inlineDiffFiles.isEmpty
    }

    private func linePreviewForFile(_ path: String, limit: Int) -> [DiffLine] {
        Array(inlineDiffLines.filter { $0.file == path }.prefix(limit))
    }

    private func inlineDiffRow(_ line: DiffLine) -> some View {
        let isAdded = line.kind == .added
        let sign = isAdded ? "+" : "-"

        return HStack(spacing: 0) {
            Text(line.lineNumber.map(String.init) ?? "·")
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 44, alignment: .trailing)
                .padding(.trailing, 6)
                .padding(.vertical, 1)
                .background(Color.black.opacity(0.14))

            HStack(spacing: 4) {
                Text(sign)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(isAdded ? .green : .red)
                Text(line.text.isEmpty ? " " : line.text)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background((isAdded ? Color.green : Color.red).opacity(0.14))
        }
    }
}
