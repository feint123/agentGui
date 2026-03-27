import Foundation
import SwiftData

nonisolated enum ConversationExecutionRuntimeScope: String, Equatable, Sendable {
    case builtIn
    case externalACP
}

nonisolated enum ConversationExecutionActivationTrigger: Equatable, Sendable {
    case selection
    case sessionBootstrap
    case executionDispatch
}

nonisolated enum ConversationExecutionRuntimeReleaseReason: Equatable, Sendable {
    case sessionBecameInactive
    case providerBecameInactive
}

struct ConversationExecutionRequest {
    let text: String
    let session: Session
    let modelID: String
    let selectedFilePath: String?
    let selectedText: String?
    let directives: [ChatInputDirective]
    let modelContext: ModelContext
    let sourceUserMessageID: UUID?
    let targetAgentMessageID: UUID?
    let workingDirectoryOverride: String?

    init(
        text: String,
        session: Session,
        modelID: String,
        selectedFilePath: String?,
        selectedText: String?,
        directives: [ChatInputDirective],
        modelContext: ModelContext,
        sourceUserMessageID: UUID? = nil,
        targetAgentMessageID: UUID? = nil,
        workingDirectoryOverride: String? = nil
    ) {
        self.text = text
        self.session = session
        self.modelID = modelID
        self.selectedFilePath = selectedFilePath
        self.selectedText = selectedText
        self.directives = directives
        self.modelContext = modelContext
        self.sourceUserMessageID = sourceUserMessageID
        self.targetAgentMessageID = targetAgentMessageID
        self.workingDirectoryOverride = workingDirectoryOverride
    }
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
    var reference: ExecutionProviderReference { get }
    var legacyProviderID: ConversationExecutionProviderID? { get }
    var runtimeScope: ConversationExecutionRuntimeScope? { get }

    func send(_ request: ConversationExecutionRequest) async throws
    func regenerate(_ request: ConversationRegenerationRequest) async throws
    func editAndResend(_ request: ConversationEditAndResendRequest) async throws
    func cancel(session: Session, modelContext: ModelContext) async
    func resetSessionState(session: Session, modelContext: ModelContext) async
    func prepareForActivation(
        session: Session,
        isActiveProvider: Bool,
        modelContext: ModelContext,
        trigger: ConversationExecutionActivationTrigger
    ) async
    func releasePreparedRuntime(
        localSessionID: String,
        modelContext: ModelContext,
        reason: ConversationExecutionRuntimeReleaseReason
    ) async
}

extension ConversationExecutionProvider {
    var legacyProviderID: ConversationExecutionProviderID? { nil }

    var id: ConversationExecutionProviderID {
        legacyProviderID ?? .builtInAgent
    }

    var runtimeScope: ConversationExecutionRuntimeScope? { nil }

    func resetSessionState(session: Session, modelContext: ModelContext) async {
        _ = session
        _ = modelContext
    }

    func prepareForActivation(
        session: Session,
        isActiveProvider: Bool,
        modelContext: ModelContext,
        trigger: ConversationExecutionActivationTrigger
    ) async {
        _ = session
        _ = isActiveProvider
        _ = modelContext
        _ = trigger
    }

    func releasePreparedRuntime(
        localSessionID: String,
        modelContext: ModelContext,
        reason: ConversationExecutionRuntimeReleaseReason
    ) async {
        _ = localSessionID
        _ = modelContext
        _ = reason
    }
}

@MainActor
final class BuiltInConversationExecutionProvider: ConversationExecutionProvider {
    let reference: ExecutionProviderReference = .builtIn
    let legacyProviderID: ConversationExecutionProviderID? = .builtInAgent
    let runtimeScope: ConversationExecutionRuntimeScope? = .builtIn

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
            targetAgentMessageID: request.targetAgentMessageID,
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
        _ = modelContext
        claudeService.acpPermissionCenter.cancelRequests(for: session.sessionId)
    }

    func resetSessionState(session: Session, modelContext: ModelContext) async {
        _ = modelContext
        claudeService.acpPermissionCenter.cancelRequests(for: session.sessionId)
    }
}

struct ConversationExecutionProviderRegistry {
    let builtIn: any ConversationExecutionProvider
    private let providersByReference: [ExecutionProviderReference: any ConversationExecutionProvider]
    private let compatibilityProvidersByID: [ConversationExecutionProviderID: any ConversationExecutionProvider]

    init(
        builtIn: any ConversationExecutionProvider,
        externalProviders: [ExecutionProviderReference: any ConversationExecutionProvider],
        compatibilityProvidersByID: [ConversationExecutionProviderID: any ConversationExecutionProvider] = [:]
    ) {
        self.builtIn = builtIn
        var providersByReference = externalProviders
        providersByReference[builtIn.reference] = builtIn
        self.providersByReference = providersByReference

        var compatibilityProviders = compatibilityProvidersByID
        compatibilityProviders[.builtInAgent] = builtIn
        for provider in externalProviders.values {
            if let legacyProviderID = provider.legacyProviderID {
                compatibilityProviders[legacyProviderID] = provider
            }
        }
        self.compatibilityProvidersByID = compatibilityProviders
    }

    var allProviders: [any ConversationExecutionProvider] {
        Array(providersByReference.values)
    }

    func providers(in runtimeScope: ConversationExecutionRuntimeScope) -> [any ConversationExecutionProvider] {
        allProviders.filter { $0.runtimeScope == runtimeScope }
    }

    func providerIfAvailable(for reference: ExecutionProviderReference) -> (any ConversationExecutionProvider)? {
        providersByReference[reference]
    }

    func provider(for reference: ExecutionProviderReference) -> any ConversationExecutionProvider {
        providersByReference[reference] ?? builtIn
    }

    func provider(for providerID: ConversationExecutionProviderID) -> any ConversationExecutionProvider {
        compatibilityProvidersByID[providerID] ?? builtIn
    }

    func driver(for providerReference: ExecutionProviderReference) -> any ConversationExecutionDriver {
        LegacyConversationExecutionDriver(provider: provider(for: providerReference))
    }

    func capacityPolicy(for providerID: ConversationExecutionProviderID) -> ProviderExecutionCapacityPolicy {
        switch providerID {
        case .builtInAgent:
            return ProviderExecutionCapacityPolicy(
                providerID: providerID,
                maxConcurrentSessions: .max,
                maxConcurrentJobsPerSession: 1,
                allowsBackgroundExecution: true
            )
        case .githubCopilotCLI, .openCodeCLI, .claudeAdapterCLI:
            return ProviderExecutionCapacityPolicy(
                providerID: providerID,
                maxConcurrentSessions: .max,
                maxConcurrentJobsPerSession: 1,
                allowsBackgroundExecution: true
            )
        }
    }

    func capacityPolicy(for providerReference: ExecutionProviderReference) -> ProviderExecutionCapacityPolicy {
        if let providerID = providerReference.compatibilityProviderID {
            return capacityPolicy(for: providerID)
        }

        return ProviderExecutionCapacityPolicy.default(for: providerReference)
    }

    func provider(for session: Session, settings: AppSettings) -> any ConversationExecutionProvider {
        provider(for: Self.resolveProviderReference(for: session, settings: settings))
    }

    static func resolveProviderReference(for session: Session, settings: AppSettings) -> ExecutionProviderReference {
        if !session.defaultExecutionProviderID.isEmpty {
            return session.defaultExecutionProviderReference
        }

        return settings.defaultExecutionProviderReference
    }

    static func resolveProviderID(for session: Session, settings: AppSettings) -> ConversationExecutionProviderID {
        let reference = resolveProviderReference(for: session, settings: settings)
        switch reference {
        case .builtIn:
            return .builtInAgent
        case .externalACP(let profileID):
            let legacyKey = LegacyExternalACPProviderKey.allCases.first {
                $0.compatibilityReference == .externalACP(profileID: profileID)
            }
            return legacyKey?.conversationExecutionProviderID ?? .builtInAgent
        }
    }
}