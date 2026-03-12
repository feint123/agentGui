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

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}