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
        let registry = try LSPServerRegistry(settings: .lspFixture(installedProviderIDs: ["typescript-language-server"]))
        let indexer = LSPProjectFileIndexer()

        let indexed = indexer.indexFiles(in: workspaceRoot.path, registry: registry)

        #expect(indexed["typescript-language-server"]?.sorted() == [
            workspaceRoot.appendingPathComponent("src/app.ts").path,
            workspaceRoot.appendingPathComponent("src/view.tsx").path
        ])
        #expect(indexed["python-lsp"] == [
            workspaceRoot.appendingPathComponent("tools/script.py").path
        ])
    }

    @Test func indexerSkipsUnsupportedAndHiddenFiles() throws {
        let workspaceRoot = try makeWorkspace(files: [
            ".build/cache.ts": "ignored\n",
            "Package.swift": "// ignored for V1\n",
            "README.md": "ignored\n"
        ])
        let registry = try LSPServerRegistry(settings: .lspFixture(installedProviderIDs: ["typescript-language-server"]))
        let indexer = LSPProjectFileIndexer()

        let indexed = indexer.indexFiles(in: workspaceRoot.path, registry: registry)

        #expect(indexed.isEmpty)
    }

    @Test func indexerIncludesInstalledGoAndClangFiles() throws {
        let workspaceRoot = try makeWorkspace(files: [
            "cmd/main.go": "package main\n",
            "native/app.cpp": "int main() { return 0; }\n",
            "native/header.h": "#pragma once\n"
        ])
        let registry = try LSPServerRegistry(settings: .lspFixture(installedProviderIDs: [
            "gopls",
            "clangd"
        ]))
        let indexer = LSPProjectFileIndexer()

        let indexed = indexer.indexFiles(in: workspaceRoot.path, registry: registry)

        #expect(indexed["gopls"] == [
            workspaceRoot.appendingPathComponent("cmd/main.go").path
        ])
        #expect(indexed["clangd"]?.sorted() == [
            workspaceRoot.appendingPathComponent("native/app.cpp").path,
            workspaceRoot.appendingPathComponent("native/header.h").path
        ])
    }

    @Test func indexerSkipsPythonVirtualEnvironmentPackages() throws {
        let workspaceRoot = try makeWorkspace(files: [
            "src/main.py": "print('app')\n",
            "venv/lib/python3.13/site-packages/pkg/module.py": "print('dependency')\n",
            "env/lib/python3.13/site-packages/other/module.py": "print('dependency')\n",
            "vendor/dist-packages/tool.py": "print('dependency')\n"
        ])
        let registry = try LSPServerRegistry(settings: .testFixture())
        let indexer = LSPProjectFileIndexer()

        let indexed = indexer.indexFiles(in: workspaceRoot.path, registry: registry)

        #expect(indexed["python-lsp"] == [
            workspaceRoot.appendingPathComponent("src/main.py").path
        ])
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