import AppKit
import SwiftUI

struct InlineRenameState<ID: Hashable>: Equatable {
    struct Draft: Identifiable, Equatable {
        let id: ID
        let originalText: String
        var text: String
    }

    struct CommitCandidate: Equatable {
        let id: ID
        let trimmedText: String
        let hasChanges: Bool
    }

    private(set) var draft: Draft?

    mutating func begin(id: ID, text: String) {
        draft = Draft(id: id, originalText: text, text: text)
    }

    mutating func update(text: String) {
        guard var draft else { return }
        draft.text = text
        self.draft = draft
    }

    mutating func cancel() {
        draft = nil
    }

    func isEditing(_ id: ID) -> Bool {
        draft?.id == id
    }

    var commitCandidate: CommitCandidate? {
        guard let draft else { return nil }

        let trimmedText = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedText.isEmpty == false else { return nil }

        let originalTrimmedText = draft.originalText.trimmingCharacters(in: .whitespacesAndNewlines)
        return CommitCandidate(
            id: draft.id,
            trimmedText: trimmedText,
            hasChanges: trimmedText != originalTrimmedText
        )
    }
}

struct InlineNameField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onCommit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> InlineEditorTextField {
        let textField = InlineEditorTextField()
        textField.isBordered = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.font = NSFont.systemFont(ofSize: 12)
        textField.lineBreakMode = .byTruncatingTail
        textField.placeholderString = placeholder
        textField.delegate = context.coordinator
        textField.commitHandler = onCommit
        textField.cancelHandler = onCancel
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField.identifier = NSUserInterfaceItemIdentifier("inline.nameField")
        textField.setAccessibilityIdentifier("inline.nameField")
        textField.setAccessibilityLabel(placeholder)
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

        init(text: Binding<String>) {
            self.text = text
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