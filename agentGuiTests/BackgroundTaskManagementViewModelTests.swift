import Foundation
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct BackgroundTaskManagementViewModelTests {
    @Test func saveDraftCreatesDedicatedBackgroundSessionAutomatically() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let viewModel = BackgroundTaskManagementViewModel(
            modelContext: context,
            persistenceCoordinator: nil
        )
        viewModel.makeNewTask()
        viewModel.draftTitle = "日报"
        viewModel.draftPrompt = "汇总今日进展"

        try viewModel.saveDraft()

        let task = try #require(context.fetch(FetchDescriptor<BackgroundAgentTask>()).first)
        let session = try #require(context.fetch(FetchDescriptor<Session>()).first)
        #expect(task.sessionId == session.sessionId)
        #expect(session.kind == .backgroundTask)
        #expect(session.isReadOnly)
        #expect(session.sourceIdentifier == task.id.uuidString)
        #expect(session.title == "日报")
    }

    @Test func saveDraftReusesExistingDedicatedBackgroundSessionWhenEditingTask() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let viewModel = BackgroundTaskManagementViewModel(
            modelContext: context,
            persistenceCoordinator: nil
        )
        viewModel.makeNewTask()
        viewModel.draftTitle = "日报"
        viewModel.draftPrompt = "汇总今日进展"

        try viewModel.saveDraft()

        let task = try #require(context.fetch(FetchDescriptor<BackgroundAgentTask>()).first)
        let firstSessionID = task.sessionId

        viewModel.selectTask(task)
        viewModel.draftPrompt = "更新后的提示词"

        try viewModel.saveDraft()

        let tasks = try context.fetch(FetchDescriptor<BackgroundAgentTask>())
        #expect(tasks.count == 1)
        #expect(tasks.first?.sessionId == firstSessionID)
        #expect(try context.fetch(FetchDescriptor<Session>()).count == 1)
    }

    @Test func saveDraftSynchronizesDedicatedSessionTitleWithTaskTitle() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let viewModel = BackgroundTaskManagementViewModel(
            modelContext: context,
            persistenceCoordinator: nil
        )
        viewModel.makeNewTask()
        viewModel.draftTitle = "日报"
        viewModel.draftPrompt = "汇总今日进展"

        try viewModel.saveDraft()

        let task = try #require(context.fetch(FetchDescriptor<BackgroundAgentTask>()).first)
        viewModel.selectTask(task)
        viewModel.draftTitle = "晚间日报"

        try viewModel.saveDraft()

        let session = try #require(context.fetch(FetchDescriptor<Session>()).first)
        #expect(session.sessionId == task.sessionId)
        #expect(session.title == "晚间日报")
        #expect(session.sourceDisplayName.contains("晚间日报"))
    }

    @Test func saveDraftPersistsScheduleAndExecutionEdits() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let session = Session.fixture(sessionId: "session-1", title: "日报会话")
        context.insert(session)
        try context.save()

        let viewModel = BackgroundTaskManagementViewModel(
            modelContext: context,
            persistenceCoordinator: nil
        )
        viewModel.makeNewTask()
        viewModel.draftTitle = "日报"
        viewModel.draftPrompt = "汇总今日进展"
        viewModel.draftSessionID = session.sessionId
        viewModel.draftSchedulePolicy.baseIntervalSeconds = 10_800
        viewModel.draftSchedulePolicy.toleranceSeconds = 900
        viewModel.draftExecutionPolicy.maxTurns = 6
        viewModel.draftExecutionPolicy.maxExecutionSeconds = 180

        try viewModel.saveDraft()

        let task = try #require(context.fetch(FetchDescriptor<BackgroundAgentTask>()).first)
        #expect(task.schedulePolicy.baseIntervalSeconds == 10_800)
        #expect(task.schedulePolicy.toleranceSeconds == 900)
        #expect(task.executionPolicy.maxTurns == 6)
        #expect(task.executionPolicy.maxExecutionSeconds == 180)
    }

    @Test func saveDraftPersistsAllowedWeekdaysAndHourRange() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let session = Session.fixture(sessionId: "session-1", title: "日报会话")
        context.insert(session)
        try context.save()

        let viewModel = BackgroundTaskManagementViewModel(
            modelContext: context,
            persistenceCoordinator: nil
        )
        viewModel.makeNewTask()
        viewModel.draftTitle = "工作日白天巡检"
        viewModel.draftPrompt = "检查未处理告警"
        viewModel.draftSessionID = session.sessionId
        viewModel.setAllowedWeekday(2, enabled: true)
        viewModel.setAllowedWeekday(3, enabled: true)
        viewModel.setAllowedWeekday(4, enabled: true)
        viewModel.setAllowedWeekday(5, enabled: true)
        viewModel.setAllowedWeekday(6, enabled: true)
        viewModel.setAllowedHourRangeEnabled(true)
        viewModel.setAllowedHourStart(9)
        viewModel.setAllowedHourEnd(18)

        try viewModel.saveDraft()

        let task = try #require(context.fetch(FetchDescriptor<BackgroundAgentTask>()).first)
        #expect(task.schedulePolicy.allowedWeekdays == [2, 3, 4, 5, 6])
        #expect(task.schedulePolicy.allowedHourRange == 9...18)
    }

    @Test func saveDraftPostsSchedulingRefreshNotification() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let session = Session.fixture(sessionId: "session-1", title: "日报会话")
        context.insert(session)
        try context.save()
        let notificationCenter = NotificationCenter()
        let viewModel = BackgroundTaskManagementViewModel(
            modelContext: context,
            persistenceCoordinator: nil,
            notificationCenter: notificationCenter
        )
        viewModel.makeNewTask()
        viewModel.draftTitle = "日报"
        viewModel.draftPrompt = "汇总今日进展"
        viewModel.draftSessionID = session.sessionId
        let recorder = NotificationRecorder(center: notificationCenter)

        try viewModel.saveDraft()

        #expect(recorder.count(for: BackgroundTaskSchedulingNotifications.refreshRequested) == 1)
    }

    @Test func toggleTaskEnabledPostsSchedulingRefreshNotification() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let session = Session.fixture(sessionId: "session-1", title: "日报会话")
        let task = BackgroundAgentTask.fixture(taskKey: "daily", title: "日报", sessionId: session.sessionId)
        context.insert(session)
        context.insert(task)
        try context.save()
        let notificationCenter = NotificationCenter()
        let viewModel = BackgroundTaskManagementViewModel(
            modelContext: context,
            persistenceCoordinator: nil,
            notificationCenter: notificationCenter
        )
        let recorder = NotificationRecorder(center: notificationCenter)

        viewModel.toggleTaskEnabled(task, isEnabled: false)

        #expect(recorder.count(for: BackgroundTaskSchedulingNotifications.refreshRequested) == 1)
    }

    @Test func selectingObserveOnlyPresetClearsEscalatedToolToggles() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let viewModel = BackgroundTaskManagementViewModel(
            modelContext: context,
            persistenceCoordinator: nil
        )
        viewModel.draftAuthorizationPolicy = ToolAuthorizationPolicy(preset: .actLimited)

        viewModel.setDraftAuthorizationPreset(.observeOnly)

        #expect(viewModel.draftAuthorizationPolicy.preset == .observeOnly)
        #expect(viewModel.draftAuthorizationPolicy.level(for: .fileSystem) == .disabled)
        #expect(viewModel.draftAuthorizationPolicy.level(for: .shell) == .disabled)
        #expect(viewModel.draftAuthorizationPolicy.level(for: .memory) == .disabled)
        #expect(viewModel.draftAuthorizationPolicy.level(for: .network) == .observe)
    }

    @Test func selectingMaintainPresetKeepsOnlyAllowedToggles() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let viewModel = BackgroundTaskManagementViewModel(
            modelContext: context,
            persistenceCoordinator: nil
        )
        viewModel.draftAuthorizationPolicy = ToolAuthorizationPolicy(preset: .actLimited)

        viewModel.setDraftAuthorizationPreset(.maintain)

        #expect(viewModel.draftAuthorizationPolicy.preset == .maintain)
        #expect(viewModel.draftAuthorizationPolicy.level(for: .fileSystem) == .disabled)
        #expect(viewModel.draftAuthorizationPolicy.level(for: .shell) == .disabled)
        #expect(viewModel.draftAuthorizationPolicy.level(for: .memory) == .mutate)
        #expect(viewModel.draftAuthorizationPolicy.level(for: .network) == .observe)
    }

    @Test func authorizationPresetDescriptionsExplainToolScope() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let viewModel = BackgroundTaskManagementViewModel(
            modelContext: context,
            persistenceCoordinator: nil
        )

        #expect(viewModel.authorizationPresetDescription(for: .observeOnly).contains("只读"))
        #expect(viewModel.authorizationPresetDescription(for: .maintain).contains("记忆"))
        #expect(viewModel.authorizationPresetDescription(for: .actLimited).contains("文件写入"))
    }

    @Test func saveDraftRejectsMissingPromptWithoutSessionSelection() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let viewModel = BackgroundTaskManagementViewModel(
            modelContext: context,
            persistenceCoordinator: nil
        )
        viewModel.makeNewTask()
        viewModel.draftTitle = "日报"
        viewModel.draftPrompt = "   "

        #expect(throws: BackgroundTaskManagementViewModel.ValidationError.self) {
            try viewModel.saveDraft()
        }
    }

    @Test func selectingTaskLoadsRecentRunsInReverseChronologicalOrder() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let session = Session.fixture(sessionId: "session-1", title: "日报会话")
        let task = BackgroundAgentTask.fixture(taskKey: "daily", title: "日报", sessionId: session.sessionId)
        let olderRun = BackgroundAgentTaskRun(
            taskID: task.id,
            schedulerIdentifier: "scheduler.daily",
            status: .completed,
            decision: .run,
            resultSummary: "older",
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let newerRun = BackgroundAgentTaskRun(
            taskID: task.id,
            schedulerIdentifier: "scheduler.daily",
            status: .failed,
            decision: .run,
            resultSummary: "newer",
            createdAt: Date(timeIntervalSince1970: 200)
        )
        context.insert(session)
        context.insert(task)
        context.insert(olderRun)
        context.insert(newerRun)
        try context.save()

        let viewModel = BackgroundTaskManagementViewModel(
            modelContext: context,
            persistenceCoordinator: nil
        )

        viewModel.selectTask(task)

        #expect(viewModel.selectedTask?.id == task.id)
        #expect(viewModel.recentRuns.map(\.resultSummary) == ["newer", "older"])
    }

    @Test func visibleTasksFiltersBySearchAndAttentionState() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let session = Session.fixture(sessionId: "session-1", title: "日报会话")
        let healthy = BackgroundAgentTask.fixture(taskKey: "daily", title: "日报", sessionId: session.sessionId)
        let attention = BackgroundAgentTask.fixture(taskKey: "ops", title: "巡检", sessionId: session.sessionId)
        attention.consecutiveFailureCount = 2
        attention.cooldownUntil = Date(timeIntervalSince1970: 1_000)
        let disabled = BackgroundAgentTask.fixture(taskKey: "off", title: "停用任务", sessionId: session.sessionId, isEnabled: false)
        context.insert(session)
        context.insert(healthy)
        context.insert(attention)
        context.insert(disabled)
        try context.save()

        let viewModel = BackgroundTaskManagementViewModel(
            modelContext: context,
            persistenceCoordinator: nil
        )

        #expect(Set(viewModel.visibleTasks.map(\.taskKey)) == Set(["daily", "ops", "off"]))

        viewModel.searchText = "巡"
        #expect(viewModel.visibleTasks.map(\.taskKey) == ["ops"])

        viewModel.searchText = ""
        viewModel.listFilter = .attention
        #expect(viewModel.visibleTasks.map(\.taskKey) == ["ops"])

        viewModel.listFilter = .enabled
        #expect(Set(viewModel.visibleTasks.map(\.taskKey)) == Set(["daily", "ops"]))
    }

    @Test func estimatedNextRunUsesCooldownWhenLaterThanSchedule() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let session = Session.fixture(sessionId: "session-1", title: "日报会话")
        let task = BackgroundAgentTask.fixture(taskKey: "daily", title: "日报", sessionId: session.sessionId)
        task.createdAt = Date(timeIntervalSince1970: 0)
        task.lastTriggeredAt = Date(timeIntervalSince1970: 3_600)
        task.cooldownUntil = Date(timeIntervalSince1970: 10_800)
        var policy = task.schedulePolicy
        policy.baseIntervalSeconds = 3_600
        task.schedulePolicy = policy
        context.insert(session)
        context.insert(task)
        try context.save()

        let viewModel = BackgroundTaskManagementViewModel(
            modelContext: context,
            persistenceCoordinator: nil
        )
        let calendar = Calendar(identifier: .gregorian)

        let nextRun = viewModel.estimatedNextRun(
            for: task,
            now: Date(timeIntervalSince1970: 4_000),
            calendar: calendar,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        #expect(nextRun == Date(timeIntervalSince1970: 10_800))
    }

    @Test func estimatedNextRunAlignsToAllowedHourRangeInRequestedTimeZone() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let session = Session.fixture(sessionId: "session-1", title: "日报会话")
        let task = BackgroundAgentTask.fixture(taskKey: "daily", title: "日报", sessionId: session.sessionId)
        task.createdAt = Date(timeIntervalSince1970: 0)
        task.lastTriggeredAt = Date(timeIntervalSince1970: 1_800)
        var policy = task.schedulePolicy
        policy.baseIntervalSeconds = 3_600
        policy.allowedHourRange = 10...18
        task.schedulePolicy = policy
        context.insert(session)
        context.insert(task)
        try context.save()

        let viewModel = BackgroundTaskManagementViewModel(
            modelContext: context,
            persistenceCoordinator: nil
        )
        let shanghai = try #require(TimeZone(identifier: "Asia/Shanghai"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = shanghai

        let nextRun = try #require(viewModel.estimatedNextRun(
            for: task,
            now: Date(timeIntervalSince1970: 2_000),
            calendar: calendar,
            timeZone: shanghai
        ))

        let components = calendar.dateComponents([.hour, .minute], from: nextRun)
        #expect(components.hour == 10)
        #expect(components.minute == 0)
    }

    @Test func taskListSubtitleUsesSessionTitle() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let session = Session.fixture(sessionId: "session-1", title: "日报会话")
        let task = BackgroundAgentTask.fixture(taskKey: "daily", title: "日报", sessionId: session.sessionId)
        context.insert(session)
        context.insert(task)
        try context.save()

        let viewModel = BackgroundTaskManagementViewModel(
            modelContext: context,
            persistenceCoordinator: nil
        )

        #expect(viewModel.taskListSubtitle(for: task) == "日报会话")
    }

    @Test func editorTitleUsesTaskTitleForExistingTask() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let session = Session.fixture(sessionId: "session-1", title: "日报会话")
        let task = BackgroundAgentTask.fixture(taskKey: "daily", title: "日报", sessionId: session.sessionId)
        context.insert(session)
        context.insert(task)
        try context.save()

        let viewModel = BackgroundTaskManagementViewModel(
            modelContext: context,
            persistenceCoordinator: nil
        )

        #expect(viewModel.editorTitle(for: nil) == "新建后台任务")
        #expect(viewModel.editorTitle(for: task) == "日报")
    }

    @Test func scheduleIntervalSummarySupportsMinutePrecision() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let viewModel = BackgroundTaskManagementViewModel(
            modelContext: context,
            persistenceCoordinator: nil
        )

        #expect(viewModel.scheduleIntervalSummary(seconds: 300) == "5 分钟")
        #expect(viewModel.scheduleIntervalSummary(seconds: 5_400) == "1 小时 30 分钟")
    }

    @Test func applyingScheduleIntervalPresetUpdatesDraftPolicy() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let viewModel = BackgroundTaskManagementViewModel(
            modelContext: context,
            persistenceCoordinator: nil
        )
        viewModel.draftSchedulePolicy.toleranceSeconds = 20_000

        let preset = try #require(viewModel.scheduleIntervalPresets.first { $0.id == "6h" })
        viewModel.applyScheduleIntervalPreset(preset)

        #expect(viewModel.draftSchedulePolicy.baseIntervalSeconds == 21_600)
        #expect(viewModel.draftSchedulePolicy.toleranceSeconds == 3_600)
    }

    @Test func toleranceUpperBoundTracksMinuteLevelInterval() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let viewModel = BackgroundTaskManagementViewModel(
            modelContext: context,
            persistenceCoordinator: nil
        )
        let policy = BackgroundTaskPolicy(baseIntervalSeconds: 300, toleranceSeconds: 60)

        #expect(viewModel.toleranceUpperBoundMinutes(for: policy) == 4)
    }

    @Test func estimatedNextRunAlignsToAllowedWeekdayAndHourWindow() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let session = Session.fixture(sessionId: "session-1", title: "日报会话")
        let task = BackgroundAgentTask.fixture(taskKey: "weekday-window", title: "工作日巡检", sessionId: session.sessionId)
        task.createdAt = Date(timeIntervalSince1970: 0)
        task.lastTriggeredAt = Date(timeIntervalSince1970: 86_400)
        var policy = task.schedulePolicy
        policy.baseIntervalSeconds = 86_400
        policy.allowedWeekdays = [2, 3, 4, 5, 6]
        policy.allowedHourRange = 9...18
        task.schedulePolicy = policy
        context.insert(session)
        context.insert(task)
        try context.save()

        let viewModel = BackgroundTaskManagementViewModel(
            modelContext: context,
            persistenceCoordinator: nil
        )
        let utc = TimeZone(secondsFromGMT: 0)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc

        let nextRun = try #require(viewModel.estimatedNextRun(
            for: task,
            now: Date(timeIntervalSince1970: 200_000),
            calendar: calendar,
            timeZone: utc
        ))

        let components = calendar.dateComponents([.weekday, .hour, .minute], from: nextRun)
        #expect(components.weekday == 2)
        #expect(components.hour == 9)
        #expect(components.minute == 0)
    }

    private func makeContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: Session.self,
            BackgroundAgentTask.self,
            BackgroundAgentTaskRun.self,
            configurations: configuration
        )
    }
}

@MainActor
private final class NotificationRecorder {
    private var counts: [Notification.Name: Int] = [:]
    private var token: NSObjectProtocol?
    private let center: NotificationCenter

    init(center: NotificationCenter) {
        self.center = center
        token = center.addObserver(
            forName: nil,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            self?.counts[notification.name, default: 0] += 1
        }
    }

    deinit {
        if let token {
            center.removeObserver(token)
        }
    }

    func count(for name: Notification.Name) -> Int {
        counts[name, default: 0]
    }
}