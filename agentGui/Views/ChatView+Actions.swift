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
        if !attachedFiles.isEmpty {
            let refs = attachedFiles.map { "- \($0.path)" }.joined(separator: "\n")
            fullText += "\n\nReferenced files:\n\(refs)"
        }

        inputText = ""
        attachedFiles = []

        let userMessage = Message.userMessage(text: fullText, session: session)
        userMessage.status = .completed
        modelContext.insert(userMessage)
        try? modelContext.save()

        let settings = AppSettings.getOrCreate(in: modelContext)
        let modelId = settings.selectedModel

        do {
            try await claudeService.sendMessage(
                text: fullText,
                session: session,
                modelId: modelId,
                modelContext: modelContext
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Message Actions

    func copyMessage(_ message: Message) {
        let text = message.textContent ?? ""
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func deleteMessage(_ message: Message) {
        modelContext.delete(message)
        try? modelContext.save()
    }

    func deleteFrom(_ message: Message) {
        deleteFromConfirmMessage = message
    }

    func confirmDeleteFrom(_ message: Message) {
        let seq = message.sequence
        for msg in allMessages where msg.sequence >= seq {
            modelContext.delete(msg)
        }
        try? modelContext.save()
    }

    func regenerate() {
        guard !claudeService.isStreaming else { return }
        Task {
            let settings = AppSettings.getOrCreate(in: modelContext)
            do {
                try await claudeService.regenerate(
                    session: session,
                    modelId: settings.selectedModel,
                    modelContext: modelContext
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func editAndResend(message: Message, newText: String) {
        guard !claudeService.isStreaming else { return }
        Task {
            let settings = AppSettings.getOrCreate(in: modelContext)
            do {
                try await claudeService.editAndResend(
                    message: message,
                    newText: newText,
                    session: session,
                    modelId: settings.selectedModel,
                    modelContext: modelContext
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
