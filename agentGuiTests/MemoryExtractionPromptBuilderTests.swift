import XCTest
@testable import agentGui

final class MemoryExtractionPromptBuilderTests: XCTestCase {

    func test_build_containsMessageCountHint() {
        let prompt = MemoryExtractionPromptBuilder.build(
            newMessageCount: 12,
            existingInsights: []
        )
        XCTAssertTrue(prompt.contains("12"), "Prompt should reference the message count")
    }

    func test_build_containsMemoryWriteToolName() {
        let prompt = MemoryExtractionPromptBuilder.build(
            newMessageCount: 4,
            existingInsights: []
        )
        XCTAssertTrue(prompt.contains("memory_write"), "Prompt must mention the write tool")
    }

    func test_build_containsAllFourSemanticTypes() {
        let prompt = MemoryExtractionPromptBuilder.build(
            newMessageCount: 4,
            existingInsights: []
        )
        for typeName in ["user", "feedback", "project", "reference"] {
            XCTAssertTrue(prompt.contains(typeName), "Prompt must describe semantic type: \(typeName)")
        }
    }

    func test_build_containsWhatNotToSaveSection() {
        let prompt = MemoryExtractionPromptBuilder.build(
            newMessageCount: 4,
            existingInsights: []
        )
        XCTAssertTrue(
            prompt.lowercased().contains("not") && prompt.lowercased().contains("save"),
            "Prompt must include what-not-to-save guidance"
        )
    }

    func test_build_withExistingInsights_includesTheirSummaries() {
        let insight = RMSInsight.constraint(
            id: "c1",
            summary: "Always inspect before editing",
            appliesWhen: "coding",
            changesDecision: "inspect first"
        )
        let prompt = MemoryExtractionPromptBuilder.build(
            newMessageCount: 4,
            existingInsights: [insight]
        )
        XCTAssertTrue(prompt.contains("Always inspect before editing"))
    }

    func test_build_withNoExistingInsights_hasNoExistingSection() {
        let prompt = MemoryExtractionPromptBuilder.build(
            newMessageCount: 4,
            existingInsights: []
        )
        XCTAssertFalse(prompt.contains("Existing memories"))
    }
}
