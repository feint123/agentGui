import Foundation
import Testing
@testable import agentGui

@MainActor
struct WorkbenchLSPPanelPresentationTests {
    @Test func statusToneMapsLocalizedRunningAndFailureStates() {
        #expect(WorkbenchLSPStatusTone.tone(for: "运行中") == .positive)
        #expect(WorkbenchLSPStatusTone.tone(for: "启动中") == .warning)
        #expect(WorkbenchLSPStatusTone.tone(for: "未安装") == .negative)
        #expect(WorkbenchLSPStatusTone.tone(for: "配置异常") == .negative)
        #expect(WorkbenchLSPStatusTone.tone(for: "未启动") == .neutral)
    }

    @Test func rowPresentationCombinesSourceAndLocationIntoMetadata() {
        let item = LSPProjectDiagnosticsSummary.DiagnosticItem(
            uri: "file:///repo/src/app.ts",
            message: "Type mismatch",
            severity: .error,
            source: "tsserver",
            line: 3,
            character: 7
        )

        let presentation = WorkbenchLSPDiagnosticRowPresentation.make(item)

        #expect(presentation.pathText == "app.ts")
        #expect(presentation.metadataText == "tsserver · L4:C8")
    }

    @Test func rowPresentationBuildsLocationMetadataWithoutSource() {
        let item = LSPProjectDiagnosticsSummary.DiagnosticItem(
            uri: "file:///repo/src/app.ts",
            message: "Missing return statement",
            severity: .warning,
            source: nil,
            line: 10,
            character: 2
        )

        let presentation = WorkbenchLSPDiagnosticRowPresentation.make(item)

        #expect(presentation.metadataText == "L11:C3")
    }

    @Test func serviceActionPresentationPrioritizesInstallAndRepairAheadOfRecheck() {
        let installActions = WorkbenchLSPServiceActionPresentation.primaryActions(
            from: [.recheck, .install],
            limit: 2
        )
        let runningActions = WorkbenchLSPServiceActionPresentation.primaryActions(
            from: [.recheck, .restart, .stop],
            limit: 2
        )

        #expect(installActions == [.install, .recheck])
        #expect(runningActions == [.stop, .restart])
    }
}