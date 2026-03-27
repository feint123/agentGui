import Foundation
import SwiftData
@testable import agentGui

@MainActor
struct InMemoryAppHarness {
    let container: ModelContainer
    let context: ModelContext
    let settings: AppSettings
    let session: Session
    let runtimeRecoveryService: RuntimeRecoveryService
    let launchOptions: TestLaunchOptions
    let projectID: String

    static func makeRecoveryScenario() throws -> InMemoryAppHarness {
        let container = try makeContainer()
        let context = ModelContext(container)
        let launchOptions = TestLaunchOptions(arguments: [
            "-com.agentgui.test.mode", "true",
            "-com.agentgui.test.preloadApiKey", "true",
            "-com.agentgui.test.preloadMessages", "true",
            "-com.agentgui.test.recoveryMode", "true"
        ])
        let settings = AppSettings.testFixture(apiKey: "sk-ant-ui-test")
        let fixture = QualityFixtureBuilder.recoveryScenario()
        context.insert(settings)
        context.insert(fixture.session)
        context.insert(fixture.pendingAgentMessage)
        for snapshot in fixture.recoverySnapshots {
            context.insert(snapshot)
        }
        try context.save()

        return InMemoryAppHarness(
            container: container,
            context: context,
            settings: settings,
            session: fixture.session,
            runtimeRecoveryService: RuntimeRecoveryService(),
            launchOptions: launchOptions,
            projectID: ""
        )
    }

    static func makeConfiguredSettingsScenario() throws -> InMemoryAppHarness {
        let container = try makeContainer()
        let context = ModelContext(container)
        let settings = AppSettings.testFixture(apiKey: "sk-ant-release-test")
        let session = Session.fixture(title: "Configured Settings")
        context.insert(settings)
        context.insert(session)
        try context.save()

        return InMemoryAppHarness(
            container: container,
            context: context,
            settings: settings,
            session: session,
            runtimeRecoveryService: RuntimeRecoveryService(),
            launchOptions: TestLaunchOptions(arguments: ["-com.agentgui.test.mode", "true"]),
            projectID: ""
        )
    }

    static func makeConversationScenario() throws -> InMemoryAppHarness {
        let container = try makeContainer()
        let context = ModelContext(container)
        let settings = AppSettings.testFixture(apiKey: "sk-ant-release-test")
        let session = Session.fixture(sessionId: "release-session", title: "UI Test Session")
        let userMessage = Message.userFixture(text: "Run the release checks", session: session)
        let agentMessage = Message.agentFixture(text: "Release checklist prepared.", session: session)
        context.insert(settings)
        context.insert(session)
        context.insert(userMessage)
        context.insert(agentMessage)
        try context.save()

        return InMemoryAppHarness(
            container: container,
            context: context,
            settings: settings,
            session: session,
            runtimeRecoveryService: RuntimeRecoveryService(),
            launchOptions: TestLaunchOptions(arguments: ["-com.agentgui.test.mode", "true"]),
            projectID: ""
        )
    }

    static func makeToolCallScenario() throws -> InMemoryAppHarness {
        let harness = try makeConversationScenario()
        guard let agentMessage = harness.session.messages.first(where: { $0.direction == .agent }) else {
            return harness
        }

        let toolCall = ToolCall.fixture(
            kind: .read,
            message: agentMessage,
            filePath: "/tmp/ReleaseChecklist.md",
            status: .inProgress
        )
        toolCall.title = "读取文件"
        toolCall.terminalOutput = "Release checklist contents"
        harness.context.insert(toolCall)
        try harness.context.save()
        return harness
    }

    static func makeBashTaskScenario() throws -> InMemoryAppHarness {
        let harness = try makeConversationScenario()
        guard let agentMessage = harness.session.messages.first(where: { $0.direction == .agent }) else {
            return harness
        }

        let toolCall = ToolCall.fixture(
            kind: .execute,
            message: agentMessage,
            status: .inProgress
        )
        toolCall.title = "npm test"
        toolCall.terminalExecutionMode = TerminalExecutionMode.background.rawValue
        toolCall.terminalTaskStatus = TerminalTaskStatus.runningBackground.rawValue
        toolCall.terminalPromptSummary = "waiting for tests"
        toolCall.terminalOutput = "running in background"
        harness.context.insert(toolCall)
        try harness.context.save()
        return harness
    }

    private static func makeContainer() throws -> ModelContainer {
        let schema = Schema(PersistenceSchema.sharedModelTypes)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}