import Foundation
import SwiftAnthropic
import SwiftData

// MARK: - MemoryConsolidationCoordinator

/// actor：保护 `isRunning` flag，防止并发二次启动整合。
actor MemoryConsolidationCoordinator {
    private var isRunning = false

    /// 若当前空闲，标记为运行中并返回 `true`；否则返回 `false`。
    func beginConsolidation() -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        return true
    }

    /// 标记整合完成（无论成功/失败）。
    func finishConsolidation() {
        isRunning = false
    }
}

// MARK: - MemoryConsolidationService

/// M-06 整合服务：持有依赖，构建供 hook 注入的 callback 闭包。
struct MemoryConsolidationService: Sendable {

    let claudeService: ClaudeService
    let settings: AppSettings
    let sessionId: String
    let modelContext: ModelContext

    // MARK: - Public

    /// 构建 consolidation callback 闭包，供 `MemoryConsolidationHook` 使用。
    func buildCallback() -> @Sendable (AgentLoopHookContext) async -> Void {
        let coordinator = MemoryConsolidationCoordinator()
        let service = claudeService
        let capturedSettings = settings
        let capturedSessionId = sessionId
        let capturedModelContext = modelContext

        return { @Sendable _ in
            guard capturedSettings.memoryEnabled,
                  capturedSettings.memoryConsolidationEnabled else { return }

            do {
                let memDir = ConfigDirectoryManager.shared.memoryDir
                let lockManager = MemoryConsolidationLockManager(memoryDir: memDir)
                let lastConsolidatedAt = try await lockManager.readLastConsolidatedAt()

                try await MemoryConsolidationService.run(
                    lastConsolidatedAtMs: lastConsolidatedAt,
                    modelContext: capturedModelContext,
                    currentSessionId: capturedSessionId,
                    minHours: capturedSettings.memoryConsolidationMinHours,
                    minSessions: capturedSettings.memoryConsolidationMinSessions,
                    memoryDir: memDir,
                    runSubagent: { prompt, _ in
                        let toolCallRecord = ToolCall(
                            toolCallId: "consolidation-daemon-\(UUID().uuidString)",
                            kind: .subagent
                        )
                        guard let anthropicService = await service.service else { return }
                        _ = try await service.runSubagentLoop(
                            task: prompt,
                            definition: WorkflowRoleDefinition.consolidationDaemon,
                            toolCallRecord: toolCallRecord,
                            service: anthropicService,
                            modelId: capturedSettings.selectedModel,
                            settings: capturedSettings,
                            sessionId: capturedSessionId,
                            modelContext: capturedModelContext
                        )
                    },
                    coordinator: coordinator
                )
            } catch {
                #if DEBUG
                print("[MemoryConsolidationService] error: \(error)")
                #endif
            }
        }
    }

    // MARK: - Internal (visible for testing)

    /// 运行整合流程。
    ///
    /// 通过 `runSubagent` 依赖注入使测试可以 mock subagent 调用。
    @MainActor
    static func run(
        lastConsolidatedAtMs: Double,
        modelContext: ModelContext,
        currentSessionId: String,
        minHours: Double,
        minSessions: Int,
        memoryDir: URL,
        runSubagent: @Sendable (String, [String]) async throws -> Void,
        coordinator: MemoryConsolidationCoordinator
    ) async throws {
        // 1. Coordinator 防重入
        guard await coordinator.beginConsolidation() else { return }
        defer { Task { await coordinator.finishConsolidation() } }

        // 2. 双门槛检查
        let gate = MemoryConsolidationScheduleGate(
            modelContext: modelContext,
            minHours: minHours,
            minSessions: minSessions
        )
        let gateResult = await gate.shouldConsolidate(
            lastConsolidatedAtMs: lastConsolidatedAtMs,
            currentSessionId: currentSessionId
        )
        guard gateResult.shouldFire else { return }

        // 3. 获取 lock 文件锁
        let lockManager = MemoryConsolidationLockManager(memoryDir: memoryDir)
        guard let priorMtime = try await lockManager.tryAcquire() else { return }

        // 4. 获取 sessionIds（与 gate 检查一致的条件）
        let lastDate = Date(timeIntervalSince1970: lastConsolidatedAtMs / 1000)
        let sid = currentSessionId
        let descriptor = FetchDescriptor<Session>(
            predicate: #Predicate { session in
                session.updatedAt > lastDate && session.sessionId != sid
            },
            sortBy: [SortDescriptor(\Session.updatedAt, order: .reverse)]
        )
        let sessions = (try? modelContext.fetch(descriptor)) ?? []
        let sessionIds = sessions.map(\.sessionId)

        // 5. 构建 prompt
        let prompt = MemoryConsolidationPromptBuilder().build(
            memoryDir: memoryDir,
            sessionIds: sessionIds,
            sessionCount: sessionIds.count
        )

        // 6. 启动 subagent（失败时 rollback lock）
        do {
            try await runSubagent(prompt, sessionIds)
            try await lockManager.commitConsolidation()
        } catch {
            try? await lockManager.rollback(to: priorMtime)
            throw error
        }
    }
}
