import Foundation
import SwiftAnthropic
import SwiftData

/// M-03: session-end 记忆自动提取服务。
///
/// 将 `buildExtractionCallback()` + `runExtraction()` 从
/// `AgentLoopHookDependencyFactory` 提炼为独立可测类型，使提取逻辑可以：
/// - 独立初始化（不依赖完整的 factory）
/// - 被测试代码直接实例化
/// - 在需要不同依赖（不同 session 或 settings）时复用
///
/// ## 架构职责
/// - `buildCallback()` 构建供 `AgentLoopBuiltInHookFactory.Dependencies.extractMemoriesCallback` 使用的 `@Sendable` 闭包。
/// - `runExtraction(...)` 是静态方法，执行实际的 subagent loop；访问修饰符为 `internal` 以支持测试。
/// - `MemoryExtractionCoordinator` 在 `buildCallback()` 内构建，保证 per-service-instance 并发保护。
struct SessionMemoryExtractorService {

    let claudeService: ClaudeService
    let settings: AppSettings
    let sessionId: String
    let modelContext: ModelContext

    // MARK: - Public

    /// 构建 memory extraction 的执行闭包，供 hook factory 注入。
    ///
    /// 闭包：
    /// - 通过内部 `MemoryExtractionCoordinator` actor 保证同一 service 实例不并发执行两次提取。
    /// - 在 fire-and-forget 的 detached task 中运行（不阻塞主 loop）。
    func buildCallback() -> @Sendable (AgentLoopHookContext) async -> Void {
        let coordinator = MemoryExtractionCoordinator()
        let service = claudeService
        let capturedSettings = settings
        let capturedSessionId = sessionId
        let capturedModelContext = modelContext

        return { @Sendable context in
            guard await coordinator.beginExtraction() else { return }
            defer { Task { await coordinator.finishExtraction() } }

            do {
                try await SessionMemoryExtractorService.runExtraction(
                    context: context,
                    claudeService: service,
                    settings: capturedSettings,
                    sessionId: capturedSessionId,
                    modelContext: capturedModelContext
                )
            } catch {
                #if DEBUG
                print("[SessionMemoryExtractorService] extraction error: \(error)")
                #endif
            }
        }
    }

    // MARK: - Internal (visible for testing)

    /// 运行 memory extraction subagent loop。
    ///
    /// - Parameters:
    ///   - context: 当前 hook 上下文，包含本轮完整消息快照。
    ///   - claudeService: 主服务，用于构建工具集和启动 subagent loop。
    ///   - settings: 当前 app 设置，提供 model ID 和工具配置。
    ///   - sessionId: 父会话 ID，用于 subagent runtime 中的资源隔离。
    ///   - modelContext: SwiftData 上下文，传递给 subagent runtime。
    ///
    /// 守卫：当 `messagesSnapshot` 为空时提前返回，不启动 subagent。
    static func runExtraction(
        context: AgentLoopHookContext,
        claudeService: ClaudeService,
        settings: AppSettings,
        sessionId: String,
        modelContext: ModelContext
    ) async throws {
        let messageCount = context.messagesSnapshot.count
        guard messageCount > 0 else { return }

        // 从 RMSInsightStore 读取现有 insights（防重复写入）
        let existingInsights = (try? RMSInsightStore().load(scope: .user)) ?? []

        // 构建提取 prompt
        let extractionPrompt = MemoryExtractionPromptBuilder.build(
            newMessageCount: messageCount,
            existingInsights: existingInsights
        )

        // 构建受限工具集（仅 memory_write + read_file）
        let restrictedTools = await claudeService.buildExtractionTools(settings: settings)

        // 组装消息：本轮快照 + 提取指令
        var loopMessages = context.messagesSnapshot
        loopMessages.append(.init(role: .user, content: .text(extractionPrompt)))

        let extractionSystem = await claudeService.makeEphemeralSystemPrompt("")
        guard let extractionService = await claudeService.service else { return }

        let request = AgentLoopRunRequest(
            service: extractionService,
            modelId: settings.selectedModel,
            tools: restrictedTools,
            system: extractionSystem,
            maxRounds: 5,
            toolExecutionContext: .backgroundTask,
            toolApprovalMode: .bypassApprovals,
            runSource: "memoryExtraction",
            runLabel: "Memory extraction",
            requestedBudgetSeconds: nil
        )
        let runtime = AgentLoopRuntime(
            settings: settings,
            session: nil,
            sessionId: sessionId,
            modelContext: modelContext,
            makeRound: { AgentRound(roundIndex: $0) },
            parentMessage: nil,
            streamProjectionTarget: .none,
            toolInterceptor: nil,
            remoteDeliveryHandle: nil
        )

        _ = try await claudeService.runCoreAgentLoop(
            messages: &loopMessages,
            request: request,
            runtime: runtime
        )
    }
}
