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

    @Test
    func navigationActionUsesRevealInCurrentFileForSameFile() {
        let currentFile = URL(fileURLWithPath: "/tmp/A.swift")
        let reveal = CodeEditorRevealRequest(
            fileURL: currentFile,
            line: 3,
            column: 2,
            reason: .definition
        )

        let action = CodeEditorViewModel.navigationAction(
            currentFileURL: currentFile,
            revealRequest: reveal
        )

        #expect(action == .revealInCurrentFile(reveal))
    }

    @Test
    func navigationActionUsesOpenFileAndRevealForDifferentLocalFile() {
        let currentFile = URL(fileURLWithPath: "/tmp/A.swift")
        let reveal = CodeEditorRevealRequest(
            fileURL: URL(fileURLWithPath: "/tmp/B.swift"),
            line: 8,
            column: 3,
            reason: .definition
        )

        let action = CodeEditorViewModel.navigationAction(
            currentFileURL: currentFile,
            revealRequest: reveal
        )

        #expect(action == .openFileAndReveal(reveal.fileURL, reveal))
    }

    @Test
    func flattenedDocumentSymbolsProduceIndentedRevealItems() throws {
        let symbols = [
            LSPDocumentSymbol(
                name: "Demo",
                detail: nil,
                kind: 12,
                line: 4,
                character: 0,
                endLine: 8,
                endCharacter: 1,
                children: [
                    LSPDocumentSymbol(
                        name: "inner",
                        detail: "func",
                        kind: 6,
                        line: 5,
                        character: 4,
                        endLine: 6,
                        endCharacter: 1,
                        children: []
                    )
                ]
            )
        ]

        let items = CodeEditorViewModel.flattenedDocumentSymbols(
            symbols,
            fileURL: URL(fileURLWithPath: "/tmp/A.swift")
        )

        let parent = try #require(items.first)
        let child = try #require(items.last)
        #expect(parent.title == "Demo")
        #expect(parent.revealRequest.line == 5)
        #expect(parent.revealRequest.reason == .documentSymbol)
        #expect(child.title == "  inner")
        #expect(child.subtitle == "func")
        #expect(child.revealRequest.line == 6)
    }

    @Test
    func selectionMatchesIgnoreMultilineOrWhitespaceSelections() {
        let document = CodeEditorDocument(
            text: "token alpha token\nnext line",
            persistedText: ""
        )

        let whitespaceOnly = CodeEditorViewModel.selectionMatchSnapshot(
            document: document,
            selectedRange: NSRange(location: 5, length: 1),
            visibleLineRange: 1...2
        )
        let multiline = CodeEditorViewModel.selectionMatchSnapshot(
            document: document,
            selectedRange: NSRange(location: 6, length: 12),
            visibleLineRange: 1...2
        )

        #expect(whitespaceOnly.spansByLine.isEmpty)
        #expect(multiline.spansByLine.isEmpty)
    }

    @Test
    func findMatchSnapshotProjectsVisibleMatchesAndActiveSelection() {
        let document = CodeEditorDocument(
            text: "alpha beta alpha\nalpha",
            persistedText: ""
        )

        let snapshot = CodeEditorViewModel.findMatchSnapshot(
            document: document,
            findState: CodeEditorFindState(
                isPresented: true,
                query: "alpha",
                caseSensitive: true,
                selectedMatchIndex: 1
            ),
            visibleLineRange: 1...2
        )

        #expect(snapshot.lineRange == 1...2)
        #expect(snapshot.spansByLine[1]?.count == 2)
        #expect(snapshot.spansByLine[2]?.count == 1)
        #expect(snapshot.spansByLine[1]?[0].kind == .findMatch)
        #expect(snapshot.spansByLine[1]?[1].kind == .activeFindMatch)
    }

    @Test
    func diagnosticsUnderlineUsesExplicitEndRangeWhenAvailable() {
        let snapshot = LSPDiagnosticsSnapshot(
            workspaceRoot: "/tmp",
            uri: "file:///tmp/Sample.swift",
            diagnostics: [
                .init(
                    message: "problem",
                    severity: .warning,
                    line: 0,
                    character: 4,
                    endLine: 0,
                    endCharacter: 9
                )
            ],
            documentVersion: 3
        )

        let decorations = CodeEditorViewModel.diagnosticUnderlineSnapshot(
            diagnostics: snapshot,
            document: CodeEditorDocument(text: "let value = 1", persistedText: ""),
            visibleLineRange: 1...1
        )

        #expect(decorations.spansByLine[1]?.first?.utf16Range == NSRange(location: 4, length: 5))
    }

    @Test
    func diagnosticsUnderlineFallsBackToSingleCharacterWhenEndRangeMissing() {
        let snapshot = LSPDiagnosticsSnapshot(
            workspaceRoot: "/tmp",
            uri: "file:///tmp/Sample.swift",
            diagnostics: [
                .init(
                    message: "problem",
                    severity: .error,
                    line: 0,
                    character: 4
                )
            ],
            documentVersion: 3
        )

        let decorations = CodeEditorViewModel.diagnosticUnderlineSnapshot(
            diagnostics: snapshot,
            document: CodeEditorDocument(text: "let value = 1", persistedText: ""),
            visibleLineRange: 1...1
        )

        #expect(decorations.spansByLine[1]?.first?.utf16Range == NSRange(location: 4, length: 1))
        #expect(decorations.spansByLine[1]?.first?.kind == .diagnosticUnderline(.error))
    }

    // MARK: - Symbol Breadcrumb Path

    @Test
    func symbolBreadcrumbPathReturnsEmptyWhenNoSymbols() {
        let path = CodeEditorViewModel.symbolBreadcrumbPath(for: 5, in: [])
        #expect(path.isEmpty)
    }

    @Test
    func symbolBreadcrumbPathFindsTopLevelEnclosingSymbol() {
        let symbols = [
            LSPDocumentSymbol(name: "MyClass", detail: nil, kind: 5,
                              line: 1, character: 0, endLine: 20, endCharacter: 1),
            LSPDocumentSymbol(name: "Other", detail: nil, kind: 5,
                              line: 22, character: 0, endLine: 30, endCharacter: 1),
        ]
        let path = CodeEditorViewModel.symbolBreadcrumbPath(for: 10, in: symbols)
        #expect(path.count == 1)
        #expect(path[0].name == "MyClass")
    }

    @Test
    func symbolBreadcrumbPathRecursesIntoBestChild() {
        let methodSymbol = LSPDocumentSymbol(
            name: "doWork()", detail: nil, kind: 12,
            line: 5, character: 4, endLine: 10, endCharacter: 5
        )
        let classSymbol = LSPDocumentSymbol(
            name: "MyClass", detail: nil, kind: 5,
            line: 1, character: 0, endLine: 20, endCharacter: 1,
            children: [methodSymbol]
        )
        let path = CodeEditorViewModel.symbolBreadcrumbPath(for: 7, in: [classSymbol])
        #expect(path.count == 2)
        #expect(path[0].name == "MyClass")
        #expect(path[1].name == "doWork()")
    }

    @Test
    func symbolBreadcrumbPathReturnsEmptyWhenCursorBetweenSymbols() {
        let symbols = [
            LSPDocumentSymbol(name: "A", detail: nil, kind: 12,
                              line: 1, character: 0, endLine: 3, endCharacter: 1),
            LSPDocumentSymbol(name: "B", detail: nil, kind: 12,
                              line: 5, character: 0, endLine: 8, endCharacter: 1),
        ]
        // cursor at line 4 — between A (ends 3) and B (starts 5)
        let path = CodeEditorViewModel.symbolBreadcrumbPath(for: 4, in: symbols)
        #expect(path.isEmpty)
    }

    @Test
    func symbolBreadcrumbPathFallsBackForSymbolsWithoutEndLine() {
        // SymbolInformation format (no end range): pick last symbol whose line ≤ cursorLine
        let symbols = [
            LSPDocumentSymbol(name: "A", detail: nil, kind: 12,
                              line: 1, character: 0, endLine: nil, endCharacter: nil),
            LSPDocumentSymbol(name: "B", detail: nil, kind: 12,
                              line: 5, character: 0, endLine: nil, endCharacter: nil),
            LSPDocumentSymbol(name: "C", detail: nil, kind: 12,
                              line: 10, character: 0, endLine: nil, endCharacter: nil),
        ]
        // cursor at line 7 → B (line 5) is nearest ≤ 7
        let path = CodeEditorViewModel.symbolBreadcrumbPath(for: 7, in: symbols)
        #expect(path.count == 1)
        #expect(path[0].name == "B")
    }

    // MARK: - Symbol Kind Icon

    @Test
    func symbolKindIconNameReturnsSFSymbolsForKnownKinds() {
        // LSP SymbolKind: 5 = Class, 12 = Function, 13 = Variable, 9 = Constructor
        #expect(CodeEditorViewModel.symbolKindIconName(for: 5) != nil)   // Class
        #expect(CodeEditorViewModel.symbolKindIconName(for: 12) != nil)  // Function
        #expect(CodeEditorViewModel.symbolKindIconName(for: 13) != nil)  // Variable
        #expect(CodeEditorViewModel.symbolKindIconName(for: 999) == nil) // unknown
    }

    @Test
    func symbolBreadcrumbNodesIncludeSiblingsForEachLevel() {
        let method1 = LSPDocumentSymbol(name: "alpha()", detail: nil, kind: 12,
                                        line: 2, character: 4, endLine: 4, endCharacter: 5)
        let method2 = LSPDocumentSymbol(name: "beta()", detail: nil, kind: 12,
                                        line: 6, character: 4, endLine: 8, endCharacter: 5)
        let classSymbol = LSPDocumentSymbol(
            name: "MyClass", detail: nil, kind: 5,
            line: 0, character: 0, endLine: 10, endCharacter: 1,
            children: [method1, method2]
        )
        let url = URL(fileURLWithPath: "/tmp/Foo.swift")
        let nodes = CodeEditorViewModel.symbolBreadcrumbNodes(for: 3, in: [classSymbol], fileURL: url)

        // path depth: MyClass > alpha()
        #expect(nodes.count == 2)
        #expect(nodes[0].name == "MyClass")
        #expect(nodes[1].name == "alpha()")

        // top-level siblings list contains only MyClass
        #expect(nodes[0].siblings.count == 1)

        // method-level siblings: alpha() + beta()
        #expect(nodes[1].siblings.count == 2)
        #expect(nodes[1].siblings.map(\.name).sorted() == ["alpha()", "beta()"])
    }
}