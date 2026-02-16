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

enum ViewModelError: LocalizedError {
    case projectNotSelected
    case emptyPrompt

    var errorDescription: String? {
        switch self {
        case .projectNotSelected:
            return "Select a project folder first."
        case .emptyPrompt:
            return "Prompt is empty."
        }
    }
}

struct ShellRunner {
    func run(command: String, workingDirectory: String?) async throws -> CommandOutput {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let output = try ShellRunner.runSync(command: command, workingDirectory: workingDirectory)
                    continuation.resume(returning: output)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func runSync(command: String, workingDirectory: String?) throws -> CommandOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        if let workingDirectory, !workingDirectory.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        }

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
}

@MainActor
final class AppViewModel: ObservableObject {
    @Published var projectPath = ""
    @Published var gitRemote = "origin"
    @Published var gitBranch = ""
    @Published var commitMessage = "Update via CodexIntelApp"
    @Published var draftPrompt = ""

    @Published var messages: [ChatMessage] = [
        ChatMessage(
            role: .system,
            content: "Select a project folder, then send prompts. Codex commands run in that project directory."
        )
    ]
    @Published var commandLog: [String] = []
    @Published var isBusy = false
    @Published var busyLabel = ""

    private let runner = ShellRunner()
    private let codexTemplate = "codex exec {prompt}"

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
                await refreshGitInfo()
            }
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
                command: "code .",
                includeAsAssistantMessage: false
            )
        }
    }

    func gitPush() {
        let branch = gitBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        let remote = gitRemote.trimmingCharacters(in: .whitespacesAndNewlines)
        let pushCommand = branch.isEmpty
            ? "git push \(shellQuote(remote))"
            : "git push \(shellQuote(remote)) \(shellQuote(branch))"

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
        let branch = gitBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        let remote = gitRemote.trimmingCharacters(in: .whitespacesAndNewlines)

        var command = "git add -A && git commit -m \(shellQuote(commit))"
        if branch.isEmpty {
            command += " && git push \(shellQuote(remote))"
        } else {
            command += " && git push \(shellQuote(remote)) \(shellQuote(branch))"
        }

        Task {
            await runUtilityCommand(
                label: "Committing and pushing",
                command: command,
                includeAsAssistantMessage: true
            )
        }
    }

    private func runCodex(for userPrompt: String) async {
        do {
            try validateProjectAndTemplate(prompt: userPrompt)
            let enrichedPrompt = buildPromptWithHistory(newPrompt: userPrompt)
            let command = codexTemplate.replacingOccurrences(
                of: "{prompt}",
                with: shellQuote(enrichedPrompt)
            )
            let output = try await executeBusyCommand(label: "Running Codex", command: command)
            let response = cleanOutput(output.stdout, fallback: output.stderr)
            messages.append(ChatMessage(role: .assistant, content: response))
            if output.exitCode != 0 {
                log("Codex exited with code \(output.exitCode)")
            }
        } catch {
            let text = error.localizedDescription
            messages.append(ChatMessage(role: .assistant, content: "Error: \(text)"))
            log("Error: \(text)")
        }
        await autoCommitAndPushAfterChat()
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

            if label == "Pushing git branch" || label == "Committing and pushing" {
                await refreshGitInfo()
            }
        } catch {
            log("Error: \(error.localizedDescription)")
            messages.append(ChatMessage(role: .assistant, content: "Error: \(error.localizedDescription)"))
        }
    }

    private func executeBusyCommand(label: String, command: String) async throws -> CommandOutput {
        isBusy = true
        busyLabel = label
        log("[\(label)] \(command)")
        defer {
            isBusy = false
            busyLabel = ""
        }
        return try await runner.run(command: command, workingDirectory: projectPath)
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
        Continue this coding conversation. Keep the response concise and action-focused.
        Recent conversation:
        \(recentHistory)

        Latest user request:
        \(newPrompt)
        """
    }

    private func refreshGitInfo() async {
        do {
            try validateProjectSelected()
            let branch = try await runner.run(
                command: "git rev-parse --abbrev-ref HEAD",
                workingDirectory: projectPath
            )
            let cleanBranch = branch.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleanBranch.isEmpty {
                gitBranch = cleanBranch
            }
        } catch {
            log("Git info unavailable: \(error.localizedDescription)")
        }
    }

    private func autoCommitAndPushAfterChat() async {
        let project = projectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !project.isEmpty else { return }

        let remote = gitRemote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remote.isEmpty else {
            log("Auto push skipped: git remote is empty.")
            return
        }

        let commit = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Update via CodexIntelApp"
            : commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)

        var branch = gitBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        if branch.isEmpty {
            do {
                let branchOutput = try await runner.run(
                    command: "git rev-parse --abbrev-ref HEAD",
                    workingDirectory: projectPath
                )
                branch = branchOutput.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                log("Auto push skipped: unable to detect git branch (\(error.localizedDescription)).")
                return
            }
        }

        guard !branch.isEmpty else {
            log("Auto push skipped: git branch is empty.")
            return
        }

        let command = "git add -A && (git diff --cached --quiet || git commit -m \(shellQuote(commit))) && git push -u \(shellQuote(remote)) \(shellQuote(branch))"

        do {
            let output = try await executeBusyCommand(label: "Auto commit + push", command: command)
            if output.exitCode != 0 {
                let details = cleanOutput(output.stdout, fallback: output.stderr)
                log("Auto push failed with code \(output.exitCode): \(details)")
                messages.append(ChatMessage(role: .system, content: "Auto push failed: \(details)"))
            } else {
                log("Auto push completed for \(remote)/\(branch).")
            }
            await refreshGitInfo()
        } catch {
            log("Auto push error: \(error.localizedDescription)")
            messages.append(ChatMessage(role: .system, content: "Auto push error: \(error.localizedDescription)"))
        }
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

    private func shellQuote(_ value: String) -> String {
        if value.isEmpty { return "''" }
        let escaped = value.replacingOccurrences(of: "'", with: "'\"'\"'")
        return "'\(escaped)'"
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
                        Button("Open in VS Code") {
                            viewModel.openInVSCode()
                        }
                        .disabled(viewModel.projectPath.isEmpty || viewModel.isBusy)
                    }
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
                        .disabled(viewModel.projectPath.isEmpty || viewModel.isBusy)

                        Button("Commit + Push") {
                            viewModel.gitCommitAndPush()
                        }
                        .disabled(viewModel.projectPath.isEmpty || viewModel.isBusy)
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
                    Text(viewModel.busyLabel)
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
