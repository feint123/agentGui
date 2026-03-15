import Foundation
import Testing
@testable import agentGui

@MainActor
struct LSPDiagnosticsPopoverPresentationTests {

    @Test func statusToneMapsLocalizedRunningAndFailureStates() {
        #expect(LSPStatusPresentationTone.tone(for: "运行中") == .positive)
        #expect(LSPStatusPresentationTone.tone(for: "启动中") == .warning)
        #expect(LSPStatusPresentationTone.tone(for: "未安装") == .negative)
        #expect(LSPStatusPresentationTone.tone(for: "配置异常") == .negative)
        #expect(LSPStatusPresentationTone.tone(for: "未启动") == .neutral)
    }

    @Test func rowPresentationCombinesSourceAndLocationIntoSingleMetadataLine() {
        let item = LSPProjectDiagnosticsSummary.DiagnosticItem(
            uri: "file:///repo/src/app.ts",
            message: "Type mismatch between inferred value and expected return type",
            severity: .error,
            source: "tsserver",
            line: 3,
            character: 7
        )

        let presentation = LSPDiagnosticRowPresentation.make(item)

        #expect(presentation.pathText == "app.ts")
        #expect(presentation.messageText == "Type mismatch between inferred value and expected return type")
        #expect(presentation.metadataText == "tsserver · L4:C8")
    }

    @Test func rowPresentationUsesLocationWhenSourceIsMissing() {
        let item = LSPProjectDiagnosticsSummary.DiagnosticItem(
            uri: "file:///repo/src/view.tsx",
            message: "Unused variable",
            severity: .warning,
            line: 10,
            character: 2
        )

        let presentation = LSPDiagnosticRowPresentation.make(item)

        #expect(presentation.metadataText == "L11:C3")
    }
}