import Foundation
import SwiftAnthropic

struct ToolResolutionRequest {
    let context: ToolContext
    let role: WorkflowRoleDefinition?
    let settings: AppSettings
}

struct ToolResolutionResult {
    let tools: [MessageParameter.Tool]
    let resolvedDefinitions: [ToolDefinition]
    let excludedToolIDs: Set<String>

    var toolIDs: Set<String> {
        Set(resolvedDefinitions.map(\.id))
    }
}

protocol ToolsetResolver {
    func resolve(_ request: ToolResolutionRequest) -> ToolResolutionResult
}

struct DefaultToolsetResolver: ToolsetResolver {
    let registry: ToolRegistry

    func resolve(_ request: ToolResolutionRequest) -> ToolResolutionResult {
        let grants = request.role?.toolGrants ?? []
        let toolIDs = expandToolIDs(from: grants, context: request.context)

        var resolvedDefinitions: [ToolDefinition] = []
        var excludedToolIDs: Set<String> = []

        for toolID in toolIDs.sorted() {
            guard let definition = registry.definition(for: toolID) else {
                excludedToolIDs.insert(toolID)
                continue
            }

            guard definition.supportedContexts.contains(request.context) else {
                excludedToolIDs.insert(toolID)
                continue
            }

            guard isEnabled(definition.id, settings: request.settings) else {
                excludedToolIDs.insert(toolID)
                continue
            }

            resolvedDefinitions.append(definition)
        }

        return ToolResolutionResult(
            tools: resolvedDefinitions.map { $0.makeAnthropicTool() },
            resolvedDefinitions: resolvedDefinitions,
            excludedToolIDs: excludedToolIDs
        )
    }

    private func expandToolIDs(from grants: [ToolGrant], context: ToolContext) -> Set<String> {
        var resolvedToolIDs: Set<String> = []

        for grant in grants where grant.allowedContexts.contains(context) {
            if let toolID = grant.toolID {
                resolvedToolIDs.insert(toolID)
            }

            if let toolGroupID = grant.toolGroupID {
                resolvedToolIDs.formUnion(toolIDs(forGroup: toolGroupID))
            }
        }

        return resolvedToolIDs
    }

    private func toolIDs(forGroup groupID: ToolGroupID) -> Set<String> {
        switch groupID {
        case .readOnlyEditor, .readWriteEditor:
            return ["str_replace_based_edit_tool"]
        case .web:
            return ["web_search", "web_fetch"]
        case .shell:
            return ["bash"]
        case .storyMemory:
            return [
                "story_memory_query",
                "story_memory_verify_continuity",
                "story_memory_upsert_character"
            ]
        case .workflowArtifact:
            return []
        }
    }

    private func isEnabled(_ toolID: String, settings: AppSettings) -> Bool {
        switch toolID {
        case "str_replace_based_edit_tool":
            return settings.enableTextEditorTool
        case "bash":
            return settings.enableBashTool
        case "web_search":
            return settings.enableWebSearchTool
        case "web_fetch":
            return settings.enableWebFetchTool
        case "story_memory_query", "story_memory_verify_continuity", "story_memory_upsert_character":
            return settings.enableStoryMemory
        default:
            return true
        }
    }
}