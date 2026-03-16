import Foundation
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct BackgroundTaskRegistryTests {
    @Test func registryUsesStableSchedulerIdentifier() {
        let task = BackgroundAgentTask(
            taskKey: "repo-daily-summary",
            title: "日报",
            sessionId: "session-1",
            taskPrompt: "生成日报"
        )

        #expect(BackgroundTaskRegistry.schedulerIdentifier(for: task) == "com.agentgui.background.task.repo-daily-summary")
    }

    @Test func registryRegistersEnabledTasksAndInvalidatesRemovedOnes() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let enabledTask = BackgroundAgentTask(
            taskKey: "enabled-task",
            title: "启用任务",
            sessionId: "session-1",
            taskPrompt: "运行启用任务"
        )
        let disabledTask = BackgroundAgentTask(
            taskKey: "disabled-task",
            title: "停用任务",
            isEnabled: false,
            sessionId: "session-1",
            taskPrompt: "不运行"
        )
        context.insert(enabledTask)
        context.insert(disabledTask)
        try context.save()

        let factory = FakeBackgroundSchedulerFactory()
        let registry = BackgroundTaskRegistry(
            policyEngine: BackgroundTaskPolicyEngine(),
            schedulerFactory: factory.makeScheduler
        )

        try registry.refresh(modelContext: context)

        #expect(factory.createdIdentifiers == ["com.agentgui.background.task.enabled-task"])

        context.delete(enabledTask)
        try context.save()

        try registry.refresh(modelContext: context)

        #expect(factory.invalidatedIdentifiers.contains("com.agentgui.background.task.enabled-task"))
    }

    private func makeContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: BackgroundAgentTask.self,
            BackgroundAgentTaskRun.self,
            configurations: configuration
        )
    }
}

@MainActor
private final class FakeBackgroundSchedulerFactory {
    private(set) var createdIdentifiers: [String] = []
    private(set) var invalidatedIdentifiers: [String] = []

    func makeScheduler(identifier: String) -> any BackgroundSystemScheduler {
        createdIdentifiers.append(identifier)
        return FakeBackgroundScheduler(
            identifier: identifier,
            onInvalidate: { [weak self] id in
                self?.invalidatedIdentifiers.append(id)
            }
        )
    }
}

@MainActor
private final class FakeBackgroundScheduler: BackgroundSystemScheduler {
    let identifier: String
    var interval: TimeInterval = 0
    var tolerance: TimeInterval = 0
    var repeats: Bool = false
    var qualityOfService: BackgroundTaskQualityOfService = .utility
    var shouldDefer: Bool = false

    private let onInvalidate: (String) -> Void

    init(identifier: String, onInvalidate: @escaping (String) -> Void) {
        self.identifier = identifier
        self.onInvalidate = onInvalidate
    }

    func setHandler(_ handler: @escaping BackgroundSystemSchedulerHandler) {}

    func invalidate() {
        onInvalidate(identifier)
    }
}