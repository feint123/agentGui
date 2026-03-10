import Foundation
import Testing
@testable import agentGui

@MainActor
struct TaskMemoryPromptRendererTests {
    @Test func rendererGroupsTaskRecordsIntoTaskMemorySections() async throws {
        let records = [
            MemoryRecord.fixture(
                layer: .task,
                kind: .working,
                scope: .session(id: "s1"),
                title: "Build uses xcodebuild",
                summary: "Build uses xcodebuild",
                source: .taskMemory,
                tags: ["confirmed-fact"]
            ),
            MemoryRecord.fixture(
                layer: .task,
                kind: .working,
                scope: .session(id: "s1"),
                title: "Run tests",
                summary: "Scheme missing",
                payload: .structured(["action": "Run tests", "reason": "Scheme missing"]),
                source: .taskMemory,
                verificationStatus: .failed,
                tags: ["failed-attempt"]
            )
        ]

        let text = TaskMemoryPromptRenderer().render(records: records)

        #expect(text.contains("## Confirmed Facts"))
        #expect(text.contains("## Failed Attempts"))
        #expect(text.contains("Build uses xcodebuild"))
        #expect(text.contains("Scheme missing"))
    }
}