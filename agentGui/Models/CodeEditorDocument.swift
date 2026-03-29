import Foundation

struct CodeEditorDocument: Equatable {
    var text: String
    var persistedText: String
    var version: Int = 0
    var selectedRange: NSRange = NSRange(location: 0, length: 0)
    private(set) var lineIndex: CodeEditorLineIndex

    init(
        text: String,
        persistedText: String,
        version: Int = 0,
        selectedRange: NSRange = NSRange(location: 0, length: 0)
    ) {
        self.text = text
        self.persistedText = persistedText
        self.version = version
        self.selectedRange = selectedRange
        lineIndex = CodeEditorLineIndex(text: text)
    }

    mutating func applyUserEdit(
        replacing replacedRange: NSRange,
        insertedText: String,
        updatedText: String,
        selectedRange: NSRange
    ) -> EditorChangeSet {
        version += 1
        lineIndex.applyEdit(replacedRange: replacedRange, insertedText: insertedText, in: updatedText)
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
        lineIndex.replaceAll(with: text)

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

    func lineRange(for range: NSRange) -> FileLineRange {
        lineIndex.lineRange(forUTF16Range: range)
    }

    func location(ofUTF16Offset offset: Int) -> CodeEditorTextLocation {
        lineIndex.location(ofUTF16Offset: offset)
    }

    func utf16Offset(line: Int, column: Int) -> Int {
        lineIndex.utf16Offset(line: line, column: column)
    }
}