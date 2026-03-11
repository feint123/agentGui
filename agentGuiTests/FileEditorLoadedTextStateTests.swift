import Foundation
import Testing
@testable import agentGui

struct FileEditorLoadedTextStateTests {

    @Test func canonicalLoadedTextMatchesEditorSerializationForMarkdownFiles() {
        let fileURL = URL(fileURLWithPath: "/tmp/note.md")
        let diskText = "第一行\n"

        let normalized = FileEditorLoadedTextState.normalizedTextForInitialLoad(diskText, fileURL: fileURL)

        #expect(normalized == "第一行")
    }

    @Test func canonicalLoadedTextMatchesEditorSerializationForSourceFiles() {
        let fileURL = URL(fileURLWithPath: "/tmp/demo.swift")
        let diskText = "struct Demo {}\n"

        let normalized = FileEditorLoadedTextState.normalizedTextForInitialLoad(diskText, fileURL: fileURL)

        #expect(normalized == "struct Demo {}")
    }
}