import Foundation
import Testing
@testable import agentGui

struct RMSInsightStoreTests {

    @Test func storeLoadsOnlyRequestedScopes() throws {
        let store = RMSInsightStore(baseDirectory: try makeTemporaryDirectory())
        try store.upsert(.constraint(
            id: "user-constraint",
            summary: "Inspect before editing",
            appliesWhen: "coding",
            changesDecision: "block speculative edits",
            scope: .user
        ))
        try store.upsert(.tactic(
            id: "session-tactic",
            summary: "Run targeted xcodebuild test first",
            appliesWhen: "xcodebuild",
            changesDecision: "narrow verification scope",
            scope: .session(id: "s1")
        ))
        try store.upsert(.constraint(
            id: "other-session",
            summary: "Unrelated session guidance",
            appliesWhen: "coding",
            changesDecision: "ignore",
            scope: .session(id: "s2")
        ))

        let loaded = try store.load(scopes: [.user, .session(id: "s1")])

        #expect(loaded.map(\.id).sorted() == ["session-tactic", "user-constraint"])
    }

    @Test func storeRemovesInsightByIdentifier() throws {
        let store = RMSInsightStore(baseDirectory: try makeTemporaryDirectory())
        try store.upsert(.constraint(
            id: "constraint-1",
            summary: "Inspect before editing",
            appliesWhen: "coding",
            changesDecision: "block speculative edits",
            scope: .user
        ))

        try store.remove(id: "constraint-1")

        #expect(try store.load(scopes: [.user]).isEmpty)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}