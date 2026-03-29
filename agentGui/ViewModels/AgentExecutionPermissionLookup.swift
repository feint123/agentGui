import Foundation

@MainActor
enum AgentExecutionPermissionLookup {
    static func pendingRequests(
        for flow: AgentMessageFlowSnapshot,
        permissionCenter: ACPPermissionCenter
    ) -> [ACPPermissionCenter.PendingRequest] {
        let toolCalls = flow.steps.compactMap { step -> ToolStepPresentation? in
            guard case .tool(let presentation) = step else {
                return nil
            }

            return presentation
        }

        var seenRequestIDs: Set<String> = []

        return toolCalls.reversed().compactMap { toolCall in
            guard let localSessionID = toolCall.localSessionID,
                  let request = permissionCenter.pendingRequest(
                      localSessionID: localSessionID,
                      toolCallID: toolCall.permissionLookupToolCallID
                  ),
                  seenRequestIDs.insert(request.id).inserted else {
                return nil
            }

            return request
        }
    }
}