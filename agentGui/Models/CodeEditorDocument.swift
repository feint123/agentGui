import Foundation

struct CodeEditorDocument: Equatable {
    var text: String
    var persistedText: String
    var version: Int = 0
    var selectedRange: NSRange = NSRange(location: 0, length: 0)
    /// 多光标选区快照（单光标时 count == 1）
    var allSelectedRanges: [NSRange] = []
    private(set) var lineIndex: CodeEditorLineIndex

    var lineCount: Int {
        lineIndex.lineCount
    }

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
        self.allSelectedRanges = [selectedRange]

        return EditorChangeSet(
            version: version,
            replacedRange: replacedRange,
            insertedText: insertedText,
            selectedRange: selectedRange,
            origin: .userEdit
        )
    }

    /// 多光标编辑全文替换路径。直接重建行索引，EditorChangeSet.isMultiCursorEdit=true。
    mutating func replaceAllForMultiCursorEdit(
        text newText: String,
        selectedRange newRange: NSRange
    ) -> EditorChangeSet {
        let replacedRange = NSRange(location: 0, length: self.text.utf16.count)
        version += 1
        lineIndex.replaceAll(with: newText)
        text = newText
        selectedRange = newRange
        allSelectedRanges = [newRange]

        return EditorChangeSet(
            version: version,
            replacedRange: replacedRange,
            insertedText: newText,
            selectedRange: newRange,
            origin: .userEdit,
            isMultiCursorEdit: true
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
        allSelectedRanges = [range]
    }

    /// 多光标选区记录
    mutating func markMultiSelection(_ ranges: [NSRange]) {
        selectedRange = ranges.last ?? NSRange(location: 0, length: 0)
        allSelectedRanges = ranges
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

    func utf16LineRange(forLine line: Int) -> NSRange {
        let safeLine = max(1, min(line, lineCount))
        let startOffset = lineIndex.lineStartOffset(forLine: safeLine)
        let endOffset = safeLine < lineCount
            ? lineIndex.lineStartOffset(forLine: safeLine + 1)
            : text.utf16.count

        return NSRange(location: startOffset, length: max(0, endOffset - startOffset))
    }
}