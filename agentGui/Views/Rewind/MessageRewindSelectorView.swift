import SwiftUI
import SwiftData

/// R-D1: 历史消息选择器 Sheet。
///
/// 展示当前 session 中所有用户消息（最多 20 条，倒序），用户选择后分两条路径：
/// - lossless（无文件变化）：直接执行 conversationOnly，关闭 sheet
/// - 有文件变化：呈现 RewindConfirmationSheet 供用户选择操作范围
///
/// ## 使用方式
/// 在 ChatView 中：
/// ```swift
/// .sheet(isPresented: $isRewindSelectorPresented) {
///     MessageRewindSelectorView(
///         session: session,
///         allMessages: allMessages,
///         transactionCoordinator: makeRewindTransactionCoordinator()
///     )
/// }
/// ```
struct MessageRewindSelectorView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    // MARK: - Dependencies (injected)

    let session: Session
    /// 完整的 session 消息列表（含 agent/system，由 ChatView @Query 传入）
    let allMessages: [Message]
    let transactionCoordinator: RewindTransactionCoordinator

    // MARK: - ViewModel

    @State private var viewModel: MessageRewindSelectorViewModel

    // MARK: - Init

    init(
        session: Session,
        allMessages: [Message],
        transactionCoordinator: RewindTransactionCoordinator,
        checkpointService: ConversationCheckpointService,
        preflightInspector: RewindPreflightInspector
    ) {
        self.session = session
        self.allMessages = allMessages
        self.transactionCoordinator = transactionCoordinator
        _viewModel = State(initialValue: MessageRewindSelectorViewModel(
            session: session,
            checkpointService: checkpointService,
            preflightInspector: preflightInspector,
            transactionCoordinator: transactionCoordinator
        ))
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Group {
                switch viewModel.phase {
                case .loading:
                    loadingView
                case .ready, .executing:
                    if viewModel.userMessages.isEmpty {
                        emptyView
                    } else {
                        messageListView
                    }
                }
            }
            .navigationTitle("回滚到历史消息")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(viewModel.phase == .executing)
                }
            }
            .alert(
                "回滚失败",
                isPresented: Binding(
                    get: { viewModel.errorMessage != nil },
                    set: { if !$0 { viewModel.errorMessage = nil } }
                )
            ) {
                Button("确定") { viewModel.errorMessage = nil }
            } message: {
                if let err = viewModel.errorMessage { Text(err) }
            }
        }
        .sheet(item: $viewModel.pendingConfirmation) { pending in
            RewindConfirmationSheet(
                pending: pending,
                onExecute: { option in
                    await viewModel.executeConfirmation(pending: pending, option: option)
                },
                onCancel: {
                    viewModel.pendingConfirmation = nil
                }
            )
        }
        .task(id: session.sessionId) {
            await viewModel.loadData(messages: allMessages, modelContext: modelContext)
        }
        .onChange(of: viewModel.shouldDismiss) { _, newValue in
            if newValue { dismiss() }
        }
        .frame(minWidth: 400, minHeight: 300)
    }

    // MARK: - Subviews

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("加载历史快照…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        ContentUnavailableView(
            "暂无历史消息",
            systemImage: "clock.arrow.circlepath",
            description: Text("当前对话中没有可回滚的用户消息。")
        )
    }

    private var messageListView: some View {
        List {
            ForEach(viewModel.userMessages.prefix(20)) { message in
                MessageRewindRowView(
                    message: message,
                    hasFileChanges: viewModel.checkpointMap[message.id]?.hasFileChanges ?? false
                )
                .onTapGesture {
                    Task { await viewModel.selectMessage(message) }
                }
                .disabled(viewModel.phase == .executing)
            }
        }
        .listStyle(.plain)
    }
}
