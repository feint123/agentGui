import XCTest
@testable import agentGui

@MainActor
final class ChangeReviewHookTests: XCTestCase {

    // MARK: - Helpers

    private func makeWriteRecord(
        toolName: String = "str_replace_based_edit_tool",
        snapshot: ChangeProposalReviewSnapshot? = nil
    ) -> ToolRunRecord {
        let result = ToolExecutionResult(
            "已创建待审查变更提案（1 个文件）。在 Apply 前不会修改真实工作区。",
            status: .success,
            changeProposalSnapshot: snapshot
        )
        return ToolRunRecord(
            toolCallId: "tc-write",
            toolName: toolName,
            input: [:],
            result: result,
            sessionID: "session-1",
            executionContext: .mainAgent
        )
    }

    private func makeReadRecord(toolName: String = "bash") -> ToolRunRecord {
        ToolRunRecord(
            toolCallId: "tc-read",
            toolName: toolName,
            input: [:],
            result: .success("output"),
            sessionID: "session-1",
            executionContext: .mainAgent
        )
    }

    private func makeSnapshot(fileCount: Int = 2) -> ChangeProposalReviewSnapshot {
        let proposal = ChangeProposalSnapshot(
            id: UUID(),
            sessionID: "session-1",
            jobID: nil,
            messageID: nil,
            providerID: .builtInAgent,
            state: .readyForReview,
            baseWorkspaceRoot: "/tmp/workspace",
            summary: "test proposal",
            createdAt: Date(),
            updatedAt: Date()
        )
        let changes = (0..<fileCount).map { i in
            ProposedFileChangeSnapshot(
                id: UUID(),
                proposalID: proposal.id,
                relativePath: "file\(i).swift",
                absolutePath: "/tmp/workspace/file\(i).swift",
                changeKind: .modify,
                unifiedDiff: "+new line",
                state: .proposed,
                lineAdditions: 1,
                lineDeletions: 0
            )
        }
        return ChangeProposalReviewSnapshot(proposal: proposal, fileChanges: changes)
    }

    // MARK: - Non-write tool: passthrough

    func test_nonWriteTool_returnsPassthrough() async {
        let store = ChangeReviewProjectionStore()
        let hook = ChangeReviewHook(projectionStore: store)

        let action = await hook.postExecute(record: makeReadRecord(toolName: "bash"))

        switch action {
        case .passthrough: break
        default: XCTFail("Expected .passthrough for non-write tool, got \(action)")
        }
    }

    // MARK: - Write tool without snapshot: passthrough

    func test_writeTool_noSnapshot_returnsPassthrough() async {
        let store = ChangeReviewProjectionStore()
        let hook = ChangeReviewHook(projectionStore: store)

        let action = await hook.postExecute(record: makeWriteRecord(snapshot: nil))

        switch action {
        case .passthrough: break
        default: XCTFail("Expected .passthrough when snapshot is nil, got \(action)")
        }
    }

    // MARK: - Write tool with snapshot: updates projection store + returns attachment

    func test_writeTool_withSnapshot_updatesProjectionStore() async {
        let store = ChangeReviewProjectionStore()
        let snapshot = makeSnapshot(fileCount: 3)
        let hook = ChangeReviewHook(projectionStore: store)

        _ = await hook.postExecute(record: makeWriteRecord(snapshot: snapshot))

        XCTAssertEqual(store.snapshot(for: snapshot.proposal.id)?.fileChanges.count, 3)
    }

    func test_writeTool_withSnapshot_returnsAppendAttachment() async {
        let store = ChangeReviewProjectionStore()
        let snapshot = makeSnapshot(fileCount: 2)
        let hook = ChangeReviewHook(projectionStore: store)

        let action = await hook.postExecute(record: makeWriteRecord(snapshot: snapshot))

        switch action {
        case .appendAttachment(let text):
            XCTAssertTrue(text.contains("2"), "Attachment should mention file count (2), got: \(text)")
        default:
            XCTFail("Expected .appendAttachment, got \(action)")
        }
    }

    // MARK: - str_replace_editor alias: also triggers hook

    func test_strReplaceEditorAlias_withSnapshot_triggersHook() async {
        let store = ChangeReviewProjectionStore()
        let snapshot = makeSnapshot(fileCount: 1)
        let hook = ChangeReviewHook(projectionStore: store)

        let action = await hook.postExecute(
            record: makeWriteRecord(toolName: "str_replace_editor", snapshot: snapshot)
        )

        switch action {
        case .appendAttachment: break
        default: XCTFail("str_replace_editor should also trigger the hook")
        }
    }

    // MARK: - Error result: passthrough even on write tool

    func test_errorResult_returnPassthrough() async {
        let store = ChangeReviewProjectionStore()
        let hook = ChangeReviewHook(projectionStore: store)

        let errorRecord = ToolRunRecord(
            toolCallId: "tc-write",
            toolName: "str_replace_based_edit_tool",
            input: [:],
            result: .failure("Error: old_str not found"),
            sessionID: "session-1",
            executionContext: .mainAgent
        )

        let action = await hook.postExecute(record: errorRecord)

        switch action {
        case .passthrough: break
        default: XCTFail("Error result should not trigger projection update")
        }
    }

    // MARK: - preExecute: always allow

    func test_preExecute_alwaysReturnsAllow() async {
        let store = ChangeReviewProjectionStore()
        let hook = ChangeReviewHook(projectionStore: store)
        let preview = ToolCallPreview(
            toolCallId: "tc-1",
            toolName: "str_replace_based_edit_tool",
            input: [:],
            sessionID: "session-1",
            executionContext: .mainAgent
        )

        let decision = await hook.preExecute(toolCall: preview)

        switch decision {
        case .allow: break
        default: XCTFail("preExecute must return .allow")
        }
    }

    // MARK: - postFailure: always propagate

    func test_postFailure_alwaysPropagate() async {
        let store = ChangeReviewProjectionStore()
        let hook = ChangeReviewHook(projectionStore: store)
        let preview = ToolCallPreview(
            toolCallId: "tc-1",
            toolName: "str_replace_based_edit_tool",
            input: [:],
            sessionID: "session-1",
            executionContext: .mainAgent
        )

        let action = await hook.postFailure(
            toolCall: preview,
            error: ToolExecutionHookError(message: "test error")
        )

        switch action {
        case .propagate: break
        default: XCTFail("postFailure must return .propagate")
        }
    }
}
