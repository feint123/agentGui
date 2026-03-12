import Foundation
import Testing
@testable import agentGui

@MainActor
struct ToolResultBudgetControllerTests {

    @Test func oversizedResultFallsBackToReferencedMode() throws {
        let controller = ToolResultBudgetController()
        let decision = controller.decide(
            rawText: String(repeating: "A", count: 20_000),
            sourceKind: .bash,
            roundInjectedChars: 1_000,
            reservedResponseTokens: 4_096
        )

        #expect(decision.mode == .referenced)
        #expect((decision.preview?.count ?? 0) < 2_000)
        #expect(decision.shouldPersistPayload)
    }

    @Test func mediumResultFallsBackToPreviewWhenRoundBudgetAllows() throws {
        let controller = ToolResultBudgetController()
        let decision = controller.decide(
            rawText: String(repeating: "B", count: 4_000),
            sourceKind: .webFetch,
            roundInjectedChars: 1_000,
            reservedResponseTokens: 4_096
        )

        #expect(decision.mode == .preview)
        #expect(!decision.shouldPersistPayload)
        #expect((decision.preview?.count ?? 0) < 4_000)
    }

    @Test func accumulatedRoundBudgetCanForceReferencedMode() throws {
        let controller = ToolResultBudgetController()
        let decision = controller.decide(
            rawText: String(repeating: "C", count: 3_000),
            sourceKind: .file,
            roundInjectedChars: 20_000,
            reservedResponseTokens: 4_096
        )

        #expect(decision.mode == .referenced)
        #expect(decision.injectedCharCount < decision.rawCharCount)
    }
}