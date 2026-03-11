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

    @Test func detectsBinaryDiffEmptyStateReason() {
        let descriptor = GitDiffEmptyStateDescriptor.make(
            title: "docs/image.png",
            diffText: "Binary files a/docs/image.png and b/docs/image.png differ"
        )

        #expect(descriptor.title == "无法预览二进制 Diff")
        #expect(descriptor.message == "这个文件是二进制内容，当前只支持文本 patch 预览。")
    }

    @Test func detectsMetadataOnlyDiffEmptyStateReason() {
        let descriptor = GitDiffEmptyStateDescriptor.make(
            title: "docs/README.md",
            diffText: "diff --git a/docs/README.md b/docs/README.md\nindex 1111111..2222222 100644\n--- a/docs/README.md\n+++ b/docs/README.md"
        )

        #expect(descriptor.title == "无可显示的 Diff")
        #expect(descriptor.message == "这个文件当前没有可渲染的 patch，可能只有元数据变化。")
    }
}