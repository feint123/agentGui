// agentGui/Services/SubagentGovernance/SubagentBackgroundExecutor.swift
import Foundation
import SwiftData
import SwiftAnthropic

// MARK: - Launch Params

/// S-C2/C4: 子代理执行闭包类型。
/// - `progressCallback`: S-C3 进度追踪回调（每轮触发）
/// - `summaryCallbacks`: S-C4 摘要器回调（context 捕获一次 + 消息快照每轮触发），nil = 不摘要
typealias SubagentLaunchClosure = @MainActor (
    _ task: String,
    _ definition: WorkflowRoleDefinition,
    _ progressCallback: (@MainActor @Sendable (SubagentProgress) -> Void)?,
    _ summaryCallbacks: SubagentSummaryCallbacks?
) async -> SubagentLaunchResult

/// S-C2: 后台子代理启动参数包（从 CoordinatorBuilder 传入，避免方法签名过长）。
struct SubagentBackgroundLaunchParams: @unchecked Sendable {
    /// 代理类型名称（用于 SubagentTaskRecord.agentName）
    let agentName: String
    /// 原始 task 入参（完整提示词）
    let task: String
    /// 5-10 字任务摘要（UI 展示用）
    let taskDescription: String
    /// 触发此调用的父级 ToolCall（用于 SubagentTaskRecord.parentToolCallID）
    let toolCallRecord: ToolCall
    /// 父 session UUID（用于 SubagentTaskRecord.sessionID 和插入通知消息）
    let sessionID: UUID
    /// 父 session 对象（用于插入完成通知系统消息）
    let session: Session
    /// 是否以后台方式执行（来自 run_in_background 参数或 definition.background）
    let runInBackground: Bool
    /// 代理定义（用于传递给 launchSubagent，保存 modelID 等）
    let definition: WorkflowRoleDefinition
    /// 执行子代理的闭包（注入依赖，方便测试 mock）。
    /// 该闭包会触达 ClaudeService / SwiftData 等主 actor 资源，因此必须在 MainActor 上执行。
    let launchSubagent: SubagentLaunchClosure
    /// 可选：测试中覆盖 agentID（默认 UUID()）
    let overrideTaskID: UUID?

    init(
        agentName: String,
        task: String,
        taskDescription: String,
        toolCallRecord: ToolCall,
        sessionID: UUID,
        session: Session,
        runInBackground: Bool,
        definition: WorkflowRoleDefinition,
        launchSubagent: @escaping SubagentLaunchClosure,
        overrideTaskID: UUID? = nil
    ) {
        self.agentName = agentName
        self.task = task
        self.taskDescription = taskDescription
        self.toolCallRecord = toolCallRecord
        self.sessionID = sessionID
        self.session = session
        self.runInBackground = runInBackground
        self.definition = definition
        self.launchSubagent = launchSubagent
        self.overrideTaskID = overrideTaskID
    }
}

// MARK: - SubagentBackgroundExecutor

/// S-C2: 后台子代理生命周期管理器。
///
/// - 维护活跃 `Task<Void, Never>` 的注册表（actor 保护并发访问）。
/// - 同步路径（`runInBackground == false`）：直接 await `launchSubagent` 并返回。
/// - 异步路径（`runInBackground == true`）：创建 `SubagentTaskRecord`，fire-and-forget 启动 Swift Task，
///   立即返回 `SubagentLaunchResult.async` 占位响应。
/// - 子代理完成/失败/取消时，更新 `SubagentTaskRecord` 状态并在父 session 中插入系统通知消息。
actor SubagentBackgroundExecutor {

    // MARK: - State

    /// 活跃后台 Task 注册表，键为 agentID（SubagentTaskRecord.id）
    private var activeTasks: [UUID: Task<Void, Never>] = [:]

    // MARK: - Public Interface

    /// 活跃 Task 数量（供测试断言使用）
    var activeTaskCount: Int { activeTasks.count }

    /// 启动子代理（同步或后台）。
    ///
    /// - Parameters:
    ///   - params: 启动参数包
    ///   - modelContext: 父代理的 SwiftData ModelContext（用于持久化记录和通知消息）
    /// - Returns: `SubagentLaunchResult`
    func launch(
        params: SubagentBackgroundLaunchParams,
        modelContext: ModelContext
    ) async -> SubagentLaunchResult {
        // 同步路径：直接执行，不注册 Task
        guard params.runInBackground else {
            let result = await params.launchSubagent(params.task, params.definition, nil, nil)
            return result
        }

        // 后台路径
        let agentID = params.overrideTaskID ?? UUID()

        // 1. 创建并持久化 SubagentTaskRecord
        let record = SubagentTaskRecord(
            id: agentID,
            sessionID: params.sessionID,
            parentToolCallID: params.toolCallRecord.id,
            agentName: params.agentName,
            taskDescription: params.taskDescription,
            task: params.task,
            status: .running,
            modelID: params.definition.modelPreference == .inherit
                ? nil
                : params.definition.modelPreference.rawValue
        )
        await MainActor.run {
            modelContext.insert(record)
            do { try modelContext.save() } catch {
                #if DEBUG
                print("[S-C2] Insert record save failed: \(error)")
                #endif
            }
        }

        // 2. Fire-and-forget Task（独立生命周期，不绑定父 Task）
        let task = Task<Void, Never> {
            await self.runBackgroundLifecycle(
                agentID: agentID,
                params: params,
                record: record,
                modelContext: modelContext
            )
        }
        activeTasks[agentID] = task

        // 3. 立即返回占位响应
        return .async(agentID: agentID, description: params.taskDescription)
    }

    /// 取消指定后台子代理。
    func cancel(agentID: UUID) {
        activeTasks[agentID]?.cancel()
        activeTasks[agentID] = nil
    }

    /// 查询指定后台子代理的当前状态（未注册时返回 nil）。
    func status(agentID: UUID) -> SubagentTaskStatus? {
        activeTasks[agentID] != nil ? .running : nil
    }

    // MARK: - Private

    /// 后台子代理完整生命周期：执行 → 更新状态 → 发送通知消息。
    private func runBackgroundLifecycle(
        agentID: UUID,
        params: SubagentBackgroundLaunchParams,
        record: SubagentTaskRecord,
        modelContext: ModelContext
    ) async {
        // S-C3: 构建进度回调，将 SubagentProgress 写入已持久化的 SubagentTaskRecord
        // 注意：回调标注 @MainActor，由 AgentLoopRoundExecutor（@MainActor）直接调用，无需 await。
        // 不在此处调用 modelContext.save()，避免每轮 IO；save 在 finalize 时统一执行。
        let progressCallback: @MainActor @Sendable (SubagentProgress) -> Void = { [record] progress in
            record.toolUseCount = progress.toolUseCount
            record.tokenCount = progress.tokenCount
            record.lastActivity = progress.lastActivity?.activityDescription
        }

        // S-C4: 创建进度摘要器（30s 间隔，仅后台子代理）
        // 使用中间 actor 容器打破 summarizer 循环引用：apiProvider 通过 ctxHolder 读取 context
        let ctxHolder = SubagentContextHolder()

        let summarizer = SubagentProgressSummarizer(
            onSummaryGenerated: { [record, modelContext] summary in
                record.progressSummary = summary
                do { try modelContext.save() } catch {
                    #if DEBUG
                    print("[S-C4] Progress summary save failed: \(error)")
                    #endif
                }
            },
            apiProvider: { systemPrompt, messages, previousSummary in
                let ctx = await ctxHolder.context
                guard let service = ctx?.service else { return nil }

                let summaryMsg = MessageParameter.Message(
                    role: .user,
                    content: .text(SubagentProgressSummarizer.buildSummaryPrompt(
                        previousSummary: previousSummary
                    ))
                )
                let allMessages = messages + [summaryMsg]
                let params = MessageParameter(
                    model: .other(ctx?.modelId ?? "claude-sonnet-4-5"),
                    messages: allMessages,
                    maxTokens: 50,
                    system: systemPrompt,
                    tools: [],
                    toolChoice: nil
                )
                let response = try await service.createMessage(params)
                for block in response.content {
                    if case .text(let text, _) = block,
                       !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return text
                    }
                }
                return nil
            }
        )

        let summaryCallbacks = SubagentSummaryCallbacks(
            onContextCaptured: { ctx in
                Task { await ctxHolder.store(ctx) }
            },
            onMessagesUpdated: { msgs in
                Task { await summarizer.updateMessages(msgs) }
            }
        )
        await summarizer.start()

        // 执行子代理（可能长时间运行）
        let result = await params.launchSubagent(params.task, params.definition, progressCallback, summaryCallbacks)

        // S-C4: 子代理完成后立即停止摘要器
        await summarizer.stop()

        // 检查 Task 取消
        if Task.isCancelled {
            await finalize(
                agentID: agentID,
                record: record,
                session: params.session,
                status: .cancelled,
                result: nil,
                error: "Task cancelled",
                modelContext: modelContext
            )
            return
        }

        // 成功
        await finalize(
            agentID: agentID,
            record: record,
            session: params.session,
            status: .completed,
            result: result.syncMessage?.content.rawText ?? result.toolResultText,
            error: nil,
            modelContext: modelContext
        )
    }

    /// 终止后台子代理：更新 record 状态、写入通知消息、注销 Task 注册表。
    private func finalize(
        agentID: UUID,
        record: SubagentTaskRecord,
        session: Session,
        status: SubagentTaskStatus,
        result: String?,
        error: String?,
        modelContext: ModelContext
    ) async {
        await MainActor.run {
            // 更新 SubagentTaskRecord
            record.status = status
            record.completedAt = Date()
            record.result = result
            record.errorMessage = error

            // 插入系统通知消息
            let notificationText = SubagentBackgroundExecutor.buildNotificationText(
                agentName: record.agentName,
                description: record.taskDescription,
                status: status,
                result: result,
                error: error,
                elapsedSeconds: record.elapsedSeconds
            )
            let notification = Message.systemMessage(text: notificationText, session: session)
            modelContext.insert(notification)
            do { try modelContext.save() } catch {
                #if DEBUG
                print("[S-C2] Finalize save failed: \(error)")
                #endif
            }
        }

        // 注销 Task 注册表
        activeTasks[agentID] = nil
    }

    /// 构建通知消息文本（XML 结构，供 UI 渲染识别）。
    nonisolated static func buildNotificationText(
        agentName: String,
        description: String,
        status: SubagentTaskStatus,
        result: String?,
        error: String?,
        elapsedSeconds: TimeInterval
    ) -> String {
        let elapsedStr = String(format: "%.1fs", elapsedSeconds)
        let statusLabel: String
        switch status {
        case .completed: statusLabel = "completed"
        case .failed:    statusLabel = "failed"
        case .cancelled: statusLabel = "cancelled"
        default:         statusLabel = status.rawValue
        }

        var body = """
        <task-notification>
          <agent>\(agentName)</agent>
          <description>\(description)</description>
          <status>\(statusLabel)</status>
          <elapsed>\(elapsedStr)</elapsed>
        """
        if let result, !result.isEmpty {
            let preview = String(result.prefix(500))
            body += "\n  <result>\(preview)</result>"
        }
        if let error, !error.isEmpty {
            body += "\n  <error>\(error)</error>"
        }
        body += "\n</task-notification>"
        return body
    }
}

// MARK: - SubagentContextHolder

/// S-C4: 轻量级 actor 容器，打破 SubagentProgressSummarizer apiProvider 闭包的循环引用。
/// 在 `onContextCaptured` 回调触发时存储 context，apiProvider 通过 `await ctxHolder.context` 读取。
private actor SubagentContextHolder {
    private(set) var context: SubagentSummaryContext?

    func store(_ ctx: SubagentSummaryContext) {
        context = ctx
    }
}
