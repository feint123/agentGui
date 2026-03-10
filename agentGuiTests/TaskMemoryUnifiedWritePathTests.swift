import Foundation
import Testing
@testable import agentGui

@MainActor
struct TaskMemoryUnifiedWritePathTests {
    @Test func extractedTaskMemoryPersistsSessionRecordsIntoUnifiedStore() async throws {
        let service = ClaudeService()
        let baseDirectory = try makeTemporaryDirectory()
        let store = UnifiedMemoryFileStoreAdapter(baseDirectory: baseDirectory)

        var memory = TaskMemory(sessionId: "")
        memory.confirmedFacts = ["Build uses xcodebuild"]
        memory.failedAttempts = [FailedAttempt(action: "Run tests", reason: "Scheme missing")]

        try service.persistTaskMemoryExtraction(
            sessionId: "session-1",
            extracted: memory,
            store: store,
            timestamp: Date(timeIntervalSince1970: 100)
        )

        let persisted = try store.records(for: .session(id: "session-1"), includeArchived: true)

        #expect(persisted.contains { $0.title == "Build uses xcodebuild" && $0.tags.contains("confirmed-fact") })
        #expect(persisted.contains { $0.title == "Run tests" && $0.tags.contains("failed-attempt") })
    }

    @Test func reflectionFailureWritesFailedAttemptAndSuggestedFixesIntoUnifiedStore() async throws {
        let service = ClaudeService()
        let baseDirectory = try makeTemporaryDirectory()
        let store = UnifiedMemoryFileStoreAdapter(baseDirectory: baseDirectory)

        try service.recordReflectionFailure(
            sessionId: "session-2",
            trigger: FailureTrigger.toolFailure(toolName: "bash", errorText: "command failed"),
            concerns: ["Tests failed", "Build script missing"],
            suggestedFixes: ["Run xcodebuild -list", "Check the active scheme"],
            store: store,
            timestamp: Date(timeIntervalSince1970: 200)
        )

        let persisted = try store.records(for: .session(id: "session-2"), includeArchived: true)

        #expect(persisted.contains { $0.title == "tool:bash" && $0.tags.contains("failed-attempt") })
        #expect(persisted.contains { $0.title == "Reflection fix: Run xcodebuild -list" && $0.tags.contains("attempt") })
        #expect(persisted.contains { $0.title == "Reflection fix: Check the active scheme" && $0.tags.contains("attempt") })
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}