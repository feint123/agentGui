import Foundation
import Testing
@testable import agentGui

@MainActor
struct ReflectionMemoryWriteTests {
    @Test func reflectionFailureWritesRMSSessionRecordsIntoUnifiedStore() async throws {
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

        #expect(persisted.contains {
            $0.title == "tool:bash" &&
            $0.tags.contains("reflection-failure") &&
            $0.verificationStatus == .failed
        })
        #expect(persisted.contains {
            $0.title == "Reflection fix: Run xcodebuild -list" &&
            $0.tags.contains("reflection-fix")
        })
        #expect(persisted.contains {
            $0.title == "Reflection fix: Check the active scheme" &&
            $0.tags.contains("reflection-fix")
        })
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}