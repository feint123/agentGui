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
            selectedFile: originalDirectory.appending(path: "Feature/View.swift"),
            selectedGitDiffPath: originalDirectory.appending(path: "Feature/View.swift")
        )

        let updated = handler.applyingRename(from: originalDirectory, to: renamedDirectory, selection: selection)

        #expect(updated.selectedTreeNodeID == renamedDirectory.appending(path: "Feature"))
        #expect(updated.selectedFile == renamedDirectory.appending(path: "Feature/View.swift"))
        #expect(updated.selectedGitDiffPath == nil)
    }

    @Test func deletionClearsSelectionsContainedInDeletedSubtree() {
        let handler = WorkspaceTreeActionHandler()
        let deletedDirectory = URL(fileURLWithPath: "/tmp/workspace/Sources")
        let unaffectedFile = URL(fileURLWithPath: "/tmp/workspace/README.md")
        let selection = WorkspaceTreeSelectionSnapshot(
            selectedTreeNodeID: deletedDirectory.appending(path: "Old"),
            selectedFile: deletedDirectory.appending(path: "Old/View.swift"),
            selectedGitDiffPath: unaffectedFile
        )

        let updated = handler.applyingDeletion(of: deletedDirectory, selection: selection)

        #expect(updated.selectedTreeNodeID == nil)
        #expect(updated.selectedFile == nil)
        #expect(updated.selectedGitDiffPath == unaffectedFile.standardizedFileURL)
    }
}