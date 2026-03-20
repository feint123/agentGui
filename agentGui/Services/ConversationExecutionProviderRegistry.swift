import Foundation
import SwiftData

struct ConversationExecutionRequest {
    let text: String
    let session: Session
    let modelID: String
    let selectedFilePath: String?
    let selectedText: String?
    let directives: [ChatInputDirective]
    let modelContext: ModelContext
}

struct ConversationRegenerationRequest {
    let session: Session
    let modelID: String
    let modelContext: ModelContext
}

struct ConversationEditAndResendRequest {
    let message: Message
    let newText: String
    let session: Session
    let modelID: String
    let modelContext: ModelContext
}

@MainActor
protocol ConversationExecutionProvider: AnyObject {
    var id: ConversationExecutionProviderID { get }

    func send(_ request: ConversationExecutionRequest) async throws
    func regenerate(_ request: ConversationRegenerationRequest) async throws
    func editAndResend(_ request: ConversationEditAndResendRequest) async throws
    func cancel(session: Session, modelContext: ModelContext) async
}

@MainActor
final class BuiltInConversationExecutionProvider: ConversationExecutionProvider {
    let id: ConversationExecutionProviderID = .builtInAgent

    private unowned let claudeService: ClaudeService

    init(claudeService: ClaudeService) {
        self.claudeService = claudeService
    }

    func send(_ request: ConversationExecutionRequest) async throws {
        try await claudeService.sendMessageBuiltIn(
            text: request.text,
            session: request.session,
            modelId: request.modelID,
            selectedFilePath: request.selectedFilePath,
            selectedText: request.selectedText,
            directives: request.directives,
            modelContext: request.modelContext
        )
    }

    func regenerate(_ request: ConversationRegenerationRequest) async throws {
        try await claudeService.regenerateBuiltIn(
            session: request.session,
            modelId: request.modelID,
            modelContext: request.modelContext
        )
    }

    func editAndResend(_ request: ConversationEditAndResendRequest) async throws {
        try await claudeService.editAndResendBuiltIn(
            message: request.message,
            newText: request.newText,
            session: request.session,
            modelId: request.modelID,
            modelContext: request.modelContext
        )
    }

    func cancel(session: Session, modelContext: ModelContext) async {
        _ = session
        _ = modelContext
    }
}

struct ConversationExecutionProviderRegistry {
    let builtIn: any ConversationExecutionProvider
    let copilot: any ConversationExecutionProvider

    func provider(for session: Session, settings: AppSettings) -> any ConversationExecutionProvider {
        switch Self.resolveProviderID(for: session, settings: settings) {
        case .builtInAgent:
            return builtIn
        case .githubCopilotCLI:
            return copilot
        }
    }

    static func resolveProviderID(for session: Session, settings: AppSettings) -> ConversationExecutionProviderID {
        if let sessionProviderID = ConversationExecutionProviderID(rawValue: session.defaultExecutionProviderID),
           !session.defaultExecutionProviderID.isEmpty {
            return sessionProviderID
        }

        return ConversationExecutionProviderID(rawValue: settings.defaultExecutionProviderID) ?? .builtInAgent
    }
}