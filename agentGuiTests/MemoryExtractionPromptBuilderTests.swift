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

    func test_build_withNonEmptyManifest_containsManifestSection() {
        let manifest = "- [user] swift_preferences.md (2026-04-03T10:00:00Z): Prefers bun over npm"
        let prompt = MemoryExtractionPromptBuilder.build(
            newMessageCount: 5,
            existingMemoriesManifest: manifest
        )
        XCTAssertTrue(prompt.contains("Existing memory files"),
                      "Prompt must contain manifest section header when manifest is non-empty")
        XCTAssertTrue(prompt.contains(manifest),
                      "Prompt must embed the manifest verbatim")
    }

    func test_build_withEmptyManifest_omitsManifestSection() {
        let prompt = MemoryExtractionPromptBuilder.build(
            newMessageCount: 5,
            existingMemoriesManifest: ""
        )
        XCTAssertFalse(prompt.contains("Existing memory files"),
                       "Prompt must NOT contain manifest section when manifest is empty")
    }

    func test_build_doesNotContainSemanticTypeFieldName() {
        // M-04 使用 'type' 字段，不是 'semantic_type'
        let prompt = MemoryExtractionPromptBuilder.build(newMessageCount: 4)
        XCTAssertFalse(prompt.contains("semantic_type"),
                       "Prompt must not reference the old semantic_type field — use 'type' instead")
    }

    func test_build_memoryWriteDescribesFileWrite() {
        let prompt = MemoryExtractionPromptBuilder.build(newMessageCount: 4)
        XCTAssertTrue(prompt.contains("MEMORY.md"),
                      "Prompt should clarify that memory_write updates MEMORY.md automatically")
    }
}
