import Foundation
import Testing
@testable import agentGui

struct WorkspaceFileSearchIndexTests {
    @Test func searchScopesToWorkingDirectory() throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let nestedDirectory = rootURL.appendingPathComponent("Sources/App", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        try "print(1)".write(to: nestedDirectory.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        try "# Demo".write(to: rootURL.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        let index = WorkspaceFileSearchIndex()
        let results = try index.search(query: "main", rootURL: rootURL)

        #expect(results.map(\.relativePath) == ["Sources/App/main.swift"])

        try? FileManager.default.removeItem(at: rootURL)
    }
}