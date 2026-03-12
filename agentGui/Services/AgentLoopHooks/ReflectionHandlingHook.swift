import Foundation

struct ReflectionHandlingHook: AgentLoopHook {
    let id = "reflection-handling"
    let order = 50
    let kind: AgentLoopHookKind = .mutator
    let isRequired = false

    let resolver: (AgentLoopHookContext) async throws -> AgentLoopReflectionResolution?

    func supports(_ stage: AgentLoopHookStage) -> Bool {
        stage == .processReflection
    }

    func perform(stage: AgentLoopHookStage, context: AgentLoopHookContext) async throws -> AgentLoopHookResult {
        guard stage == .processReflection,
              let resolution = try await resolver(context) else {
            return .continue
        }
        return .reflection(resolution)
    }
}