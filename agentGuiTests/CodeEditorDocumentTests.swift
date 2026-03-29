import Foundation
import Testing
@testable import agentGui

struct CodeEditorDocumentTests {
    @Test
    func initialStateStartsCleanAtVersionZero() {
        let document = CodeEditorDocument(text: "hello", persistedText: "hello")

        #expect(document.version == 0)
        #expect(document.text == "hello")
        #expect(document.persistedText == "hello")
        #expect(document.selectedRange == NSRange(location: 0, length: 0))
    }

    @Test
    func applyUserEditEmitsChangeSetAndBumpsVersion() {
        var document = CodeEditorDocument(text: "hello", persistedText: "hello")

        let change = document.applyUserEdit(
            replacing: NSRange(location: 5, length: 0),
            insertedText: " world",
            updatedText: "hello world",
            selectedRange: NSRange(location: 11, length: 0)
        )

        #expect(document.version == 1)
        #expect(document.text == "hello world")
        #expect(document.persistedText == "hello")
        #expect(document.selectedRange == NSRange(location: 11, length: 0))
        #expect(change.version == 1)
        #expect(change.replacedRange == NSRange(location: 5, length: 0))
        #expect(change.insertedText == " world")
        #expect(change.selectedRange == NSRange(location: 11, length: 0))
        #expect(change.origin == .userEdit)
    }

    @Test
    func replaceFromDiskUpdatesTextWithoutMarkingUserEdit() {
        var document = CodeEditorDocument(
            text: "hello world",
            persistedText: "hello",
            version: 1,
            selectedRange: NSRange(location: 11, length: 0)
        )

        let change = document.replaceFromDisk(
            text: "fresh",
            persistedText: "fresh",
            selectedRange: NSRange(location: 5, length: 0)
        )

        #expect(document.version == 2)
        #expect(document.text == "fresh")
        #expect(document.persistedText == "fresh")
        #expect(document.selectedRange == NSRange(location: 5, length: 0))
        #expect(change.origin == .externalReload)
        #expect(change.insertedText == "fresh")
        #expect(change.replacedRange == NSRange(location: 0, length: 11))
    }

    @Test
    func markSelectionDoesNotChangeVersion() {
        var document = CodeEditorDocument(text: "hello", persistedText: "hello", version: 2)

        document.markSelection(NSRange(location: 1, length: 3))

        #expect(document.version == 2)
        #expect(document.text == "hello")
        #expect(document.persistedText == "hello")
        #expect(document.selectedRange == NSRange(location: 1, length: 3))
    }
}