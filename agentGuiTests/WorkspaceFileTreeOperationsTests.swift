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

    @Test func moveItemsRelocatesMultipleFilesIntoTargetDirectory() throws {
        let rootURL = try makeWorkspaceOperationsTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let docsURL = try WorkspaceFileTreeOperations.createDirectory(named: "Docs", in: rootURL)
        let archiveURL = try WorkspaceFileTreeOperations.createDirectory(named: "Archive", in: rootURL)
        let readmeURL = try WorkspaceFileTreeOperations.createFile(named: "README.md", in: docsURL)
        let notesURL = try WorkspaceFileTreeOperations.createFile(named: "Notes.md", in: docsURL)

        let movedURLs = try WorkspaceFileTreeOperations.moveItems(at: [readmeURL, notesURL], to: archiveURL)

        #expect(movedURLs == [
            archiveURL.appending(path: "README.md").standardizedFileURL,
            archiveURL.appending(path: "Notes.md").standardizedFileURL
        ])
        #expect(!FileManager.default.fileExists(atPath: readmeURL.path))
        #expect(!FileManager.default.fileExists(atPath: notesURL.path))
        #expect(FileManager.default.fileExists(atPath: movedURLs[0].path))
        #expect(FileManager.default.fileExists(atPath: movedURLs[1].path))
    }
}

private func makeWorkspaceOperationsTemporaryDirectory() throws -> URL {
    let baseURL = FileManager.default.temporaryDirectory
    let directoryURL = baseURL.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    return directoryURL
}