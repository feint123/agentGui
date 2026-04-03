import Foundation

struct AgentRuntimeDefinition: Sendable, Equatable {
    let name: String
    let displayName: String
    let description: String
    let argumentHint: String
    let systemPrompt: String
    let toolGrants: [ToolGrant]
    let maxTurns: Int
    let userInvocable: Bool
    let subagentInvocable: Bool
    let outputContract: String
    let readableArtifacts: Set<WorkflowArtifactKind>
    let writableArtifacts: Set<WorkflowArtifactKind>
    let subscribesTo: Set<WorkflowMessageKind>
    let defaultOutputMessageKind: WorkflowMessageKind
    let primaryOutputArtifactKind: WorkflowArtifactKind?
    let maxActivations: Int

    // MARK: - S-A1 Optional execution-trait fields
    let modelPreference: SubagentModelPreference
    let effort: SubagentEffort?
    let background: Bool
    let omitMainContext: Bool
    let initialPrompt: String?
    let criticalReminder: String?
    let color: String?
    let disallowedToolNames: [String]

    // MARK: - S-A2
    let isOneShot: Bool

    var workflowRoleDefinition: WorkflowRoleDefinition {
        WorkflowRoleDefinition(
            name: name,
            displayName: displayName,
            description: description,
            systemPrompt: systemPrompt,
            enableTextEditor: toolGrants.contains { $0.toolGroupID == .readOnlyEditor || $0.toolGroupID == .readWriteEditor || $0.toolID == "str_replace_based_edit_tool" },
            enableBash: toolGrants.contains { $0.toolGroupID == .shell || $0.toolID == "bash" },
            enableWebSearch: toolGrants.contains { $0.toolGroupID == .web || $0.toolID == "web_search" },
            enableWebFetch: toolGrants.contains { $0.toolGroupID == .web || $0.toolID == "web_fetch" },
            toolGrants: toolGrants,
            readableArtifacts: readableArtifacts,
            writableArtifacts: writableArtifacts,
            subscribesTo: subscribesTo,
            defaultOutputMessageKind: defaultOutputMessageKind,
            primaryOutputArtifactKind: primaryOutputArtifactKind,
            maxTurnsPerActivation: maxTurns,
            maxActivations: maxActivations,
            modelPreference: modelPreference,
            effort: effort,
            background: background,
            omitMainContext: omitMainContext,
            initialPrompt: initialPrompt,
            criticalReminder: criticalReminder,
            color: color,
            disallowedToolNames: disallowedToolNames,
            isOneShot: isOneShot
        )
    }
}

extension AgentRuntimeDefinition {
    static func make(from document: AgentDefinitionDocument) throws -> AgentRuntimeDefinition {
        let toolGrants = try document.toolGroupNames.map(Self.makeGrant(from:))

        switch document.name {
        case "explore":
            return AgentRuntimeDefinition(
                name: document.name,
                displayName: document.displayName,
                description: document.description,
                argumentHint: document.argumentHint,
                systemPrompt: document.body,
                toolGrants: toolGrants,
                maxTurns: document.maxTurns,
                userInvocable: document.userInvocable,
                subagentInvocable: document.subagentInvocable,
                outputContract: document.outputContract,
                readableArtifacts: [.plan],
                writableArtifacts: [.explorationReport],
                subscribesTo: [.task, .infoRequest],
                defaultOutputMessageKind: .infoResponse,
                primaryOutputArtifactKind: .explorationReport,
                maxActivations: 5,
                modelPreference: document.modelPreference,
                effort: document.effort,
                background: document.background,
                omitMainContext: document.omitMainContext,
                initialPrompt: document.initialPrompt,
                criticalReminder: document.criticalReminder,
                color: document.color,
                disallowedToolNames: document.disallowedToolNames,
                isOneShot: document.isOneShot
            )
        case "worker":
            return AgentRuntimeDefinition(
                name: document.name,
                displayName: document.displayName,
                description: document.description,
                argumentHint: document.argumentHint,
                systemPrompt: document.body,
                toolGrants: toolGrants,
                maxTurns: document.maxTurns,
                userInvocable: document.userInvocable,
                subagentInvocable: document.subagentInvocable,
                outputContract: document.outputContract,
                readableArtifacts: [.plan, .explorationReport, .reviewReport, .testReport],
                writableArtifacts: [.codePatchSummary],
                subscribesTo: [.task, .reviewFeedback, .rejection, .infoResponse],
                defaultOutputMessageKind: .handoff,
                primaryOutputArtifactKind: .codePatchSummary,
                maxActivations: 5,
                modelPreference: document.modelPreference,
                effort: document.effort,
                background: document.background,
                omitMainContext: document.omitMainContext,
                initialPrompt: document.initialPrompt,
                criticalReminder: document.criticalReminder,
                color: document.color,
                disallowedToolNames: document.disallowedToolNames,
                isOneShot: document.isOneShot
            )
        case "verifier":
            return AgentRuntimeDefinition(
                name: document.name,
                displayName: document.displayName,
                description: document.description,
                argumentHint: document.argumentHint,
                systemPrompt: document.body,
                toolGrants: toolGrants,
                maxTurns: document.maxTurns,
                userInvocable: document.userInvocable,
                subagentInvocable: document.subagentInvocable,
                outputContract: document.outputContract,
                readableArtifacts: [.plan, .explorationReport, .codePatchSummary, .reviewReport, .testReport],
                writableArtifacts: [],
                subscribesTo: [.task, .handoff],
                defaultOutputMessageKind: .statusUpdate,
                primaryOutputArtifactKind: nil,
                maxActivations: 3,
                modelPreference: document.modelPreference,
                effort: document.effort,
                background: document.background,
                omitMainContext: document.omitMainContext,
                initialPrompt: document.initialPrompt,
                criticalReminder: document.criticalReminder,
                color: document.color,
                disallowedToolNames: document.disallowedToolNames,
                isOneShot: document.isOneShot
            )
        case "plan":
            return AgentRuntimeDefinition(
                name: document.name,
                displayName: document.displayName,
                description: document.description,
                argumentHint: document.argumentHint,
                systemPrompt: document.body,
                toolGrants: toolGrants,
                maxTurns: document.maxTurns,
                userInvocable: document.userInvocable,
                subagentInvocable: document.subagentInvocable,
                outputContract: document.outputContract,
                readableArtifacts: [.explorationReport],
                writableArtifacts: [.plan],
                subscribesTo: [.task],
                defaultOutputMessageKind: .statusUpdate,
                primaryOutputArtifactKind: .plan,
                maxActivations: 3,
                modelPreference: document.modelPreference,
                effort: document.effort,
                background: document.background,
                omitMainContext: document.omitMainContext,
                initialPrompt: document.initialPrompt,
                criticalReminder: document.criticalReminder,
                color: document.color,
                disallowedToolNames: document.disallowedToolNames,
                isOneShot: document.isOneShot
            )
        default:
            return AgentRuntimeDefinition(
                name: document.name,
                displayName: document.displayName,
                description: document.description,
                argumentHint: document.argumentHint,
                systemPrompt: document.body,
                toolGrants: toolGrants,
                maxTurns: document.maxTurns,
                userInvocable: document.userInvocable,
                subagentInvocable: document.subagentInvocable,
                outputContract: document.outputContract,
                readableArtifacts: [],
                writableArtifacts: [],
                subscribesTo: [.task],
                defaultOutputMessageKind: .statusUpdate,
                primaryOutputArtifactKind: nil,
                maxActivations: 5,
                modelPreference: document.modelPreference,
                effort: document.effort,
                background: document.background,
                omitMainContext: document.omitMainContext,
                initialPrompt: document.initialPrompt,
                criticalReminder: document.criticalReminder,
                color: document.color,
                disallowedToolNames: document.disallowedToolNames,
                isOneShot: document.isOneShot
            )
        }
    }

    private static func makeGrant(from toolGroupName: String) throws -> ToolGrant {
        switch toolGroupName {
        case "read_only_editor":
            return .init(toolGroupID: .readOnlyEditor, accessMode: .readOnly, allowedContexts: [.subagent])
        case "read_write_editor":
            return .init(toolGroupID: .readWriteEditor, accessMode: .readWrite, allowedContexts: [.subagent])
        case "web":
            return .init(toolGroupID: .web, allowedContexts: [.subagent])
        case "shell":
            return .init(toolGroupID: .shell, allowedContexts: [.subagent])
        default:
            throw AgentValidationError.unknownToolGroup(toolGroupName)
        }
    }
}