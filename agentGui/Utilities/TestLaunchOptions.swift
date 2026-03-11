import Foundation

struct TestLaunchOptions {
    let isUITestMode: Bool
    let initialTab: AppTab
    let preloadAPIKey: Bool
    let preloadMessages: Bool
    let preloadToolCall: Bool
    let workflowState: WorkflowStatus?
    let recoveryMode: Bool
    let sessionID: String?

    static var current: TestLaunchOptions {
        TestLaunchOptions(arguments: ProcessInfo.processInfo.arguments)
    }

    init(arguments: [String]) {
        isUITestMode = Self.boolValue(for: "-com.agentgui.test.mode", in: arguments)
        preloadAPIKey = Self.boolValue(for: "-com.agentgui.test.preloadApiKey", in: arguments)
        preloadMessages = Self.boolValue(for: "-com.agentgui.test.preloadMessages", in: arguments)
        preloadToolCall = Self.boolValue(for: "-com.agentgui.test.preloadToolCall", in: arguments)
        recoveryMode = Self.boolValue(for: "-com.agentgui.test.recoveryMode", in: arguments)
        sessionID = Self.stringValue(for: "-com.agentgui.test.sessionId", in: arguments)

        if let rawTab = Self.stringValue(for: "-com.agentgui.test.initialTab", in: arguments),
           let parsedTab = AppTab(rawValue: rawTab) {
            initialTab = parsedTab
        } else {
            initialTab = .chat
        }

        if let rawWorkflowState = Self.stringValue(for: "-com.agentgui.test.workflowState", in: arguments) {
            workflowState = WorkflowStatus(rawValue: rawWorkflowState)
        } else {
            workflowState = nil
        }
    }

    private static func stringValue(for flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.lastIndex(of: flag), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    private static func boolValue(for flag: String, in arguments: [String]) -> Bool {
        guard let rawValue = stringValue(for: flag, in: arguments) else {
            return false
        }
        switch rawValue.lowercased() {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }
}