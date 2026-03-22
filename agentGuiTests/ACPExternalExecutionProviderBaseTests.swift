import Foundation
import Testing
@testable import agentGui

enum ExternalACPProviderAssertionHelpers {
    static func expectLiveTurnProjection(
        assistantMessage: Message,
        toolCalls: [ToolCall],
        expectedText: String,
        expectedToolCallID: String,
        expectedToolTitle: String,
        expectedToolOutput: String
    ) {
        #expect(assistantMessage.textContent == expectedText)
        #expect(toolCalls.count == 1)
        #expect(toolCalls.first?.toolCallId == expectedToolCallID)
        #expect(toolCalls.first?.title == expectedToolTitle)
        #expect(toolCalls.first?.terminalOutput == expectedToolOutput)
    }

    static func expectCancelledMessageSettlesToolCalls(_ message: Message) {
        #expect(message.status == .cancelled)

        let roundCalls = message.agentRounds.flatMap(\.toolCalls)
        let directCalls = message.toolCalls.filter { $0.agentRound == nil }
        let allToolCalls = roundCalls + directCalls

        #expect(allToolCalls.allSatisfy { $0.status != .inProgress })
    }
}
