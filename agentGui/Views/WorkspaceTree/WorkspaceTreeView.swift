import SwiftUI

struct WorkspaceTreeView: View {
    let nodes: [FileNode]
    let selectionIDs: Set<URL>
    let primarySelectionID: URL?
    let inlineEdit: WorkspaceTreeInlineEdit?
    let expandsMatchingBranches: Bool
    let gitChangeProvider: (FileNode) -> GitFileChange?
    let onSelectionChange: (Set<URL>, URL?) -> Void
    let actions: WorkspaceTreeOutlineView.ActionHandlers

    var body: some View {
        WorkspaceTreeOutlineView(
            nodes: nodes,
            selectionIDs: selectionIDs,
            primarySelectionID: primarySelectionID,
            inlineEdit: inlineEdit,
            expandsMatchingBranches: expandsMatchingBranches,
            gitChangeProvider: gitChangeProvider,
            onSelectionChange: onSelectionChange,
            actions: actions
        )
        .accessibilityIdentifier("workspace.fileTree")
    }
}