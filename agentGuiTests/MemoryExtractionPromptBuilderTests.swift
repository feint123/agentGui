import XCTest
@testable import agentGui

final class MemoryExtractionPromptBuilderTests: XCTestCase {

    func test_build_containsMessageCountHint() {
        let prompt = MemoryExtractionPromptBuilder.build(
            newMessageCount: 12
        )
        XCTAssertTrue(prompt.contains("12"), "Prompt should reference the message count")
    }

    func test_build_containsMemoryWriteToolName() {
        let prompt = MemoryExtractionPromptBuilder.build(
            newMessageCount: 4
        )
        XCTAssertTrue(prompt.contains("memory_write"), "Prompt must mention the write tool")
    }

    func test_build_containsAllFourSemanticTypes() {
        let prompt = MemoryExtractionPromptBuilder.build(
            newMessageCount: 4
        )
        for typeName in ["user", "feedback", "project", "reference"] {
            XCTAssertTrue(prompt.contains(typeName), "Prompt must describe semantic type: \(typeName)")
        }
    }

    func test_build_containsWhatNotToSaveSection() {
        let prompt = MemoryExtractionPromptBuilder.build(
            newMessageCount: 4
        )
        XCTAssertTrue(
            prompt.lowercased().contains("not") && prompt.lowercased().contains("save"),
            "Prompt must include what-not-to-save guidance"
        )
    }
}
