import Foundation

struct TestLaunchOptions {
    let isUITestMode: Bool
    let initialTab: AppTab
    let preloadAPIKey: Bool
    let preloadMessages: Bool
    let preloadToolCall: Bool
    let recoveryMode: Bool
    let sessionID: String?
    let workingDirectoryPath: String?
    let selectedFilePath: String?
    let todoFixtureMode: String?
    let initialComposerText: String?
    let chatProjectionFixture: String?
    let executionFixtureMode: String?
    let suppressOnboarding: Bool

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
        workingDirectoryPath = Self.stringValue(for: "-com.agentgui.test.workingDirectory", in: arguments)
        selectedFilePath = Self.stringValue(for: "-com.agentgui.test.selectedFilePath", in: arguments)
        todoFixtureMode = Self.stringValue(for: "-com.agentgui.test.todoFixtureMode", in: arguments)
        initialComposerText = Self.stringValue(for: "-com.agentgui.test.initialComposerText", in: arguments)
        chatProjectionFixture = Self.stringValue(for: "-com.agentgui.test.chatProjectionFixture", in: arguments)
        executionFixtureMode = Self.stringValue(for: "-com.agentgui.test.executionFixture", in: arguments)
        suppressOnboarding = Self.boolValue(for: "-com.agentgui.test.suppressOnboarding", in: arguments)

        if let rawTab = Self.stringValue(for: "-com.agentgui.test.initialTab", in: arguments),
           let parsedTab = AppTab(rawValue: rawTab) {
            initialTab = parsedTab
        } else {
            initialTab = .chat
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