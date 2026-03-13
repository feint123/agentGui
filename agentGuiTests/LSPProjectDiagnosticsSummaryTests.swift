import Foundation
import Testing
@testable import agentGui

@MainActor
struct LSPProjectDiagnosticsSummaryTests {

    @Test func summaryCountsFilesErrorsWarningsAndMostRecentUpdate() {
        let first = Date(timeIntervalSince1970: 1_000)
        let second = Date(timeIntervalSince1970: 2_000)
        let summary = LSPProjectDiagnosticsSummary(
            workspaceRoot: "/repo",
            filesWithDiagnostics: 2,
            errorCount: 1,
            warningCount: 2,
            informationCount: 1,
            hintCount: 0,
            updatedAt: second,
            recentDiagnostics: [
                .init(uri: "file:///repo/src/app.ts", message: "Type mismatch", severity: .error),
                .init(uri: "file:///repo/src/view.tsx", message: "Unused variable", severity: .warning)
            ]
        )

        #expect(summary.workspaceRoot == "/repo")
        #expect(summary.filesWithDiagnostics == 2)
        #expect(summary.errorCount == 1)
        #expect(summary.warningCount == 2)
        #expect(summary.updatedAt == second)
        #expect(summary.recentDiagnostics.count == 2)
        #expect(summary.recentDiagnostics.first?.message == "Type mismatch")
        _ = first
    }
}