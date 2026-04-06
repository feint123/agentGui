import Foundation
import SwiftData
import SwiftUI

// MARK: - MessageRewindSelectorViewModel.Phase

extension MessageRewindSelectorViewModel {
    enum Phase {
        case loading     // 初始加载 checkpointMap
        case ready       // 列表就绪，等待用户操作
        case executing   // 正在执行回滚事务
    }
}

// MARK: - MessageRewindSelectorViewModel.PendingConfirmation

extension MessageRewindSelectorViewModel {
    /// 有文件变化时，暂存待确认信息，触发 RewindConfirmationSheet 展示。
    struct PendingConfirmation: Identifiable {
        let id = UUID()
        let message: Message
        let checkpoint: ConversationCheckpoint?
        let diffStats: RewindDiffStats
    }
}

// MARK: - MessageRewindSelectorViewModel

/// R-D1 ViewModel：管理历史消息列表展示、checkpointMap 加载和回滚路径决策。
///
/// ## 两条执行路径
/// - lossless fast path：`hasAnyFileChanges == false` → 调用 `RewindTransactionCoordinator.execute(.conversationOnly)` 直接完成
/// - confirmation path：`hasAnyFileChanges == true` → 填充 `pendingConfirmation`，Sheet 呈现 RewindConfirmationSheet
///
/// ## 并发安全
/// `@MainActor`：所有可变状态在主线程访问；
/// `preflightInspector`（actor）和 `transactionCoordinator`（@MainActor）均通过 `await` 调用。
@Observable
@MainActor
final class MessageRewindSelectorViewModel {

    // MARK: - Observable State

    var phase: Phase = .loading
    var errorMessage: String?
    /// 非 nil 时触发 RewindConfirmationSheet
    var pendingConfirmation: PendingConfirmation?
    /// 执行成功后置 true，View 观测后调用 dismiss()
    var shouldDismiss = false

    /// 倒序的用户消息列表（最新在前），由 loadData 填充
    private(set) var userMessages: [Message] = []
    /// messageID → checkpoint 映射，由 loadData 填充
    private(set) var checkpointMap: [UUID: ConversationCheckpoint] = [:]

    // MARK: - Dependencies

    private let checkpointService: ConversationCheckpointService
    private let preflightInspector: RewindPreflightInspector
    private let transactionCoordinator: RewindTransactionCoordinator
    private let session: Session

    // MARK: - Init

    init(
        session: Session,
        checkpointService: ConversationCheckpointService,
        preflightInspector: RewindPreflightInspector,
        transactionCoordinator: RewindTransactionCoordinator
    ) {
        self.session = session
        self.checkpointService = checkpointService
        self.preflightInspector = preflightInspector
        self.transactionCoordinator = transactionCoordinator
    }

    // MARK: - Public API

    /// 加载 checkpoints 并构建 userMessages 列表。
    /// 应在 `.task(id: session.sessionId)` 或视图 onAppear 中调用。
    func loadData(messages: [Message], modelContext: ModelContext) async {
        phase = .loading

        // 1. 筛选用户消息，按 sequence 倒序
        let sorted = messages
            .filter { $0.direction == .user }
            .sorted { $0.sequence > $1.sequence }

        // 2. 获取本 session 的所有 checkpoints（最多 50 个）
        let checkpoints = (try? await checkpointService.fetchCheckpoints(
            sessionID: session.sessionId,
            limit: 50,
            modelContext: modelContext
        )) ?? []

        // 3. 构建 messageID → checkpoint 映射
        var map: [UUID: ConversationCheckpoint] = [:]
        for cp in checkpoints {
            map[cp.messageID] = cp
        }

        userMessages = sorted
        checkpointMap = map
        phase = .ready
    }

    /// 用户点击某条消息时触发，决定走哪条路径。
    func selectMessage(_ message: Message) async {
        phase = .executing
        errorMessage = nil

        let checkpoint = checkpointMap[message.id]

        // 判断是否有文件变化（快速路径：先检查 hasFileChanges 标志，再调用 inspector）
        let hasChanges: Bool
        if let cp = checkpoint, cp.hasFileChanges {
            // checkpoint 声明有文件变化，调用 inspector 精确验证（当前文件是否仍与备份不同）
            hasChanges = (try? await preflightInspector.hasAnyFileChanges(checkpoint: cp)) ?? false
        } else {
            // 无 checkpoint 或 checkpoint.hasFileChanges == false → 无需验证
            hasChanges = false
        }

        if !hasChanges {
            // Lossless fast path: 仅截断对话，不动文件
            do {
                try await transactionCoordinator.execute(
                    targetMessage: message,
                    checkpoint: nil,
                    option: .conversationOnly,
                    repopulateInput: true
                )
                shouldDismiss = true
            } catch {
                errorMessage = error.localizedDescription
            }
        } else {
            // Confirmation path（Task 4 实现）
            let diffStats = (try? await preflightInspector.computeDiffStats(checkpoint: checkpoint!)) ?? .empty
            pendingConfirmation = PendingConfirmation(
                message: message,
                checkpoint: checkpoint,
                diffStats: diffStats
            )
        }

        phase = .ready
    }

    /// 确认 sheet 批准后执行回滚（由 RewindConfirmationSheet 回调）。
    func executeConfirmation(pending: PendingConfirmation, option: RewindOption) async {
        // TODO: Task 4 实现
    }
}
