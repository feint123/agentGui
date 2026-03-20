import Foundation

@MainActor
enum AgentExecutionPermissionLookup {
    static func pendingRequests(
        for flow: AgentMessageFlowSnapshot,
        permissionCenter: ACPPermissionCenter
    ) -> [ACPPermissionCenter.PendingRequest] {
        let toolCalls = flow.steps.compactMap { step -> ToolCall? in
            guard case .tool(let presentation) = step else {
                return nil
            }

            return flow.toolCall(for: presentation.toolCallID)
        }

        var seenRequestIDs: Set<String> = []

        return toolCalls.reversed().compactMap { toolCall in
            guard let localSessionID = toolCall.message?.session?.sessionId,
                  let request = permissionCenter.pendingRequest(
                      localSessionID: localSessionID,
                      toolCallID: toolCall.permissionLookupToolCallId
                  ),
                  seenRequestIDs.insert(request.id).inserted else {
                return nil
            }

            return request
        }
    }
}