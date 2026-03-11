import Foundation

enum PreviewData {
    @MainActor
    static func settings(apiKey: String = "sk-ant-preview") -> AppSettings {
        AppSettings.testFixture(apiKey: apiKey)
    }

    @MainActor
    static func session(title: String = "Preview Session") -> Session {
        Session.fixture(title: title)
    }

    @MainActor
    static func messages(session: Session? = nil) -> [Message] {
        let previewSession = session ?? Session.fixture(title: "Preview Session")
        return [
            Message.userFixture(text: "Review the latest test plan", session: previewSession),
            Message.agentFixture(text: "I added a focused implementation plan and verified the entry points.", session: previewSession)
        ]
    }

    @MainActor
    static func runningWorkflow(sessionID: String = "preview-session") -> WorkflowInstance {
        WorkflowInstance.fixture(sessionId: sessionID, userTask: "Preview workflow", status: .running)
    }
}