import Foundation
import SwiftData

@Model
final class BackgroundAgentTask {
    var id: UUID
    var taskKey: String
    var title: String
    var isEnabled: Bool
    var sessionId: String
    var taskPrompt: String
    var systemPromptOverride: String?
    var workspacePath: String?
    var workingDirectoryPath: String?
    var modelIDOverride: String?
    var authorizationPolicyJSON: String = "{}"
    var schedulePolicyJSON: String
    var executionPolicyJSON: String
    var lastScheduledAt: Date?
    var lastTriggeredAt: Date?
    var lastCompletedAt: Date?
    var lastResultSummary: String?
    var consecutiveFailureCount: Int
    var cooldownUntil: Date?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        taskKey: String = UUID().uuidString.lowercased(),
        title: String,
        isEnabled: Bool = true,
        sessionId: String,
        taskPrompt: String,
        systemPromptOverride: String? = nil,
        workspacePath: String? = nil,
        workingDirectoryPath: String? = nil,
        modelIDOverride: String? = nil,
        authorizationPolicy: ToolAuthorizationPolicy = ToolAuthorizationPolicy(),
        schedulePolicy: BackgroundTaskPolicy = BackgroundTaskPolicy(),
        executionPolicy: BackgroundTaskExecutionPolicy = BackgroundTaskExecutionPolicy(),
        lastScheduledAt: Date? = nil,
        lastTriggeredAt: Date? = nil,
        lastCompletedAt: Date? = nil,
        lastResultSummary: String? = nil,
        consecutiveFailureCount: Int = 0,
        cooldownUntil: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.taskKey = taskKey
        self.title = title
        self.isEnabled = isEnabled
        self.sessionId = sessionId
        self.taskPrompt = taskPrompt
        self.systemPromptOverride = systemPromptOverride
        self.workspacePath = workspacePath
        self.workingDirectoryPath = workingDirectoryPath
        self.modelIDOverride = modelIDOverride
        self.authorizationPolicyJSON = Self.encode(authorizationPolicy, fallback: "{}")
        self.schedulePolicyJSON = Self.encode(schedulePolicy, fallback: "{}")
        self.executionPolicyJSON = Self.encode(executionPolicy, fallback: "{}")
        self.lastScheduledAt = lastScheduledAt
        self.lastTriggeredAt = lastTriggeredAt
        self.lastCompletedAt = lastCompletedAt
        self.lastResultSummary = lastResultSummary
        self.consecutiveFailureCount = consecutiveFailureCount
        self.cooldownUntil = cooldownUntil
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var authorizationPolicy: ToolAuthorizationPolicy {
        get { Self.decode(authorizationPolicyJSON, defaultValue: ToolAuthorizationPolicy()) }
        set { authorizationPolicyJSON = Self.encode(newValue, fallback: "{}") }
    }

    var schedulePolicy: BackgroundTaskPolicy {
        get { Self.decode(schedulePolicyJSON, defaultValue: BackgroundTaskPolicy()) }
        set { schedulePolicyJSON = Self.encode(newValue, fallback: "{}") }
    }

    var executionPolicy: BackgroundTaskExecutionPolicy {
        get { Self.decode(executionPolicyJSON, defaultValue: BackgroundTaskExecutionPolicy()) }
        set { executionPolicyJSON = Self.encode(newValue, fallback: "{}") }
    }

    private static func encode<T: Encodable>(_ value: T, fallback: String) -> String {
        (try? String(data: JSONEncoder().encode(value), encoding: .utf8)) ?? fallback
    }

    private static func decode<T: Decodable>(_ string: String, defaultValue: T) -> T {
        guard let data = string.data(using: .utf8),
              let value = try? JSONDecoder().decode(T.self, from: data) else {
            return defaultValue
        }
        return value
    }
}

extension BackgroundAgentTask {
    var dedicatedSessionSourceIdentifier: String {
        id.uuidString
    }

    func dedicatedSessionTitle(fallbackTitle: String? = nil) -> String {
        let candidate = (fallbackTitle ?? title).trimmingCharacters(in: .whitespacesAndNewlines)
        return candidate.isEmpty ? "后台任务" : candidate
    }

    func dedicatedSessionSourceDisplayName(fallbackTitle: String? = nil) -> String {
        "后台任务 · \(dedicatedSessionTitle(fallbackTitle: fallbackTitle))"
    }

    @MainActor
    static func fixture(
        taskKey: String = "background-task",
        title: String = "后台任务",
        sessionId: String = "session-1",
        taskPrompt: String = "生成后台摘要",
        cooldownUntil: Date? = nil,
        isEnabled: Bool = true
    ) -> BackgroundAgentTask {
        BackgroundAgentTask(
            taskKey: taskKey,
            title: title,
            isEnabled: isEnabled,
            sessionId: sessionId,
            taskPrompt: taskPrompt,
            cooldownUntil: cooldownUntil
        )
    }
}