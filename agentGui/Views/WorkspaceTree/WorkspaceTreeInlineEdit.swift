import AppKit
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

struct InlineTreeNameField: NSViewRepresentable {
    @Binding var text: String
    let onCommit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onCommit: onCommit, onCancel: onCancel)
    }

    func makeNSView(context: Context) -> InlineEditorTextField {
        let textField = InlineEditorTextField()
        textField.isBordered = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.font = NSFont.systemFont(ofSize: 12)
        textField.lineBreakMode = .byTruncatingTail
        textField.placeholderString = "输入名称"
        textField.delegate = context.coordinator
        textField.commitHandler = onCommit
        textField.cancelHandler = onCancel
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField.identifier = NSUserInterfaceItemIdentifier("workspace.inlineNameField")
        textField.setAccessibilityIdentifier("workspace.prompt.textField")
        textField.setAccessibilityLabel("输入名称")
        return textField
    }

    func updateNSView(_ nsView: InlineEditorTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.commitHandler = onCommit
        nsView.cancelHandler = onCancel
        context.coordinator.text = $text

        DispatchQueue.main.async {
            nsView.focusIfNeeded()
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        let onCommit: () -> Void
        let onCancel: () -> Void

        init(text: Binding<String>, onCommit: @escaping () -> Void, onCancel: @escaping () -> Void) {
            self.text = text
            self.onCommit = onCommit
            self.onCancel = onCancel
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else { return }
            text.wrappedValue = textField.stringValue
        }
    }
}

final class InlineEditorTextField: NSTextField {
    enum EndEditingAction: Equatable {
        case commit
        case cancel
    }

    var commitHandler: (() -> Void)?
    var cancelHandler: (() -> Void)?
    private var didAutoFocus = false

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        switch Self.endEditingAction(for: notification.userInfo?["NSTextMovement"] as? Int) {
        case .commit:
            commitHandler?()
        case .cancel:
            cancelHandler?()
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:
            cancelHandler?()
        default:
            super.keyDown(with: event)
        }
    }

    func focusIfNeeded() {
        guard !didAutoFocus, let window else { return }
        didAutoFocus = true
        window.makeFirstResponder(self)
        currentEditor()?.selectedRange = NSRange(location: 0, length: stringValue.count)
    }

    static func endEditingAction(for movement: Int?) -> EndEditingAction {
        if movement == NSReturnTextMovement {
            return .commit
        }
        return .cancel
    }
}