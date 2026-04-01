import Foundation

/// 工具结果 payload 预算钩子：在 postExecute 阶段检测结果大小。
/// 若结果文本超过阈值且尚未被 dispatch 层处理（`envelope == nil`），
/// 将完整文本存入 `ToolPayloadStore` 并以结构化 reference 替换 context 中的内容，
/// 避免大型工具结果撑爆 context window。
///
/// **不触发条件（直接 passthrough）：**
/// - `record.result.envelope != nil`：dispatch 层已处理，不重复压缩
/// - `record.result.isError`：失败结果不做 payload 化
/// - 文本长度 ≤ `charThreshold`
///
/// 注册于 `AgentLoopToolExecutionCoordinatorBuilder.buildHookPipeline()`（F-C5）。
struct PayloadBudgetHook: ToolExecutionHook, Sendable {

    let hookID = "payload-budget"

    /// 触发 payload 化的字符数阈值，默认 16 384（约 4 000 tokens）。
    let charThreshold: Int

    /// 用于创建 payload 文件的存储 actor。
    private let payloadStore: ToolPayloadStore

    init(
        payloadStore: ToolPayloadStore,
        charThreshold: Int = 16_384
    ) {
        self.payloadStore = payloadStore
        self.charThreshold = charThreshold
    }

    // MARK: - ToolExecutionHook

    func preExecute(toolCall: ToolCallPreview) async -> PreExecuteDecision {
        .allow
    }

    func postExecute(record: ToolRunRecord) async -> PostExecuteAction {
        // 1. 已有 envelope → dispatch 层已处理，passthrough
        guard record.result.envelope == nil else { return .passthrough }
        // 2. 错误结果不 payload 化
        guard !record.result.isError else { return .passthrough }
        // 3. 文本未超阈值 → passthrough
        let text = record.result.text
        guard text.count > charThreshold else { return .passthrough }

        // 4. 决定 sourceKind（根据工具名做简单映射，未匹配的归入 .other）
        let sourceKind = Self.sourceKind(for: record.toolName)

        // 5. 创建 payload；若失败则 passthrough（安全降级，不影响主路径）
        guard let payload = try? await payloadStore.createPayload(
            text: text,
            sourceKind: sourceKind,
            sourceDescriptor: record.toolName
        ) else {
            return .passthrough
        }

        // 6. 构造 ToolResultEnvelope（.referenced 模式）
        let preview = String(text.prefix(800))
        let summary = "\(sourceKind.rawValue) result (\(text.count) chars)"
        let envelope = ToolResultEnvelope(
            summary: summary,
            preview: preview,
            payloadRef: payload.payloadID,
            isTruncated: true,
            estimatedChars: text.count,
            estimatedTokens: ToolResultEnvelope.estimateTokens(for: text),
            retrievalHint: "Use read_tool_payload with payload_ref to access the full result in chunks.",
            sourceKind: sourceKind,
            injectionMode: .referenced,
            rawCharCount: text.count,
            injectedCharCount: summary.count + preview.count
        )

        // 7. 构造紧凑 result，保留原始 status 和 rawOutputText
        let compactText = envelope.renderForModel()
        let newResult = ToolExecutionResult(
            compactText,
            status: record.result.status,
            rawOutputText: text,
            envelope: envelope
        )
        return .rewriteResult(newResult)
    }

    func postFailure(toolCall: ToolCallPreview, error: any Error) async -> FailureAction {
        .propagate
    }

    // MARK: - Private Helpers

    /// 根据工具名推断 `LargeTextPayload.SourceKind`（最佳猜测，不限于确定映射）。
    private static func sourceKind(for toolName: String) -> LargeTextPayload.SourceKind {
        switch toolName {
        case "bash":               return .bash
        case "read_file",
             "str_replace_based_edit_tool",
             "str_replace_editor":  return .file
        case "web_fetch":          return .webFetch
        case "web_search":         return .webSearch
        default:                   return .other
        }
    }
}
