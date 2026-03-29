import Foundation
import Testing
@testable import agentGui

struct CodeEditorLineIndexTests {
    @Test
    func buildsLineStartsAndLocationsFromMultilineText() {
        let index = CodeEditorLineIndex(text: "alpha\nbeta\ngamma")

        #expect(index.lineCount == 3)
        #expect(index.lineStartOffset(forLine: 1) == 0)
        #expect(index.lineStartOffset(forLine: 2) == 6)
        #expect(index.location(ofUTF16Offset: 7) == CodeEditorTextLocation(line: 2, column: 2))
        #expect(index.lineRange(forUTF16Range: NSRange(location: 6, length: 4)) == FileLineRange(startLine: 2, endLine: 2))
    }

    @Test
    func treatsEmptyTextAsSingleLine() {
        let index = CodeEditorLineIndex(text: "")

        #expect(index.lineCount == 1)
        #expect(index.lineStartOffset(forLine: 1) == 0)
        #expect(index.location(ofUTF16Offset: 0) == CodeEditorTextLocation(line: 1, column: 1))
        #expect(index.lineRange(forUTF16Range: NSRange(location: 0, length: 0)) == FileLineRange(startLine: 1, endLine: 1))
    }

    @Test
    func clampsTailOffsetToLastColumn() {
        let index = CodeEditorLineIndex(text: "alpha\nbeta")

        #expect(index.location(ofUTF16Offset: 10) == CodeEditorTextLocation(line: 2, column: 5))
    }

    @Test
    func mapsCrossLineRangeToEnclosingFileLineRange() {
        let index = CodeEditorLineIndex(text: "alpha\nbeta\ngamma")

        #expect(index.lineRange(forUTF16Range: NSRange(location: 3, length: 8)) == FileLineRange(startLine: 1, endLine: 3))
    }

    @Test
    func roundTripsUTF16ColumnsForMultiUnitCharacters() {
        let index = CodeEditorLineIndex(text: "a🙂\nb")

        #expect(index.location(ofUTF16Offset: 3) == CodeEditorTextLocation(line: 1, column: 4))
        #expect(index.utf16Offset(line: 1, column: 4) == 3)
        #expect(index.utf16Offset(line: 2, column: 2) == 5)
    }

    @Test
    func applyEditUpdatesOnlyAffectedMappingSemantics() {
        var index = CodeEditorLineIndex(text: "alpha\nbeta\ngamma")
        let updatedText = "alpha\nbe\nta\ngamma"

        index.applyEdit(
            replacedRange: NSRange(location: 8, length: 0),
            insertedText: "\n",
            in: updatedText
        )

        #expect(index.lineCount == 4)
        #expect(index.lineStartOffset(forLine: 3) == 9)
        #expect(index.location(ofUTF16Offset: 9) == CodeEditorTextLocation(line: 3, column: 1))
        #expect(index.lineRange(forUTF16Range: NSRange(location: 6, length: 4)) == FileLineRange(startLine: 2, endLine: 3))
    }

    @Test
    func applyEditDeletingNewlineMergesLines() {
        var index = CodeEditorLineIndex(text: "alpha\n\nbeta")
        let updatedText = "alpha\nbeta"

        index.applyEdit(
            replacedRange: NSRange(location: 6, length: 1),
            insertedText: "",
            in: updatedText
        )

        #expect(index.lineCount == 2)
        #expect(index.lineStartOffset(forLine: 2) == 6)
        #expect(index.location(ofUTF16Offset: 9) == CodeEditorTextLocation(line: 2, column: 4))
    }

    @Test
    func applyEditMatchesFullRebuildAcrossRandomEdits() {
        var text = "alpha\nbeta\ngamma\n🙂delta"
        var index = CodeEditorLineIndex(text: text)
        var generator = DeterministicGenerator(seed: 42)
        let insertedTexts = ["", "x", "\n", "🙂", "pq\n", "zz"]

        for _ in 0..<50 {
            let textLength = text.utf16.count
            let location = generator.nextInt(upperBound: textLength + 1)
            let maxRemoval = min(3, textLength - location)
            let removalLength = generator.nextInt(upperBound: maxRemoval + 1)
            let insertedText = insertedTexts[generator.nextInt(upperBound: insertedTexts.count)]
            let replacedRange = NSRange(location: location, length: removalLength)
            let updatedText = (text as NSString).replacingCharacters(in: replacedRange, with: insertedText)

            index.applyEdit(
                replacedRange: replacedRange,
                insertedText: insertedText,
                in: updatedText
            )

            let rebuilt = CodeEditorLineIndex(text: updatedText)
            #expect(index == rebuilt)

            text = updatedText
        }
    }
}

private struct DeterministicGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func nextInt(upperBound: Int) -> Int {
        precondition(upperBound > 0)
        state = state &* 6364136223846793005 &+ 1
        return Int(state % UInt64(upperBound))
    }
}