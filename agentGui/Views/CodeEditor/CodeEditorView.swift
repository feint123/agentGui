import Foundation
import SwiftUI

struct CodeEditorView: View {
    @Binding var text: String
    let persistedText: String
    let fileURL: URL
    var focusRequest: UUID? = nil
    var onSelectionChange: ((EditorSelectionSnapshot?) -> Void)? = nil
    var onTextChange: ((String, EditorChangeSet) -> Void)? = nil

    @State private var document: CodeEditorDocument

    init(
        text: Binding<String>,
        persistedText: String,
        fileURL: URL,
        focusRequest: UUID? = nil,
        onSelectionChange: ((EditorSelectionSnapshot?) -> Void)? = nil,
        onTextChange: ((String, EditorChangeSet) -> Void)? = nil
    ) {
        self._text = text
        self.persistedText = persistedText
        self.fileURL = fileURL
        self.focusRequest = focusRequest
        self.onSelectionChange = onSelectionChange
        self.onTextChange = onTextChange
        self._document = State(initialValue: CodeEditorDocument(text: text.wrappedValue, persistedText: persistedText))
    }

    var body: some View {
        CodeEditorTextView(
            text: $text,
            document: $document,
            focusRequest: focusRequest,
            onSelectionChange: onSelectionChange,
            onChangeSet: { change in
                onTextChange?(text, change)
            }
        )
        .background(Color(NSColor.textBackgroundColor))
        .onChange(of: text) { _, newText in
            syncHostText(newText)
        }
        .onChange(of: persistedText) { _, newPersistedText in
            syncPersistedText(newPersistedText)
        }
    }

    private func syncHostText(_ hostText: String) {
        guard hostText != document.text else { return }
        let selectedRange = clampedSelection(for: hostText)
        _ = document.replaceFromDisk(
            text: hostText,
            persistedText: persistedText,
            selectedRange: selectedRange
        )
    }

    private func syncPersistedText(_ hostPersistedText: String) {
        guard hostPersistedText != document.persistedText else { return }
        document.syncPersistedText(hostPersistedText)
    }

    private func clampedSelection(for text: String) -> NSRange {
        let length = text.utf16.count
        let location = max(0, min(document.selectedRange.location, length))
        let safeLength = max(0, min(document.selectedRange.length, length - location))
        return NSRange(location: location, length: safeLength)
    }
}