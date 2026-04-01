import Foundation

/// 文件写入工具后置钩子：将 ChangeProposalReviewSnapshot 注入 ChangeReviewProjectionStore，
/// 并向执行时间线追加变更提案摘要附件。
///
/// 触发条件：
///   - 工具名为 `str_replace_based_edit_tool` 或 `str_replace_editor`
///   - ToolExecutionResult 携带非 nil 的 changeProposalSnapshot
///   - 工具执行结果为成功（非 isError）
///
/// 不触发时返回 .passthrough，不影响其他钩子链。
struct ChangeReviewHook: ToolExecutionHook, Sendable {

    let hookID = "change-review"

    private let projectionStore: ChangeReviewProjectionStore

    init(projectionStore: ChangeReviewProjectionStore) {
        self.projectionStore = projectionStore
    }

    // MARK: - 触发条件

    private static let writeToolNames: Set<String> = [
        "str_replace_based_edit_tool",
        "str_replace_editor"
    ]

    // MARK: - ToolExecutionHook

    func preExecute(toolCall: ToolCallPreview) async -> PreExecuteDecision {
        .allow
    }

    func postExecute(record: ToolRunRecord) async -> PostExecuteAction {
        guard Self.writeToolNames.contains(record.toolName),
              !record.result.isError,
              let snapshot = record.result.changeProposalSnapshot else {
            return .passthrough
        }

        await MainActor.run {
            projectionStore.set(snapshot)
        }

        let fileCount = snapshot.fileChanges.count
        let filesLabel = fileCount == 1 ? "1 个文件" : "\(fileCount) 个文件"
        return .appendAttachment("变更提案已创建：\(filesLabel)待审查")
    }

    func postFailure(toolCall: ToolCallPreview, error: any Error) async -> FailureAction {
        .propagate
    }
}
