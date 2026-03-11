import Foundation
import Testing
@testable import agentGui

struct GitDiffPresentationTests {

    @Test func buildsPatchSummaryAndRowsFromUnifiedDiff() {
        let diffText = """
        diff --git a/agentGui/Views/GitDiffView.swift b/agentGui/Views/GitDiffView.swift
        index 1111111..2222222 100644
        --- a/agentGui/Views/GitDiffView.swift
        +++ b/agentGui/Views/GitDiffView.swift
        @@ -10,3 +10,4 @@ struct GitDiffView: View {
        -    Text("old")
        +    Text("new")
        +    Text("added")
             Spacer()
        """

        let presentation = GitDiffPresentation.build(title: "agentGui/Views/GitDiffView.swift", diffText: diffText)

        #expect(presentation.filePath == "agentGui/Views/GitDiffView.swift")
        #expect(presentation.changeSummary.additions == 2)
        #expect(presentation.changeSummary.deletions == 1)
        #expect(presentation.sections.count == 1)
        #expect(presentation.sections[0].header == "@@ -10,3 +10,4 @@ struct GitDiffView: View {")
        #expect(presentation.sections[0].rows.count == 4)
        #expect(presentation.sections[0].rows[0] == .deletion(oldLineNumber: 10, newLineNumber: nil, text: "    Text(\"old\")"))
        #expect(presentation.sections[0].rows[1] == .addition(oldLineNumber: nil, newLineNumber: 10, text: "    Text(\"new\")"))
        #expect(presentation.sections[0].rows[2] == .addition(oldLineNumber: nil, newLineNumber: 11, text: "    Text(\"added\")"))
        #expect(presentation.sections[0].rows[3] == .context(oldLineNumber: 11, newLineNumber: 12, text: "    Spacer()"))
    }

    @Test func buildsEmptyPresentationForBlankDiff() {
        let presentation = GitDiffPresentation.build(title: "file.swift", diffText: "")

        #expect(presentation.changeSummary.additions == 0)
        #expect(presentation.changeSummary.deletions == 0)
        #expect(presentation.sections.isEmpty)
    }
}