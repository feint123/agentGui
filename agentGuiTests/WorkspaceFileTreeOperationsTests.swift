import Foundation
import Testing
@testable import agentGui

struct WorkspaceFileTreeOperationsTests {

    @Test func createRenameAndDeleteItemsUnderWorkspaceRoot() throws {
        let rootURL = try makeWorkspaceOperationsTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let folderURL = try WorkspaceFileTreeOperations.createDirectory(named: "Sources", in: rootURL)
        let fileURL = try WorkspaceFileTreeOperations.createFile(named: "Draft.md", in: folderURL)
        let renamedFileURL = try WorkspaceFileTreeOperations.renameItem(at: fileURL, to: "Notes.md")

        #expect(FileManager.default.fileExists(atPath: folderURL.path))
        #expect(FileManager.default.fileExists(atPath: renamedFileURL.path))
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))

        try WorkspaceFileTreeOperations.deleteItem(at: renamedFileURL)
        try WorkspaceFileTreeOperations.deleteItem(at: folderURL)

        #expect(!FileManager.default.fileExists(atPath: renamedFileURL.path))
        #expect(!FileManager.default.fileExists(atPath: folderURL.path))
    }

    @Test func rejectsInvalidOrDuplicateNames() throws {
        let rootURL = try makeWorkspaceOperationsTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        _ = try WorkspaceFileTreeOperations.createFile(named: "README.md", in: rootURL)

        #expect(throws: WorkspaceFileTreeOperationError.self) {
            _ = try WorkspaceFileTreeOperations.createFile(named: "README.md", in: rootURL)
        }

        #expect(throws: WorkspaceFileTreeOperationError.self) {
            _ = try WorkspaceFileTreeOperations.createDirectory(named: "  ", in: rootURL)
        }

        #expect(throws: WorkspaceFileTreeOperationError.self) {
            _ = try WorkspaceFileTreeOperations.renameItem(at: rootURL.appending(path: "README.md"), to: "Nested/Name.md")
        }
    }

    @Test func renameWithUnchangedNameIsANoop() throws {
        let rootURL = try makeWorkspaceOperationsTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let fileURL = try WorkspaceFileTreeOperations.createFile(named: "README.md", in: rootURL)

        let resultURL = try WorkspaceFileTreeOperations.renameItem(at: fileURL, to: "README.md")

        #expect(resultURL == fileURL.standardizedFileURL)
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
    }
}

private func makeWorkspaceOperationsTemporaryDirectory() throws -> URL {
    let baseURL = FileManager.default.temporaryDirectory
    let directoryURL = baseURL.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    return directoryURL
}