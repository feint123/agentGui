import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class BackgroundTaskManagementViewModel {
    enum ListFilter: String, CaseIterable {
        case all
        case enabled
        case attention

        var title: String {
            switch self {
            case .all:
                return "全部"
            case .enabled:
                return "启用中"
            case .attention:
                return "需关注"
            }
        }
    }

    struct SessionOption: Identifiable, Equatable {
        let id: String
        let title: String
        let detail: String
    }

    struct NextRunPresentation: Equatable {
        let value: String
        let detail: String
    }

    struct ScheduleIntervalPreset: Identifiable, Equatable, Hashable {
        let id: String
        let seconds: TimeInterval
        let toleranceSeconds: TimeInterval
        let title: String
        let detail: String
    }

    struct WeekdayOption: Identifiable, Equatable {
        let id: Int
        let weekday: Int
        let shortTitle: String
        let fullTitle: String
    }

    enum ValidationError: Error, Equatable {
        case missingTitle
        case missingSession
        case missingPrompt
    }

    private let modelContext: ModelContext
    private let persistenceCoordinator: PersistenceCoordinator?
    private let notificationCenter: NotificationCenter
    private let sessionFactory: BackgroundTaskSessionFactory

    private(set) var tasks: [BackgroundAgentTask] = []
    private(set) var sessionOptions: [SessionOption] = []
    private(set) var recentRuns: [BackgroundAgentTaskRun] = []
    private(set) var selectedTask: BackgroundAgentTask?

    var searchText: String = ""
    var listFilter: ListFilter = .all
    var draftTitle: String = ""
    var draftPrompt: String = ""
    var draftSessionID: String?
    var draftWorkspacePath: String = ""
    var draftWorkingDirectoryPath: String = ""
    var draftSystemPromptOverride: String = ""
    var draftModelIDOverride: String = ""
    var draftIsEnabled: Bool = true
    var draftSchedulePolicy: BackgroundTaskPolicy = BackgroundTaskPolicy()
    var draftExecutionPolicy: BackgroundTaskExecutionPolicy = BackgroundTaskExecutionPolicy()
    var draftAuthorizationPolicy: ToolAuthorizationPolicy = ToolAuthorizationPolicy()

    var scheduleIntervalPresets: [ScheduleIntervalPreset] {
        Self.defaultScheduleIntervalPresets
    }

    var scheduleIntervalPresetOptions: [ScheduleIntervalPreset] {
        let currentSeconds = max(1, draftSchedulePolicy.baseIntervalSeconds)
        guard scheduleIntervalPreset(for: currentSeconds) == nil else {
            return scheduleIntervalPresets
        }

        return [
            ScheduleIntervalPreset(
                id: customScheduleIntervalPresetID(seconds: currentSeconds),
                seconds: currentSeconds,
                toleranceSeconds: draftSchedulePolicy.sanitizedToleranceSeconds,
                title: "自定义 \(scheduleIntervalSummary(seconds: currentSeconds))",
                detail: "历史任务保留当前间隔，重新选择后会切换到预设档位。"
            )
        ] + scheduleIntervalPresets
    }

    var selectedScheduleIntervalPresetID: String {
        scheduleIntervalPreset(for: draftSchedulePolicy.baseIntervalSeconds)?.id
            ?? customScheduleIntervalPresetID(seconds: draftSchedulePolicy.baseIntervalSeconds)
    }

    var selectedScheduleIntervalPresetDetail: String {
        scheduleIntervalPresetOptions.first(where: { $0.id == selectedScheduleIntervalPresetID })?.detail
            ?? "预设会同时更新建议容差。"
    }

    var weekdayOptions: [WeekdayOption] {
        let calendar = Calendar.autoupdatingCurrent
        let shortSymbols = calendar.veryShortWeekdaySymbols
        let fullSymbols = calendar.weekdaySymbols
        let firstWeekday = calendar.firstWeekday

        return (0..<7).map { offset in
            let weekday = ((firstWeekday - 1 + offset) % 7) + 1
            return WeekdayOption(
                id: weekday,
                weekday: weekday,
                shortTitle: shortSymbols[weekday - 1],
                fullTitle: fullSymbols[weekday - 1]
            )
        }
    }

    init(
        modelContext: ModelContext,
        persistenceCoordinator: PersistenceCoordinator?,
        notificationCenter: NotificationCenter = .default,
        sessionFactory: BackgroundTaskSessionFactory = BackgroundTaskSessionFactory()
    ) {
        self.modelContext = modelContext
        self.persistenceCoordinator = persistenceCoordinator
        self.notificationCenter = notificationCenter
        self.sessionFactory = sessionFactory
        refresh()
        if selectedTask == nil {
            makeNewTask()
        }
    }

    func refresh() {
        tasks = (try? modelContext.fetch(FetchDescriptor<BackgroundAgentTask>()))?
            .sorted { lhs, rhs in
                if lhs.updatedAt == rhs.updatedAt {
                    return lhs.createdAt > rhs.createdAt
                }
                return lhs.updatedAt > rhs.updatedAt
            } ?? []

        sessionOptions = (try? modelContext.fetch(FetchDescriptor<Session>()))?
            .sorted { lhs, rhs in
                if lhs.updatedAt == rhs.updatedAt {
                    return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                }
                return lhs.updatedAt > rhs.updatedAt
            }
            .map {
                SessionOption(
                    id: $0.sessionId,
                    title: $0.title,
                    detail: $0.lastMessagePreview
                )
            } ?? []

        if let selectedTaskID = selectedTask?.id,
           let refreshedTask = tasks.first(where: { $0.id == selectedTaskID }) {
            selectedTask = refreshedTask
            loadDraft(from: refreshedTask)
        } else if selectedTask != nil {
            selectedTask = nil
            makeNewTask()
        }

        loadRecentRuns()
    }

    var visibleTasks: [BackgroundAgentTask] {
        tasks.filter { task in
            matchesFilter(task) && matchesSearch(task)
        }
    }

    func makeNewTask() {
        selectedTask = nil
        draftTitle = ""
        draftPrompt = ""
        draftSessionID = sessionOptions.first?.id
        draftWorkspacePath = ""
        draftWorkingDirectoryPath = ""
        draftSystemPromptOverride = ""
        draftModelIDOverride = ""
        draftIsEnabled = true
        draftSchedulePolicy = BackgroundTaskPolicy()
        draftExecutionPolicy = BackgroundTaskExecutionPolicy()
        draftAuthorizationPolicy = ToolAuthorizationPolicy()
        recentRuns = []
    }

    func selectTask(_ task: BackgroundAgentTask) {
        selectedTask = task
        loadDraft(from: task)
        loadRecentRuns()
    }

    func saveDraft() throws {
        let title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = draftPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw ValidationError.missingTitle }
        guard !prompt.isEmpty else { throw ValidationError.missingPrompt }

        if let selectedTask {
            selectedTask.title = title
            selectedTask.taskPrompt = prompt
            selectedTask.workspacePath = normalizedOptional(draftWorkspacePath)
            selectedTask.workingDirectoryPath = normalizedOptional(draftWorkingDirectoryPath)
            selectedTask.systemPromptOverride = normalizedOptional(draftSystemPromptOverride)
            selectedTask.modelIDOverride = normalizedOptional(draftModelIDOverride)
            selectedTask.isEnabled = draftIsEnabled
            selectedTask.schedulePolicy = draftSchedulePolicy
            selectedTask.executionPolicy = draftExecutionPolicy
            selectedTask.authorizationPolicy = draftAuthorizationPolicy
            selectedTask.updatedAt = Date()
            let session = try sessionFactory.ensureSession(for: selectedTask, desiredTitle: title, modelContext: modelContext)
            selectedTask.sessionId = session.sessionId
        } else {
            let task = BackgroundAgentTask(
                title: title,
                isEnabled: draftIsEnabled,
                sessionId: "",
                taskPrompt: prompt,
                systemPromptOverride: normalizedOptional(draftSystemPromptOverride),
                workspacePath: normalizedOptional(draftWorkspacePath),
                workingDirectoryPath: normalizedOptional(draftWorkingDirectoryPath),
                modelIDOverride: normalizedOptional(draftModelIDOverride),
                authorizationPolicy: draftAuthorizationPolicy,
                schedulePolicy: draftSchedulePolicy,
                executionPolicy: draftExecutionPolicy
            )
            modelContext.insert(task)
            let session = try sessionFactory.ensureSession(for: task, desiredTitle: title, modelContext: modelContext)
            task.sessionId = session.sessionId
            selectedTask = task
        }

        try persist("后台任务未成功保存")
        BackgroundTaskSchedulingNotifications.postRefresh(on: notificationCenter)
        refresh()
    }

    func deleteSelectedTask() throws {
        guard let selectedTask else { return }
        modelContext.delete(selectedTask)
        try persist("后台任务未成功删除")
        BackgroundTaskSchedulingNotifications.postRefresh(on: notificationCenter)
        makeNewTask()
        refresh()
    }

    func toggleTaskEnabled(_ task: BackgroundAgentTask, isEnabled: Bool) {
        task.isEnabled = isEnabled
        task.updatedAt = Date()
        do {
            try persist("后台任务状态未成功保存")
            BackgroundTaskSchedulingNotifications.postRefresh(on: notificationCenter)
        } catch {
            return
        }
        refresh()
    }

    func sessionOption(for sessionID: String?) -> SessionOption? {
        guard let sessionID else { return nil }
        return sessionOptions.first(where: { $0.id == sessionID })
    }

    func requiresAttention(_ task: BackgroundAgentTask) -> Bool {
        task.consecutiveFailureCount > 0 || task.cooldownUntil != nil
    }

    func summaryText(for task: BackgroundAgentTask) -> String {
        if let summary = task.lastResultSummary, !summary.isEmpty {
            return summary
        }
        return task.taskPrompt
    }

    func setDraftAuthorizationPreset(_ preset: ToolAuthorizationPreset) {
        var editorModel = ToolPermissionEditorModel(policy: draftAuthorizationPolicy)
        editorModel.setPreset(preset)
        draftAuthorizationPolicy = editorModel.policy
    }

    func authorizationPresetDescription(for preset: ToolAuthorizationPreset) -> String {
        ToolPermissionEditorModel(policy: draftAuthorizationPolicy).presetDescription(for: preset)
    }

    func isDraftToolOptionAvailable(_ option: ToolPermissionEditorModel.Option) -> Bool {
        ToolPermissionEditorModel(policy: draftAuthorizationPolicy).isOptionAvailable(option)
    }

    func draftToolRestrictionExplanation(for option: ToolPermissionEditorModel.Option) -> String? {
        ToolPermissionEditorModel(policy: draftAuthorizationPolicy).restrictionExplanation(for: option)
    }

    func taskListSubtitle(for task: BackgroundAgentTask) -> String {
        sessionOption(for: task.sessionId)?.title ?? task.dedicatedSessionTitle()
    }

    var draftDedicatedSessionTitle: String {
        if let selectedTask {
            return sessionOption(for: selectedTask.sessionId)?.title ?? selectedTask.dedicatedSessionTitle(fallbackTitle: draftTitle)
        }

        let trimmed = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "后台任务" : trimmed
    }

    var draftDedicatedSessionBindingSummary: String {
        if let selectedTask, selectedTask.sessionId.isEmpty == false {
            return "已绑定专属只读会话"
        }
        return "保存后自动创建专属只读会话"
    }

    var draftDedicatedSessionDetail: String {
        if let selectedTask,
           let session = sessionOption(for: selectedTask.sessionId),
           session.detail.isEmpty == false {
            return session.detail
        }
        return "执行结果和失败摘要都会只写回这个后台任务的专属会话。"
    }

    func editorTitle(for task: BackgroundAgentTask?) -> String {
        guard let task else { return "新建后台任务" }
        return task.title
    }

    func scheduleIntervalSummary(seconds: TimeInterval) -> String {
        let totalMinutes = max(1, Int(seconds / 60))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours == 0 {
            return "\(totalMinutes) 分钟"
        }

        if minutes == 0 {
            return "\(hours) 小时"
        }

        return "\(hours) 小时 \(minutes) 分钟"
    }

    func applyScheduleIntervalPreset(_ preset: ScheduleIntervalPreset) {
        draftSchedulePolicy.baseIntervalSeconds = preset.seconds
        draftSchedulePolicy.toleranceSeconds = min(preset.toleranceSeconds, draftSchedulePolicy.sanitizedToleranceSeconds)
    }

    func applyScheduleIntervalPreset(id: String) {
        guard let preset = scheduleIntervalPresetOptions.first(where: { $0.id == id }) else { return }
        applyScheduleIntervalPreset(preset)
    }

    func isAllowedWeekday(_ weekday: Int) -> Bool {
        draftSchedulePolicy.sanitizedAllowedWeekdays.contains(weekday)
    }

    func setAllowedWeekday(_ weekday: Int, enabled: Bool) {
        var weekdays = Set(draftSchedulePolicy.sanitizedAllowedWeekdays)
        if enabled {
            weekdays.insert(weekday)
        } else {
            weekdays.remove(weekday)
        }
        draftSchedulePolicy.allowedWeekdays = weekdays.sorted()
    }

    func allowedWeekdaysSummary(for policy: BackgroundTaskPolicy) -> String {
        let weekdays = policy.sanitizedAllowedWeekdays
        guard !weekdays.isEmpty else { return "每天" }

        return weekdayOptions
            .filter { weekdays.contains($0.weekday) }
            .map(\.shortTitle)
            .joined(separator: " ")
    }

    func setAllowedHourRangeEnabled(_ enabled: Bool) {
        if enabled {
            draftSchedulePolicy.allowedHourRange = draftSchedulePolicy.sanitizedAllowedHourRange ?? Self.defaultAllowedHourRange
        } else {
            draftSchedulePolicy.allowedHourRange = nil
        }
    }

    func setAllowedHourStart(_ hour: Int) {
        let normalizedHour = min(max(hour, 0), 23)
        let range = draftSchedulePolicy.sanitizedAllowedHourRange ?? Self.defaultAllowedHourRange
        draftSchedulePolicy.allowedHourRange = normalizedHour...max(normalizedHour, range.upperBound)
    }

    func setAllowedHourEnd(_ hour: Int) {
        let normalizedHour = min(max(hour, 0), 23)
        let range = draftSchedulePolicy.sanitizedAllowedHourRange ?? Self.defaultAllowedHourRange
        draftSchedulePolicy.allowedHourRange = min(range.lowerBound, normalizedHour)...normalizedHour
    }

    func allowedHourRangeSummary(for policy: BackgroundTaskPolicy) -> String {
        guard let range = policy.sanitizedAllowedHourRange else { return "全天" }
        return "\(hourLabel(range.lowerBound)) - \(hourLabel(range.upperBound))"
    }

    func toleranceUpperBoundMinutes(for policy: BackgroundTaskPolicy) -> Int {
        let intervalMinutes = max(1, Int(policy.sanitizedForScheduling.baseIntervalSeconds / 60))
        return min(180, max(0, intervalMinutes - 1))
    }

    func estimatedNextRun(
        for task: BackgroundAgentTask,
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> Date? {
        let policy = task.schedulePolicy.sanitizedForScheduling
        guard task.isEnabled else { return nil }
        if !policy.repeats, task.lastTriggeredAt != nil {
            return nil
        }

        var calendar = calendar
        calendar.timeZone = timeZone

        let anchor = [task.lastTriggeredAt, task.lastScheduledAt, task.createdAt]
            .compactMap { $0 }
            .max() ?? now

        var nextRun = anchor.addingTimeInterval(policy.baseIntervalSeconds)
        if policy.repeats, nextRun < now {
            let elapsed = now.timeIntervalSince(anchor)
            let stepCount = max(1, Int(ceil(elapsed / policy.baseIntervalSeconds)))
            nextRun = anchor.addingTimeInterval(Double(stepCount) * policy.baseIntervalSeconds)
        }

        if let cooldownUntil = task.cooldownUntil, cooldownUntil > nextRun {
            nextRun = cooldownUntil
        }

        return alignedToAllowedWindow(nextRun, policy: policy, calendar: calendar)
    }

    func nextRunPresentation(
        for task: BackgroundAgentTask,
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> NextRunPresentation {
        guard let nextRun = estimatedNextRun(for: task, now: now, calendar: calendar, timeZone: timeZone) else {
            return NextRunPresentation(
                value: task.isEnabled ? "暂不安排" : "已停用",
                detail: task.isEnabled ? "当前配置下没有可估算的后续触发" : "启用后才会再次加入调度"
            )
        }

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.locale = Locale.autoupdatingCurrent
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return NextRunPresentation(
            value: formatter.string(from: nextRun),
            detail: "按本地时区 \(timeZoneDisplayName(timeZone)) 估算"
        )
    }

    func timeZoneDisplayName(_ timeZone: TimeZone = .autoupdatingCurrent) -> String {
        let abbreviation = timeZone.localizedName(for: .shortStandard, locale: .autoupdatingCurrent) ?? timeZone.identifier
        let seconds = timeZone.secondsFromGMT()
        let hours = seconds / 3600
        let minutes = abs(seconds / 60) % 60
        return String(format: "%@ (GMT%+.2d:%02d)", abbreviation, hours, minutes)
    }

    private func loadDraft(from task: BackgroundAgentTask) {
        draftTitle = task.title
        draftPrompt = task.taskPrompt
        draftSessionID = task.sessionId
        draftWorkspacePath = task.workspacePath ?? ""
        draftWorkingDirectoryPath = task.workingDirectoryPath ?? ""
        draftSystemPromptOverride = task.systemPromptOverride ?? ""
        draftModelIDOverride = task.modelIDOverride ?? ""
        draftIsEnabled = task.isEnabled
        draftSchedulePolicy = task.schedulePolicy
        draftExecutionPolicy = task.executionPolicy
        draftAuthorizationPolicy = task.authorizationPolicy
    }

    private func loadRecentRuns() {
        guard let selectedTask else {
            recentRuns = []
            return
        }

        recentRuns = ((try? modelContext.fetch(FetchDescriptor<BackgroundAgentTaskRun>())) ?? [])
            .filter { $0.taskID == selectedTask.id }
            .sorted { lhs, rhs in
                if lhs.createdAt == rhs.createdAt {
                    return lhs.id.uuidString > rhs.id.uuidString
                }
                return lhs.createdAt > rhs.createdAt
            }
    }

    private func persist(_ userMessage: String) throws {
        if let persistenceCoordinator {
            try persistenceCoordinator.save(modelContext, domain: .settings, userMessage: userMessage)
        } else {
            try modelContext.save()
        }
    }

    private func normalizedOptional(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func matchesFilter(_ task: BackgroundAgentTask) -> Bool {
        switch listFilter {
        case .all:
            return true
        case .enabled:
            return task.isEnabled
        case .attention:
            return requiresAttention(task)
        }
    }

    private func matchesSearch(_ task: BackgroundAgentTask) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }

        let sessionTitle = sessionOption(for: task.sessionId)?.title ?? task.dedicatedSessionTitle()
        return task.title.localizedStandardContains(query)
            || task.taskPrompt.localizedStandardContains(query)
            || sessionTitle.localizedStandardContains(query)
    }

    private func alignedToAllowedWindow(
        _ date: Date,
        policy: BackgroundTaskPolicy,
        calendar: Calendar
    ) -> Date {
        guard !policy.allowedWeekdays.isEmpty || policy.allowedHourRange != nil else {
            return date
        }

        var candidate = date
        for _ in 0..<400 {
            if let hourRange = policy.allowedHourRange {
                let hour = calendar.component(.hour, from: candidate)
                if hour < hourRange.lowerBound {
                    candidate = calendar.date(bySettingHour: hourRange.lowerBound, minute: 0, second: 0, of: candidate) ?? candidate
                } else if hour > hourRange.upperBound {
                    let nextDay = calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
                    candidate = calendar.date(bySettingHour: hourRange.lowerBound, minute: 0, second: 0, of: nextDay) ?? nextDay
                    continue
                }
            }

            if !policy.allowedWeekdays.isEmpty {
                let weekday = calendar.component(.weekday, from: candidate)
                if !policy.allowedWeekdays.contains(weekday) {
                    let nextDay = calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
                    if let startHour = policy.allowedHourRange?.lowerBound {
                        candidate = calendar.date(bySettingHour: startHour, minute: 0, second: 0, of: nextDay) ?? nextDay
                    } else {
                        candidate = nextDay
                    }
                    continue
                }
            }

            return candidate
        }

        return candidate
    }
}

extension BackgroundTaskManagementViewModel {
    private static let defaultScheduleIntervalPresets: [ScheduleIntervalPreset] = [
        //30
        ScheduleIntervalPreset(id: "30m", seconds: 1_800, toleranceSeconds: 300, title: "每 30 分钟", detail: "适合高频巡检，建议容差 5 分钟。"),
        //1h
        ScheduleIntervalPreset(id: "1h", seconds: 3_600, toleranceSeconds: 600, title: "每 1 小时", detail: "适合频繁巡检，建议容差 10 分钟。"),
        //2h
        ScheduleIntervalPreset(id: "2h", seconds: 7_200, toleranceSeconds: 1_800, title: "每 2 小时", detail: "适合较频繁巡检，建议容差 30 分钟。"),
        //6h
        ScheduleIntervalPreset(id: "6h", seconds: 21_600, toleranceSeconds: 3_600, title: "每 6 小时", detail: "默认日常档，兼顾时效和资源占用。"),
        //12h
        ScheduleIntervalPreset(id: "12h", seconds: 43_200, toleranceSeconds: 7_200, title: "每 12 小时", detail: "适合半天一次的维护或汇总任务。"),
        //24h
        ScheduleIntervalPreset(id: "24h", seconds: 86_400, toleranceSeconds: 7_200, title: "每天一次", detail: "适合日报、归档和低频后台维护。")
    ]

    private static let defaultAllowedHourRange = 9...18

    private func scheduleIntervalPreset(for seconds: TimeInterval) -> ScheduleIntervalPreset? {
        scheduleIntervalPresets.first { Int($0.seconds) == max(1, Int(seconds)) }
    }

    private func customScheduleIntervalPresetID(seconds: TimeInterval) -> String {
        "custom-\(max(1, Int(seconds)))"
    }

    private func hourLabel(_ hour: Int) -> String {
        let normalizedHour = min(max(hour, 0), 23)
        let paddedHour = normalizedHour < 10 ? "0\(normalizedHour)" : "\(normalizedHour)"
        return "\(paddedHour):00"
    }
}