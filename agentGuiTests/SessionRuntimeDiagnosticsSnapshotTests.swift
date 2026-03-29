import Foundation
import Testing
@testable import agentGui

struct SessionRuntimeDiagnosticsSnapshotTests {
    @Test
    func diagnosticsSnapshotUsesRuntimeSnapshotFields() {
        let snapshot = SessionRuntimeSnapshot(
            sessionID: "session-a",
            queuedJobIDs: [UUID(), UUID()],
            runningJobID: UUID(),
            runningProviderReference: .builtIn,
            requestedCancellationJobIDs: [],
            lastAction: .started,
            lastUpdatedAt: .now,
            lastKnownProviderReference: .builtIn
        )

        let diagnostics = SessionRuntimeDiagnosticsSnapshot(snapshot: snapshot)

        #expect(diagnostics.sessionID == "session-a")
        #expect(diagnostics.activityText == "运行中")
        #expect(diagnostics.providerText == "Built-in")
        #expect(diagnostics.queuedCount == 2)
        #expect(diagnostics.isCancelling == false)
        #expect(diagnostics.lastActionText.localizedStandardContains("started"))
    }

    @Test
    func diagnosticsSnapshotMarksCancellingState() {
        let runningJobID = UUID()
        let snapshot = SessionRuntimeSnapshot(
            sessionID: "session-b",
            queuedJobIDs: [],
            runningJobID: runningJobID,
            runningProviderReference: .builtIn,
            requestedCancellationJobIDs: [runningJobID],
            lastAction: .cancelRequested,
            lastUpdatedAt: .now,
            lastKnownProviderReference: .builtIn
        )

        let diagnostics = SessionRuntimeDiagnosticsSnapshot(snapshot: snapshot)

        #expect(diagnostics.activityText == "取消中")
        #expect(diagnostics.isCancelling)
        #expect(diagnostics.lastActionText.localizedStandardContains("cancel"))
    }
}