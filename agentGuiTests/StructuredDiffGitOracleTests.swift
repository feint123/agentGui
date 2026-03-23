import Foundation
import Testing
@testable import agentGui

struct StructuredDiffGitOracleTests {
    @Test func engineRoughlyMatchesGitForSeparatedEdits() throws {
        guard isGitAvailable() else {
            return
        }

        let root = try makeTemporaryDirectory()
        let oldURL = root.appending(path: "old.txt")
        let newURL = root.appending(path: "new.txt")
        let oldText = ["a", "b", "c", "d", "e", "f", "g", "h"].joined(separator: "\n")
        let newText = ["a", "b2", "c", "d", "e", "f", "g2", "h"].joined(separator: "\n")

        try oldText.write(to: oldURL, atomically: true, encoding: .utf8)
        try newText.write(to: newURL, atomically: true, encoding: .utf8)

        let diff = try StructuredDiffEngine().build(
            relativePath: "sample.txt",
            absolutePath: oldURL.path,
            kind: .modify,
            baseContent: oldText,
            stagedContent: newText,
            contextLines: 1,
            interHunkContext: 0
        )
        let rendered = UnifiedDiffSerializer.serialize(diff)
        let gitOutput = try runGitNoIndexDiff(oldURL: oldURL, newURL: newURL)

        let renderedHunkCount = rendered.components(separatedBy: "@@").count / 2
        let gitHunkCount = gitOutput.components(separatedBy: "@@").count / 2

        #expect(diff.summary.additions == 2)
        #expect(diff.summary.deletions == 2)
        #expect(rendered.contains("+b2"))
        #expect(rendered.contains("+g2"))
        #expect(renderedHunkCount == gitHunkCount)
    }

    private func runGitNoIndexDiff(oldURL: URL, newURL: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "diff", "--no-index", "--unified=1", "--no-color", oldURL.path, newURL.path]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 || process.terminationStatus == 1 else {
            throw GitOracleError.commandFailed(err.isEmpty ? out : err)
        }
        return out
    }

    private func isGitAvailable() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "--version"]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private enum GitOracleError: Error {
    case commandFailed(String)
}