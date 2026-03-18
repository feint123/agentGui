import Foundation
import SwiftAnthropic

struct AuthorizedToolsetProjector {
    let registry: any ToolRegistry

    init(registry: any ToolRegistry = DefaultToolRegistry()) {
        self.registry = registry
    }

    func definitions(from snapshot: EffectiveToolAuthorizationSnapshot) -> [ToolDefinition] {
        snapshot.allowedToolIDs.sorted().compactMap { registry.definition(for: $0) }
    }

    func tools(from snapshot: EffectiveToolAuthorizationSnapshot, context: ToolDefinitionBuildContext = .default) -> [MessageParameter.Tool] {
        definitions(from: snapshot).map { $0.makeAnthropicTool(context: context) }
    }
}
