//
//  ChatView+Actions.swift
//  agentGui
//

import SwiftUI
import SwiftData
import AppKit

extension ChatView {

    // MARK: - Send Message

    func sendMessage() async {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, claudeService.isConfigured else {
            if !claudeService.isConfigured {
                errorMessage = "请先在「设置」中配置 Anthropic API Key"
            }
            return
        }

        var fullText = trimmed
        let settings = AppSettings.getOrCreate(in: modelContext)
        fullText = expandMentions(in: fullText, workingDirectory: settings.workingDirectory)

        // Build a parseable workspace context prefix from the current file path and/or selected text.
        var contextParts: [String] = []
        if showSelectionContext, let sel = workspaceState.editorSelectedText, !sel.isEmpty {
            if let fileURL = workspaceState.selectedFile {
                contextParts.append("当前文件: \(WorkspaceFileContextFormatter.inlineReference(for: fileURL, lineRange: workspaceState.editorSelectedLineRange))")
            } else if let lineRange = workspaceState.editorSelectedLineRange {
                contextParts.append("当前文件: :\(lineRange.displayText)")
            } else {
                contextParts.append("当前文件:")
            }
            contextParts.append("选区内容:\n\(sel)")
        } else if showFileContext, let fileURL = workspaceState.selectedFile {
            contextParts.append("当前文件: \(WorkspaceFileContextFormatter.inlineReference(for: fileURL))")
        }
        if !contextParts.isEmpty {
            fullText = contextParts.joined(separator: "\n") + "\n\n" + fullText
        }

        if !attachedFiles.isEmpty {
            let refs = attachedFiles.map { "- \($0.path)" }.joined(separator: "\n")
            fullText += "\n\nReferenced files:\n\(refs)"
        }

        do {
            _ = try claudeService.resolveTurnSkillContext(
                enabledSkillNames: settings.enabledSkillNames,
                directives: activeInputDirectives
            )
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        let auditedText = ChatInputDirectiveAudit.appendAuditTrail(
            to: fullText,
            directives: activeInputDirectives
        )

        inputText = ""
        attachedFiles = []
        showFileContext = true
        showSelectionContext = true

        let userMessage = Message.userMessage(text: auditedText, session: session)
        userMessage.status = .completed
        modelContext.insert(userMessage)
        try? modelContext.save()

        let modelId = settings.selectedModel
        let selectedFilePath: String?
        if showFileContext || showSelectionContext {
            selectedFilePath = workspaceState.selectedFile?.standardizedFileURL.path
        } else {
            selectedFilePath = nil
        }
        let selectedText = showSelectionContext ? workspaceState.editorSelectedText : nil

        do {
            try await claudeService.sendMessage(
                text: auditedText,
                session: session,
                modelId: modelId,
                selectedFilePath: selectedFilePath,
                selectedText: selectedText,
                directives: activeInputDirectives,
                modelContext: modelContext
            )
            activeInputDirectives = []
        } catch is CancellationError {
            // User stopped the stream — no error to show
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - @ Mention Expansion

    /// Replaces @relPath tokens with their absolute path when the file exists under workingDirectory.
    func expandMentions(in text: String, workingDirectory: String) -> String {
        guard !workingDirectory.isEmpty,
              let regex = try? NSRegularExpression(pattern: #"@(\S+)"#)
        else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var result = text
        // Iterate in reverse so replacements don't shift earlier offsets
        for match in matches.reversed() {
            guard match.numberOfRanges == 2 else { continue }
            let relRange = match.range(at: 1)
            let relPath = ns.substring(with: relRange)
            let absPath = (workingDirectory as NSString).appendingPathComponent(relPath)
            guard FileManager.default.fileExists(atPath: absPath) else { continue }
            if let swiftRange = Range(match.range(at: 0), in: result) {
                result.replaceSubrange(swiftRange, with: absPath)
            }
        }
        return result
    }

    // MARK: - Message Actions

    func copyMessage(_ message: Message) {
        let text = message.textContent ?? ""
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func deleteMessage(_ message: Message) {
        _ = message.toolCalls
        _ = message.agentRounds
        modelContext.delete(message)
        try? modelContext.save()
    }

    func deleteFrom(_ message: Message) {
        deleteFromConfirmMessage = message
    }

    func confirmDeleteFrom(_ message: Message) {
        activeTask?.cancel()
        activeTask = nil
        let seq = message.sequence
        // Snapshot and pre-resolve faults before deletion
        let snapshot = allMessages.filter { $0.sequence >= seq }
        for msg in snapshot {
            _ = msg.toolCalls
            _ = msg.agentRounds
            modelContext.delete(msg)
        }
        try? modelContext.save()
    }

    func regenerate() {
        guard !claudeService.isStreaming else { return }
        activeTask = Task {
            let settings = AppSettings.getOrCreate(in: modelContext)
            do {
                try await claudeService.regenerate(
                    session: session,
                    modelId: settings.selectedModel,
                    modelContext: modelContext
                )
            } catch is CancellationError {
                // User stopped
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func editAndResend(message: Message, newText: String) {
        guard !claudeService.isStreaming else { return }
        activeTask = Task {
            let settings = AppSettings.getOrCreate(in: modelContext)
            do {
                try await claudeService.editAndResend(
                    message: message,
                    newText: newText,
                    session: session,
                    modelId: settings.selectedModel,
                    modelContext: modelContext
                )
            } catch is CancellationError {
                // User stopped
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func stopStreaming() {
        activeTask?.cancel()
        activeTask = nil
    }
}
