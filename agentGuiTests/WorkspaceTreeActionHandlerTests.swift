import Foundation
import Testing
@testable import agentGui

struct WorkspaceTreeActionHandlerTests {

    @Test func renameRemapsNestedSelectionsAndClearsGitDiffWhenAffected() {
        let handler = WorkspaceTreeActionHandler()
        let originalDirectory = URL(fileURLWithPath: "/tmp/workspace/Sources")
        let renamedDirectory = URL(fileURLWithPath: "/tmp/workspace/App")
        let selection = WorkspaceTreeSelectionSnapshot(
            selectedTreeNodeID: originalDirectory.appending(path: "Feature"),
            selectedTreeNodeIDs: [
                originalDirectory.appending(path: "Feature"),
                originalDirectory.appending(path: "Feature/View.swift")
            ],
            selectedFile: originalDirectory.appending(path: "Feature/View.swift"),
            selectedGitDiffPath: originalDirectory.appending(path: "Feature/View.swift")
        )

        let updated = handler.applyingRename(from: originalDirectory, to: renamedDirectory, selection: selection)

        #expect(updated.selectedTreeNodeID == renamedDirectory.appending(path: "Feature"))
        #expect(updated.selectedTreeNodeIDs == [
            renamedDirectory.appending(path: "Feature").standardizedFileURL,
            renamedDirectory.appending(path: "Feature/View.swift").standardizedFileURL
        ])
        #expect(updated.selectedFile == renamedDirectory.appending(path: "Feature/View.swift"))
        #expect(updated.selectedGitDiffPath == nil)
    }

    @Test func deletionClearsSelectionsContainedInDeletedSubtree() {
        let handler = WorkspaceTreeActionHandler()
        let deletedDirectory = URL(fileURLWithPath: "/tmp/workspace/Sources")
        let unaffectedFile = URL(fileURLWithPath: "/tmp/workspace/README.md")
        let selection = WorkspaceTreeSelectionSnapshot(
            selectedTreeNodeID: deletedDirectory.appending(path: "Old"),
            selectedTreeNodeIDs: [
                deletedDirectory.appending(path: "Old"),
                unaffectedFile
            ],
            selectedFile: deletedDirectory.appending(path: "Old/View.swift"),
            selectedGitDiffPath: unaffectedFile
        )

        let updated = handler.applyingDeletion(of: deletedDirectory, selection: selection)

        #expect(updated.selectedTreeNodeID == nil)
        #expect(updated.selectedTreeNodeIDs == [unaffectedFile.standardizedFileURL])
        #expect(updated.selectedFile == nil)
        #expect(updated.selectedGitDiffPath == unaffectedFile.standardizedFileURL)
    }

    @Test func moveRemapsNestedSelectionsAndOpenFiles() {
        let handler = WorkspaceTreeActionHandler()
        let originalDirectory = URL(fileURLWithPath: "/tmp/workspace/Sources/Feature")
        let movedDirectory = URL(fileURLWithPath: "/tmp/workspace/Archive/Feature")
        let selection = WorkspaceTreeSelectionSnapshot(
            selectedTreeNodeID: originalDirectory,
            selectedTreeNodeIDs: [
                originalDirectory,
                originalDirectory.appending(path: "View.swift")
            ],
            selectedFile: originalDirectory.appending(path: "View.swift"),
            selectedGitDiffPath: originalDirectory.appending(path: "View.swift")
        )

        let updated = handler.applyingMove(
            from: [originalDirectory],
            to: [movedDirectory],
            selection: selection
        )

        #expect(updated.selectedTreeNodeID == movedDirectory.standardizedFileURL)
        #expect(updated.selectedTreeNodeIDs == [
            movedDirectory.standardizedFileURL,
            movedDirectory.appending(path: "View.swift").standardizedFileURL
        ])
        #expect(updated.selectedFile == movedDirectory.appending(path: "View.swift").standardizedFileURL)
        #expect(updated.selectedGitDiffPath == movedDirectory.appending(path: "View.swift").standardizedFileURL)
    }
}