import Foundation
import Testing
@testable import agentGui

struct CodeEditorViewModelTests {
    @Test
    func statusBarUsesDocumentLocationAndLSPSummary() {
        let document = CodeEditorDocument(
            text: "func demo() {\n    return 1\n}\n",
            persistedText: ""
        )
        let status = WorkspacePanelLSPStatusPresentation(
            stateText: "运行中",
            serverID: "swift",
            selectedFileName: "Demo.swift",
            errorCount: 2,
            warningCount: 1,
            projectSummary: nil
        )

        let state = CodeEditorViewModel.makeStatusBarState(
            document: document,
            selectedRange: NSRange(location: 18, length: 0),
            fileURL: URL(fileURLWithPath: "/tmp/Demo.swift"),
            lspStatus: status,
            diagnostics: nil
        )

        #expect(state.cursor.line == 2)
        #expect(state.cursor.column == 5)
        #expect(state.languageLabel == "swift")
        #expect(state.lspStateText == "运行中")
        #expect(state.errorCount == 2)
        #expect(state.warningCount == 1)
    }

    @Test
    func diagnosticsAggregateHighestSeverityPerLine() {
        let snapshot = LSPDiagnosticsSnapshot(
            workspaceRoot: "/tmp",
            uri: URL(fileURLWithPath: "/tmp/Demo.swift").absoluteString,
            diagnostics: [
                .init(message: "unused", severity: .warning, line: 3, character: 1),
                .init(message: "syntax", severity: .error, line: 3, character: 4),
                .init(message: "hint", severity: .hint, line: 5, character: 0)
            ]
        )

        let summaries = CodeEditorViewModel.diagnosticsByLine(snapshot)

        #expect(summaries[4]?.highestSeverity == .error)
        #expect(summaries[4]?.messageCount == 2)
        #expect(summaries[6]?.highestSeverity == .hint)
        #expect(summaries[6]?.messageCount == 1)
    }

    @Test
    func detectIndentationRecognizesSpacesTabsAndUnknown() {
        let spaces = CodeEditorViewModel.detectIndentation(
            in: "func demo() {\n    if ready {\n        return\n    }\n}\n"
        )
        let tabs = CodeEditorViewModel.detectIndentation(
            in: "func demo() {\n\tif ready {\n\t\treturn\n\t}\n}\n"
        )
        let unknown = CodeEditorViewModel.detectIndentation(
            in: "func demo() {\nreturn\n}\n"
        )

        #expect(spaces == CodeEditorIndentationStatus(kind: .spaces, width: 4))
        #expect(tabs == CodeEditorIndentationStatus(kind: .tabs, width: 1))
        #expect(unknown == CodeEditorIndentationStatus(kind: .unknown, width: 0))
    }
}