import Foundation

struct CodeEditorDocument: Equatable {
    var text: String
    var persistedText: String
    var version: Int = 0
    var selectedRange: NSRange = NSRange(location: 0, length: 0)

    mutating func applyUserEdit(
        replacing replacedRange: NSRange,
        insertedText: String,
        updatedText: String,
        selectedRange: NSRange
    ) -> EditorChangeSet {
        version += 1
        text = updatedText
        self.selectedRange = selectedRange

        return EditorChangeSet(
            version: version,
            replacedRange: replacedRange,
            insertedText: insertedText,
            selectedRange: selectedRange,
            origin: .userEdit
        )
    }

    mutating func replaceFromDisk(
        text: String,
        persistedText: String,
        selectedRange: NSRange = NSRange(location: 0, length: 0)
    ) -> EditorChangeSet {
        let replacedRange = NSRange(location: 0, length: self.text.utf16.count)
        version += 1
        self.text = text
        self.persistedText = persistedText
        self.selectedRange = selectedRange

        return EditorChangeSet(
            version: version,
            replacedRange: replacedRange,
            insertedText: text,
            selectedRange: selectedRange,
            origin: .externalReload
        )
    }

    mutating func markSelection(_ range: NSRange) {
        selectedRange = range
    }

    mutating func syncPersistedText(_ text: String) {
        persistedText = text
    }
}