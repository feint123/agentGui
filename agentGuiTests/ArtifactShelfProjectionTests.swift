import Foundation
import Testing
@testable import agentGui

@MainActor
struct ArtifactShelfProjectionTests {

    @Test func projectionClassifiesReferencedArtifactsAndCommands() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let fileURL = root.appending(path: "README.md").standardizedFileURL
        FileManager.default.createFile(atPath: fileURL.path, contents: Data("# Demo".utf8))

        let folderURL = root.appending(path: "docs", directoryHint: .isDirectory).standardizedFileURL
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

        let message = Message.agentMessage(text: nil, session: Session(title: "Artifact Projection"))
        let round = AgentRound(roundIndex: 0, message: message)

        let edit = ToolCall(toolCallId: "edit-1", kind: .edit, message: message, agentRound: round)
        edit.filePath = fileURL.path
        edit.status = .success

        let readFile = ToolCall(toolCallId: "read-file", kind: .read, message: message, agentRound: round)
        readFile.filePath = fileURL.path
        readFile.status = .success

        let readFolder = ToolCall(toolCallId: "read-folder", kind: .read, message: message, agentRound: round)
        readFolder.filePath = folderURL.path
        readFolder.status = .success

        let fetchURL = ToolCall(toolCallId: "fetch-url", kind: .fetch, message: message, agentRound: round)
        fetchURL.filePath = "https://example.com/spec"
        fetchURL.status = .success

        let execute = ToolCall(toolCallId: "exec-1", kind: .execute, message: message, agentRound: round)
        execute.title = "xcodebuild test"
        execute.status = .success

        round.toolCalls = [edit, readFile, readFolder, fetchURL, execute]
        message.agentRounds = [round]
        message.status = .completed

        let projection = AgentExecutionProjection.make(for: message)

        #expect(projection.artifacts.changedFiles.count == 1)
        #expect(projection.artifacts.referencedFiles.count == 3)
        #expect(projection.artifacts.commandSummaries.map(\.text) == ["xcodebuild test"])
        #expect(projection.artifacts.changedFiles.first?.kind == .localFile(fileURL))
        #expect(projection.artifacts.referencedFiles.contains { $0.kind == .localFolder(folderURL) })
        #expect(projection.artifacts.referencedFiles.contains { $0.kind == .webURL(URL(string: "https://example.com/spec")!) })
    }

    @Test func projectionDeduplicatesArtifactsByPath() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let fileURL = root.appending(path: "ChatView.swift").standardizedFileURL
        FileManager.default.createFile(atPath: fileURL.path, contents: Data("struct Demo {}".utf8))

        let message = Message.agentMessage(text: nil, session: Session(title: "Artifact Dedup"))
        let round = AgentRound(roundIndex: 0, message: message)

        let firstRead = ToolCall(toolCallId: "read-1", kind: .read, message: message, agentRound: round)
        firstRead.filePath = fileURL.path
        firstRead.status = .success

        let secondRead = ToolCall(toolCallId: "read-2", kind: .read, message: message, agentRound: round)
        secondRead.filePath = fileURL.path
        secondRead.status = .success

        round.toolCalls = [firstRead, secondRead]
        message.agentRounds = [round]
        message.status = .completed

        let projection = AgentExecutionProjection.make(for: message)

        #expect(projection.artifacts.referencedFiles.count == 1)
        #expect(projection.artifacts.referencedFiles.first?.displayName == "ChatView.swift")
    }
}