import Foundation
import Testing
@testable import agentGui

@MainActor
struct ToolPayloadStoreTests {

    @Test func createAndReadPayloadByCharactersAndLines() async throws {
        let baseDirectory = try makeTemporaryDirectory()
        let store = ToolPayloadStore(baseDirectory: baseDirectory, now: { Date(timeIntervalSince1970: 100) })
        let payload = try await store.createPayload(
            text: "alpha\nbeta\ngamma\ndelta",
            sourceKind: .file,
            sourceDescriptor: "/tmp/sample.txt",
            ttl: 60
        )

        let chars = try await store.readChars(payloadID: payload.payloadID, start: 1, end: 5)
        let lines = try await store.readLines(payloadID: payload.payloadID, start: 2, end: 3)

        #expect(chars == "alpha")
        #expect(lines == "2\tbeta\n3\tgamma")
    }

    @Test func invalidRangeThrowsError() async throws {
        let baseDirectory = try makeTemporaryDirectory()
        let store = ToolPayloadStore(baseDirectory: baseDirectory)
        let payload = try await store.createPayload(
            text: "alpha\nbeta",
            sourceKind: .file,
            sourceDescriptor: "/tmp/sample.txt"
        )

        await #expect(throws: ToolPayloadStoreError.invalidRange("chars 5-2")) {
            _ = try await store.readChars(payloadID: payload.payloadID, start: 5, end: 2)
        }
    }

    @Test func expiredPayloadThrowsError() async throws {
        let baseDirectory = try makeTemporaryDirectory()
        let store = ToolPayloadStore(baseDirectory: baseDirectory, now: { Date(timeIntervalSince1970: 100) })
        let payload = try await store.createPayload(
            text: "alpha",
            sourceKind: .bash,
            sourceDescriptor: "echo alpha",
            ttl: 1
        )

        let expiredStore = ToolPayloadStore(baseDirectory: baseDirectory, now: { Date(timeIntervalSince1970: 200) })

        await #expect(throws: ToolPayloadStoreError.payloadExpired(payload.payloadID)) {
            _ = try await expiredStore.readChars(payloadID: payload.payloadID, start: 1, end: 1)
        }
    }

    @Test func linesCursorCanBeReusedForNextWindow() async throws {
        let baseDirectory = try makeTemporaryDirectory()
        let store = ToolPayloadStore(baseDirectory: baseDirectory)
        let payload = try await store.createPayload(
            text: (1...6).map { "line \($0)" }.joined(separator: "\n"),
            sourceKind: .file,
            sourceDescriptor: "/tmp/sample.txt"
        )

        let first = try await store.readWindow(
            payloadID: payload.payloadID,
            readMode: .lines,
            start: 2,
            end: 3,
            cursor: nil,
            maxChars: nil
        )
        let second = try await store.readWindow(
            payloadID: payload.payloadID,
            readMode: .lines,
            start: nil,
            end: nil,
            cursor: first.nextCursor,
            maxChars: nil
        )

        #expect(first.nextCursor == "lines:4-5")
        #expect(second.rangeSummary == "lines 4-5 of 6")
        #expect(second.content == "4\tline 4\n5\tline 5")
    }

    @Test func charsCursorCanBeReusedForNextWindow() async throws {
        let baseDirectory = try makeTemporaryDirectory()
        let store = ToolPayloadStore(baseDirectory: baseDirectory)
        let payload = try await store.createPayload(
            text: "abcdefghijkl",
            sourceKind: .file,
            sourceDescriptor: "/tmp/sample.txt"
        )

        let first = try await store.readWindow(
            payloadID: payload.payloadID,
            readMode: .chars,
            start: 2,
            end: 5,
            cursor: nil,
            maxChars: nil
        )
        let second = try await store.readWindow(
            payloadID: payload.payloadID,
            readMode: .chars,
            start: nil,
            end: nil,
            cursor: first.nextCursor,
            maxChars: nil
        )

        #expect(first.nextCursor == "chars:6-9")
        #expect(second.rangeSummary == "chars 6-9 of 12")
        #expect(second.content == "fghi")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}