import Foundation
import Testing
@testable import agentGui

@MainActor
struct LSPProjectFileIndexerTests {

    @Test func indexerReturnsProjectLanguageFilesAcrossWorkspace() throws {
        let workspaceRoot = try makeWorkspace(files: [
            "src/app.ts": "const answer: number = 42\n",
            "src/view.tsx": "export const View = () => null\n",
            "tools/script.py": "print('hi')\n",
            "docs/readme.md": "# ignored\n"
        ])
        let registry = try LSPServerRegistry(settings: .testFixture())
        let indexer = LSPProjectFileIndexer()

        let indexed = indexer.indexFiles(in: workspaceRoot.path, registry: registry)

        #expect(indexed["typescript-language-server"]?.sorted() == [
            workspaceRoot.appendingPathComponent("src/app.ts").path,
            workspaceRoot.appendingPathComponent("src/view.tsx").path
        ])
        #expect(indexed["python-lsp"] == [
            workspaceRoot.appendingPathComponent("tools/script.py").path
        ])
        #expect(indexed["swift-sourcekit-lsp"] == nil)
    }

    @Test func indexerSkipsUnsupportedAndHiddenFiles() throws {
        let workspaceRoot = try makeWorkspace(files: [
            ".build/cache.ts": "ignored\n",
            "Package.swift": "// ignored for V1\n",
            "README.md": "ignored\n"
        ])
        let registry = try LSPServerRegistry(settings: .testFixture())
        let indexer = LSPProjectFileIndexer()

        let indexed = indexer.indexFiles(in: workspaceRoot.path, registry: registry)

        #expect(indexed.isEmpty)
    }

    private func makeWorkspace(files: [String: String]) throws -> URL {
        let workspaceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)

        for (relativePath, contents) in files {
            let fileURL = workspaceRoot.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: fileURL, atomically: true, encoding: .utf8)
        }

        return workspaceRoot
    }
}