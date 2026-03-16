import Foundation
import Testing
@testable import agentGui

struct TerminalTranscriptStoreTests {

    @Test func transcriptStoreReturnsLatestLines() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = TerminalTranscriptStore(baseDirectory: directory)
        let taskId = "task-1"

        try store.createTranscript(taskId: taskId)
        try store.append("one\ntwo\nthree\n", to: taskId)

        let tail = try store.readTail(taskId: taskId, lineCount: 2)

        #expect(tail == "two\nthree")
        #expect(store.transcriptURL(taskId: taskId).pathExtension == "log")
    }

    @Test func transcriptStorePreservesTranscriptAfterMultipleAppends() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = TerminalTranscriptStore(baseDirectory: directory)
        let taskId = "task-2"

        try store.createTranscript(taskId: taskId)
        try store.append("alpha\n", to: taskId)
        try store.append("beta\ngamma\n", to: taskId)

        let tail = try store.readTail(taskId: taskId, lineCount: 3)

        #expect(tail == "alpha\nbeta\ngamma")
    }
}