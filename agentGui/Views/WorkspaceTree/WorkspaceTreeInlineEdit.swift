import SwiftUI

struct WorkspaceTreeInlineEdit: Equatable {
    enum Kind: Equatable {
        case file
        case folder
        case rename
    }

    let kind: Kind
    let parentDirectory: URL
    let targetURL: URL?
    let editingNodeID: URL
    let draftName: String
    let isDirectory: Bool

    static func makeCreate(kind: Kind, targetDirectory: URL) -> WorkspaceTreeInlineEdit {
        let tempURL = targetDirectory.appending(path: ".agentgui-inline-\(UUID().uuidString)")
        return WorkspaceTreeInlineEdit(
            kind: kind,
            parentDirectory: targetDirectory,
            targetURL: nil,
            editingNodeID: tempURL,
            draftName: "",
            isDirectory: kind == .folder
        )
    }

    static func makeRename(targetURL: URL, initialName: String, isDirectory: Bool) -> WorkspaceTreeInlineEdit {
        WorkspaceTreeInlineEdit(
            kind: .rename,
            parentDirectory: targetURL.deletingLastPathComponent(),
            targetURL: targetURL,
            editingNodeID: targetURL,
            draftName: initialName,
            isDirectory: isDirectory
        )
    }

    func withDraftName(_ draftName: String) -> WorkspaceTreeInlineEdit {
        WorkspaceTreeInlineEdit(
            kind: kind,
            parentDirectory: parentDirectory,
            targetURL: targetURL,
            editingNodeID: editingNodeID,
            draftName: draftName,
            isDirectory: isDirectory
        )
    }
}

enum WorkspaceTreeInlineEditApplier {
    static func apply(inlineEdit: WorkspaceTreeInlineEdit?, to nodes: [FileNode], rootDirectory: URL?) -> [FileNode] {
        guard let inlineEdit else { return nodes }
        if inlineEdit.kind == .rename {
            return nodes
        }

        let placeholderNode = FileNode(
            id: inlineEdit.editingNodeID,
            name: inlineEdit.draftName.isEmpty ? "未命名" : inlineEdit.draftName,
            isDirectory: inlineEdit.isDirectory,
            children: inlineEdit.isDirectory ? [] : nil
        )

        if inlineEdit.parentDirectory == rootDirectory?.standardizedFileURL {
            return [placeholderNode] + nodes
        }

        return injectPlaceholder(placeholderNode, into: nodes, parentDirectory: inlineEdit.parentDirectory)
    }

    private static func injectPlaceholder(_ placeholderNode: FileNode, into nodes: [FileNode], parentDirectory: URL) -> [FileNode] {
        nodes.map { node in
            guard node.isDirectory else { return node }
            if node.id == parentDirectory {
                return FileNode(
                    id: node.id,
                    name: node.name,
                    isDirectory: true,
                    children: [placeholderNode] + (node.children ?? [])
                )
            }

            let updatedChildren = injectPlaceholder(placeholderNode, into: node.children ?? [], parentDirectory: parentDirectory)
            return FileNode(id: node.id, name: node.name, isDirectory: true, children: updatedChildren)
        }
    }
}
