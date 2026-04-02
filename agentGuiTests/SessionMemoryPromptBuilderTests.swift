import XCTest
@testable import agentGui

final class SessionMemoryPromptBuilderTests: XCTestCase {

    func test_defaultTemplate_containsAllTenSections() {
        let template = SessionMemoryPromptBuilder.defaultTemplate
        let expectedSections = [
            "# Session Title",
            "# Current State",
            "# Task specification",
            "# Files and Functions",
            "# Workflow",
            "# Errors & Corrections",
            "# Codebase and System Documentation",
            "# Learnings",
            "# Key results",
            "# Worklog"
        ]
        for section in expectedSections {
            XCTAssertTrue(template.contains(section), "Template missing: \(section)")
        }
    }

    func test_buildUpdatePrompt_containsNotesPath() {
        let prompt = SessionMemoryPromptBuilder.buildUpdatePrompt(
            currentNotes: "# Session Title\n_placeholder_",
            notesPath: "/path/to/summary.md"
        )
        XCTAssertTrue(prompt.contains("/path/to/summary.md"))
    }

    func test_buildUpdatePrompt_containsCurrentNotesContent() {
        let currentNotes = "# Session Title\n_placeholder_\n\nSome existing content"
        let prompt = SessionMemoryPromptBuilder.buildUpdatePrompt(
            currentNotes: currentNotes,
            notesPath: "/tmp/summary.md"
        )
        XCTAssertTrue(prompt.contains("Some existing content"))
    }

    func test_buildUpdatePrompt_instructsParallelEdits() {
        let prompt = SessionMemoryPromptBuilder.buildUpdatePrompt(
            currentNotes: "",
            notesPath: "/tmp/summary.md"
        )
        XCTAssertTrue(prompt.contains("parallel") || prompt.contains("single message"))
    }

    func test_buildUpdatePrompt_prohibitsModifyingSectionHeaders() {
        let prompt = SessionMemoryPromptBuilder.buildUpdatePrompt(
            currentNotes: "",
            notesPath: "/tmp/summary.md"
        )
        XCTAssertTrue(prompt.contains("NEVER modify") || prompt.contains("section headers"))
    }

    func test_loadCustomTemplate_returnsDefaultWhenFileAbsent() async {
        let nonExistentDir = URL(fileURLWithPath: "/tmp/nonexistent-agentgui-\(UUID().uuidString)")
        let template = await SessionMemoryPromptBuilder.loadTemplate(configDir: nonExistentDir)
        XCTAssertEqual(template, SessionMemoryPromptBuilder.defaultTemplate)
    }

    func test_loadCustomTemplate_loadsFromFile() async throws {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sm-template-test-\(UUID().uuidString)", isDirectory: true)
        let configPath = tmpDir
            .appendingPathComponent("session-memory", isDirectory: true)
            .appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: configPath, withIntermediateDirectories: true)
        let templateURL = configPath.appendingPathComponent("template.md")
        try "# Custom Template\n_my section_".write(to: templateURL, atomically: true, encoding: .utf8)

        let template = await SessionMemoryPromptBuilder.loadTemplate(configDir: tmpDir)
        XCTAssertEqual(template, "# Custom Template\n_my section_")
    }
}
