import Foundation

struct CodeEditorTextLocation: Equatable, Sendable {
    let line: Int
    let column: Int
}

struct CodeEditorLineIndex: Equatable, Sendable {
    private(set) var textLength: Int
    private(set) var lineStartOffsets: [Int]

    init(text: String) {
        textLength = text.utf16.count
        lineStartOffsets = Self.computeLineStarts(for: text)
    }

    var lineCount: Int {
        lineStartOffsets.count
    }

    mutating func replaceAll(with text: String) {
        self = Self(text: text)
    }

    mutating func applyEdit(replacedRange: NSRange, insertedText: String, in updatedText: String) {
        let updatedTextLength = updatedText.utf16.count
        let safeLocation = clampedOffset(replacedRange.location)
        let safeLength = max(0, min(replacedRange.length, textLength - safeLocation))
        let safeUpperBound = safeLocation + safeLength
        let firstAffectedLineIndex = lineIndex(containing: safeLocation)
        let lastAffectedLineIndex = lineIndex(containing: safeUpperBound)
        let windowStartOffset = lineStartOffsets[firstAffectedLineIndex]
        let suffixStartIndex = min(lastAffectedLineIndex + 1, lineStartOffsets.count)
        let oldWindowEndOffset = suffixStartIndex < lineStartOffsets.count
            ? lineStartOffsets[suffixStartIndex]
            : textLength
        let lengthDelta = insertedText.utf16.count - safeLength
        let newWindowEndOffset = max(windowStartOffset, min(updatedTextLength, oldWindowEndOffset + lengthDelta))
        var rescannedOffsets = Self.computeLineStarts(
            in: updatedText,
            range: NSRange(location: windowStartOffset, length: newWindowEndOffset - windowStartOffset)
        )

        if suffixStartIndex < lineStartOffsets.count,
           rescannedOffsets.last == newWindowEndOffset {
            rescannedOffsets.removeLast()
        }

        let prefixOffsets = Array(lineStartOffsets[..<firstAffectedLineIndex])
        let suffixOffsets = lineStartOffsets[suffixStartIndex...].map { $0 + lengthDelta }

        lineStartOffsets = prefixOffsets + rescannedOffsets + suffixOffsets
        textLength = updatedTextLength
    }

    func lineNumber(containingUTF16Offset offset: Int) -> Int {
        location(ofUTF16Offset: offset).line
    }

    func columnNumber(atUTF16Offset offset: Int) -> Int {
        location(ofUTF16Offset: offset).column
    }

    func location(ofUTF16Offset offset: Int) -> CodeEditorTextLocation {
        let safeOffset = clampedOffset(offset)
        let lineIndex = lineIndex(containing: safeOffset)
        let lineStart = lineStartOffsets[lineIndex]
        return CodeEditorTextLocation(
            line: lineIndex + 1,
            column: safeOffset - lineStart + 1
        )
    }

    func utf16Offset(line: Int, column: Int) -> Int {
        guard !lineStartOffsets.isEmpty else { return 0 }
        let safeLineIndex = max(0, min(line - 1, lineStartOffsets.count - 1))
        let safeColumn = max(1, column)
        let startOffset = lineStartOffsets[safeLineIndex]
        let endOffset = lineContentEndOffset(forLineIndex: safeLineIndex)
        return min(startOffset + safeColumn - 1, endOffset)
    }

    func lineRange(forUTF16Range range: NSRange) -> FileLineRange {
        let safeLocation = clampedOffset(range.location)
        let safeUpperBound = clampedOffset(range.location + max(0, range.length))
        let startLine = lineNumber(containingUTF16Offset: safeLocation)
        let endLine = lineNumber(containingUTF16Offset: safeUpperBound)
        return FileLineRange(startLine: startLine, endLine: endLine)
    }

    func lineStartOffset(forLine line: Int) -> Int {
        let safeLineIndex = max(0, min(line - 1, lineStartOffsets.count - 1))
        return lineStartOffsets[safeLineIndex]
    }

    private func clampedOffset(_ offset: Int) -> Int {
        max(0, min(offset, textLength))
    }

    private func lineIndex(containing offset: Int) -> Int {
        guard lineStartOffsets.count > 1 else { return 0 }

        var lowerBound = 0
        var upperBound = lineStartOffsets.count
        while lowerBound + 1 < upperBound {
            let middle = (lowerBound + upperBound) / 2
            if lineStartOffsets[middle] <= offset {
                lowerBound = middle
            } else {
                upperBound = middle
            }
        }
        return lowerBound
    }

    private func lineContentEndOffset(forLineIndex lineIndex: Int) -> Int {
        guard lineIndex + 1 < lineStartOffsets.count else { return textLength }
        return lineStartOffsets[lineIndex + 1] - 1
    }

    private static func computeLineStarts(for text: String) -> [Int] {
        var starts = [0]
        for (offset, codeUnit) in text.utf16.enumerated() {
            if codeUnit == 10 {
                starts.append(offset + 1)
            }
        }
        return starts
    }

    private static func computeLineStarts(in text: String, range: NSRange) -> [Int] {
        let source = text as NSString
        let safeLocation = max(0, min(range.location, source.length))
        let safeLength = max(0, min(range.length, source.length - safeLocation))
        let windowText = source.substring(with: NSRange(location: safeLocation, length: safeLength))
        return computeLineStarts(for: windowText).map { safeLocation + $0 }
    }
}