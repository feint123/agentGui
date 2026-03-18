import Foundation

enum ToolRiskTier: String, Codable, Sendable {
    case low
    case medium
    case high
}

struct ToolCapabilityRequirement: Hashable, Sendable {
    let capabilityID: ToolCapabilityID
    let minimumLevel: ToolCapabilityLevel
}

struct ToolAuthorizationDescriptor: Sendable {
    let requirements: [ToolCapabilityRequirement]
    let riskTier: ToolRiskTier

    static let none = ToolAuthorizationDescriptor(requirements: [], riskTier: .low)
}

enum ToolAuthorizationDenialReason: Equatable, Sendable {
    case globallyDisabled
    case subjectPolicyDenied
    case contextUnsupported
    case roleGrantMissing
    case runtimePrerequisiteMissing
}

struct ToolAuthorizationRequest {
    let context: ToolContext
    let role: WorkflowRoleDefinition?
    let settings: AppSettings
    let subjectPolicy: ToolAuthorizationPolicy
    let capabilityCeilings: [ToolCapabilityID: ToolCapabilityLevel]

    init(
        context: ToolContext,
        role: WorkflowRoleDefinition? = nil,
        settings: AppSettings,
        subjectPolicy: ToolAuthorizationPolicy,
        capabilityCeilings: [ToolCapabilityID: ToolCapabilityLevel] = [:]
    ) {
        self.context = context
        self.role = role
        self.settings = settings
        self.subjectPolicy = subjectPolicy
        self.capabilityCeilings = capabilityCeilings
    }
}

struct EffectiveToolAuthorizationSnapshot: Sendable {
    let context: ToolContext
    let allowedToolIDs: Set<String>
    let deniedToolReasons: [String: ToolAuthorizationDenialReason]
    let capabilityLevels: [ToolCapabilityID: ToolCapabilityLevel]

    func level(for capabilityID: ToolCapabilityID) -> ToolCapabilityLevel {
        capabilityLevels[capabilityID] ?? .disabled
    }
}

protocol ToolAuthorizationResolving {
    func resolve(_ request: ToolAuthorizationRequest) -> EffectiveToolAuthorizationSnapshot
}

struct ToolAuthorizationResolver: ToolAuthorizationResolving {
    let registry: any ToolRegistry

    init(registry: any ToolRegistry = DefaultToolRegistry()) {
        self.registry = registry
    }

    func resolve(_ request: ToolAuthorizationRequest) -> EffectiveToolAuthorizationSnapshot {
        let effectiveCapabilityLevels = effectiveCapabilities(for: request)
        let grantedToolIDs = request.role.map { expandToolIDs(from: $0.toolGrants, context: request.context) }

        var allowedToolIDs: Set<String> = []
        var deniedToolReasons: [String: ToolAuthorizationDenialReason] = [:]

        for definition in registry.allDefinitions() {
            if !definition.supportedContexts.contains(request.context) {
                deniedToolReasons[definition.id] = .contextUnsupported
                continue
            }

            if let grantedToolIDs, !grantedToolIDs.contains(definition.id) {
                deniedToolReasons[definition.id] = .roleGrantMissing
                continue
            }

            if !isGloballyEnabled(toolID: definition.id, settings: request.settings) {
                deniedToolReasons[definition.id] = .globallyDisabled
                continue
            }

            let satisfiesRequirements = definition.authorization.requirements.allSatisfy { requirement in
                effectiveCapabilityLevels[requirement.capabilityID, default: .disabled] >= requirement.minimumLevel
            }

            if !satisfiesRequirements {
                deniedToolReasons[definition.id] = .subjectPolicyDenied
                continue
            }

            allowedToolIDs.insert(definition.id)
        }

        return EffectiveToolAuthorizationSnapshot(
            context: request.context,
            allowedToolIDs: allowedToolIDs,
            deniedToolReasons: deniedToolReasons,
            capabilityLevels: effectiveCapabilityLevels
        )
    }

    private func effectiveCapabilities(for request: ToolAuthorizationRequest) -> [ToolCapabilityID: ToolCapabilityLevel] {
        var result = Dictionary(uniqueKeysWithValues: ToolCapabilityID.allCases.map { ($0, request.subjectPolicy.level(for: $0)) })
        for (capabilityID, ceiling) in request.capabilityCeilings {
            result[capabilityID] = ToolCapabilityLevel.min(result[capabilityID, default: .disabled], ceiling)
        }
        return result
    }

    private func expandToolIDs(from grants: [ToolGrant], context: ToolContext) -> Set<String> {
        var resolvedToolIDs: Set<String> = []

        for grant in grants where grant.allowedContexts.contains(context) {
            if let toolID = grant.toolID {
                resolvedToolIDs.insert(toolID)
            }

            if let toolGroupID = grant.toolGroupID {
                switch toolGroupID {
                case .readOnlyEditor, .readWriteEditor:
                    resolvedToolIDs.insert("str_replace_based_edit_tool")
                case .web:
                    resolvedToolIDs.formUnion(["web_search", "web_fetch"])
                case .shell:
                    resolvedToolIDs.insert("bash")
                case .workflowArtifact:
                    break
                }
            }
        }

        return resolvedToolIDs
    }

    private func isGloballyEnabled(toolID: String, settings: AppSettings) -> Bool {
        switch toolID {
        case "str_replace_based_edit_tool":
            return settings.enableTextEditorTool
        case "bash":
            return settings.enableBashTool
        case "web_search":
            return settings.enableWebSearchTool
        case "web_fetch":
            return settings.enableWebFetchTool
        case "lsp_definition", "lsp_references", "lsp_hover", "lsp_document_symbols", "lsp_workspace_symbols", "lsp_diagnostics", "lsp_list_servers", "lsp_server_status":
            return settings.enableLSPTools
        default:
            return true
        }
    }
}
