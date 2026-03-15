import Foundation
import Testing
@testable import agentGui

@MainActor
struct ReleaseScenarioTests {

    @Test func configuredAPIKeyScenarioProvidesUsableConnectionSettings() async throws {
        let harness = try InMemoryAppHarness.makeConfiguredSettingsScenario()

        #expect(harness.settings.apiKey == "sk-ant-release-test")
        #expect(!harness.settings.selectedModel.isEmpty)
    }

    @Test func conversationScenarioPersistsSessionAndMessages() async throws {
        let harness = try InMemoryAppHarness.makeConversationScenario()

        #expect(harness.session.messageCount == 2)
        #expect(harness.session.messages.contains { $0.direction == .user && $0.textContent == "Run the release checks" })
        #expect(harness.session.messages.contains { $0.direction == .agent && $0.textContent == "Release checklist prepared." })
    }

    @Test func toolCallScenarioProducesVisiblePresentationData() async throws {
        let harness = try InMemoryAppHarness.makeToolCallScenario()
        let toolCall = try #require(harness.session.messages.flatMap(\Message.toolCalls).first)

        let row = ToolCallRowPresentation.make(for: toolCall, isExpanded: true)

        #expect(row.style == .read)
        #expect(row.primaryText == "ReleaseChecklist.md")
        #expect(row.detailText == "Release checklist contents")
    }

    @Test func bashTaskScenarioPreservesRecoverableExecutionSummary() async throws {
        let harness = try InMemoryAppHarness.makeBashTaskScenario()
        let toolCall = try #require(harness.session.messages.flatMap(\Message.toolCalls).first)

        let row = ToolCallRowPresentation.make(for: toolCall, isExpanded: true)

        #expect(row.style == .execute)
        #expect(row.statusText == "后台运行中")
        #expect(row.tertiaryText == "waiting for tests")
    }

    @Test func recoveryScenarioFindsInterruptedWorkflowAndPendingMessage() async throws {
        let harness = try InMemoryAppHarness.makeRecoveryScenario()

        let summary = try harness.runtimeRecoveryService.loadRecoverySummary(from: harness.context)

        #expect(summary.items.count == 2)
        #expect(summary.items.contains { $0.sourceKind == .workflow })
        #expect(summary.items.contains { $0.sourceKind == .messageGeneration })
    }
}