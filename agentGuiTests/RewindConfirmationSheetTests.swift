// agentGuiTests/RewindConfirmationSheetTests.swift
import Testing
import Foundation
import SwiftData
@testable import agentGui

// MARK: - Helpers

/// 构造一个最小可用的 PendingConfirmation，方便各测试自定义字段。
/// 返回 (container, pending)，调用方须持有 container 使 SwiftData 上下文保持有效。
@MainActor
private func makePending(
    messageText: String? = "hello world",
    checkpoint: ConversationCheckpoint? = nil,
    filesChanged: [String] = [],
    totalInsertions: Int = 0,
    totalDeletions: Int = 0,
    addedFiles: [String] = [],
    deletedFiles: [String] = [],
    modifiedFiles: [String] = [],
    messagesAfterCount: Int = 0,
    toolCallsAfterCount: Int = 0
) throws -> (ModelContainer, MessageRewindSelectorViewModel.PendingConfirmation) {
    let schema = Schema(PersistenceSchema.sharedModelTypes)
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: schema, configurations: [config])
    let ctx = container.mainContext

    let session = Session()
    ctx.insert(session)
    let message = Message(direction: .user, text: messageText, session: session)
    message.sequence = 0
    ctx.insert(message)
    try ctx.save()

    let diffStats = RewindDiffStats(
        filesChanged: filesChanged,
        totalInsertions: totalInsertions,
        totalDeletions: totalDeletions,
        addedFiles: addedFiles,
        deletedFiles: deletedFiles,
        modifiedFiles: modifiedFiles
    )

    let pending = MessageRewindSelectorViewModel.PendingConfirmation(
        message: message,
        checkpoint: checkpoint,
        diffStats: diffStats,
        messagesAfterCount: messagesAfterCount,
        toolCallsAfterCount: toolCallsAfterCount
    )
    return (container, pending)
}

// MARK: - RewindConfirmationSheet computed property tests

@Suite("RewindConfirmationSheet — 计算属性")
struct RewindConfirmationSheetTests {

    // MARK: canRestoreFiles

    @Test("canRestoreFiles: checkpoint 为 nil 时返回 false")
    @MainActor
    func canRestoreFiles_noCheckpoint_returnsFalse() throws {
        let (container, pending) = try makePending(
            checkpoint: nil,
            filesChanged: ["/path/to/file.swift"]
        )
        _ = container
        let sheet = RewindConfirmationSheet(
            pending: pending,
            onExecute: { _ in },
            onCancel: {}
        )
        #expect(sheet.canRestoreFiles == false)
    }

    @Test("canRestoreFiles: filesChanged 为空时返回 false")
    @MainActor
    func canRestoreFiles_emptyFilesChanged_returnsFalse() throws {
        let schema = Schema(PersistenceSchema.sharedModelTypes)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let ctx = container.mainContext
        let session = Session()
        ctx.insert(session)
        let cp = try ConversationCheckpoint(
            sessionID: session.sessionId,
            messageID: UUID(),
            snapshotSequence: 0,
            workspaceRoot: "/tmp",
            trackedFileBackups: [:],
            hasFileChanges: true
        )
        ctx.insert(cp)
        try ctx.save()

        let (pendingContainer, pending) = try makePending(
            checkpoint: cp,
            filesChanged: []   // 空列表
        )
        _ = pendingContainer
        let sheet = RewindConfirmationSheet(
            pending: pending,
            onExecute: { _ in },
            onCancel: {}
        )
        #expect(sheet.canRestoreFiles == false)
    }

    @Test("canRestoreFiles: checkpoint 存在且 filesChanged 非空时返回 true")
    @MainActor
    func canRestoreFiles_withCheckpointAndFiles_returnsTrue() throws {
        let schema = Schema(PersistenceSchema.sharedModelTypes)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let ctx = container.mainContext
        let session = Session()
        ctx.insert(session)
        let cp = try ConversationCheckpoint(
            sessionID: session.sessionId,
            messageID: UUID(),
            snapshotSequence: 0,
            workspaceRoot: "/tmp",
            trackedFileBackups: [:],
            hasFileChanges: true
        )
        ctx.insert(cp)
        try ctx.save()

        let (pendingContainer, pending) = try makePending(
            checkpoint: cp,
            filesChanged: ["/tmp/foo.swift"]
        )
        _ = pendingContainer
        let sheet = RewindConfirmationSheet(
            pending: pending,
            onExecute: { _ in },
            onCancel: {}
        )
        #expect(sheet.canRestoreFiles == true)
    }

    // MARK: diffSummaryLine

    @Test("diffSummaryLine: insertions 和 deletions 均为 0 时返回空字符串")
    @MainActor
    func diffSummaryLine_zeroCounts_returnsEmpty() throws {
        let (container, pending) = try makePending(totalInsertions: 0, totalDeletions: 0)
        _ = container
        let sheet = RewindConfirmationSheet(
            pending: pending,
            onExecute: { _ in },
            onCancel: {}
        )
        #expect(sheet.diffSummaryLine.isEmpty)
    }

    @Test("diffSummaryLine: 格式为 '+N -M'")
    @MainActor
    func diffSummaryLine_formatsCorrectly() throws {
        let (container, pending) = try makePending(totalInsertions: 42, totalDeletions: 18)
        _ = container
        let sheet = RewindConfirmationSheet(
            pending: pending,
            onExecute: { _ in },
            onCancel: {}
        )
        #expect(sheet.diffSummaryLine == "+42 -18")
    }

    @Test("diffSummaryLine: 只有 insertions 时正确格式化")
    @MainActor
    func diffSummaryLine_insertionsOnly() throws {
        let (container, pending) = try makePending(totalInsertions: 10, totalDeletions: 0)
        _ = container
        let sheet = RewindConfirmationSheet(
            pending: pending,
            onExecute: { _ in },
            onCancel: {}
        )
        #expect(sheet.diffSummaryLine == "+10 -0")
    }

    // MARK: truncationDescription

    @Test("truncationDescription: 无工具调用时只显示消息数")
    @MainActor
    func truncationDescription_noToolCalls() throws {
        let (container, pending) = try makePending(messagesAfterCount: 5, toolCallsAfterCount: 0)
        _ = container
        let sheet = RewindConfirmationSheet(
            pending: pending,
            onExecute: { _ in },
            onCancel: {}
        )
        #expect(sheet.truncationDescription == "将移除 5 条消息")
    }

    @Test("truncationDescription: 有工具调用时显示括号内容")
    @MainActor
    func truncationDescription_withToolCalls() throws {
        let (container, pending) = try makePending(messagesAfterCount: 3, toolCallsAfterCount: 12)
        _ = container
        let sheet = RewindConfirmationSheet(
            pending: pending,
            onExecute: { _ in },
            onCancel: {}
        )
        #expect(sheet.truncationDescription == "将移除 3 条消息（含 12 次工具调用）")
    }

    @Test("truncationDescription: 0 条消息时正确显示（无可截断消息场景）")
    @MainActor
    func truncationDescription_zeroMessages() throws {
        let (container, pending) = try makePending(messagesAfterCount: 0, toolCallsAfterCount: 0)
        _ = container
        let sheet = RewindConfirmationSheet(
            pending: pending,
            onExecute: { _ in },
            onCancel: {}
        )
        #expect(sheet.truncationDescription == "将移除 0 条消息")
    }

    // MARK: messagePreview

    @Test("messagePreview: 短消息原样返回")
    @MainActor
    func messagePreview_shortText() throws {
        let (container, pending) = try makePending(messageText: "short message")
        _ = container
        let sheet = RewindConfirmationSheet(
            pending: pending,
            onExecute: { _ in },
            onCancel: {}
        )
        #expect(sheet.messagePreview == "short message")
    }

    @Test("messagePreview: 超过 80 字符时截断并加省略号")
    @MainActor
    func messagePreview_longText_truncated() throws {
        let longText = String(repeating: "a", count: 100)
        let (container, pending) = try makePending(messageText: longText)
        _ = container
        let sheet = RewindConfirmationSheet(
            pending: pending,
            onExecute: { _ in },
            onCancel: {}
        )
        #expect(sheet.messagePreview.count == 81)  // 80 chars + "…"
        #expect(sheet.messagePreview.hasSuffix("…"))
    }

    @Test("messagePreview: nil 文本时返回占位文字")
    @MainActor
    func messagePreview_nilText_returnsPlaceholder() throws {
        let (container, pending) = try makePending(messageText: nil)
        _ = container
        let sheet = RewindConfirmationSheet(
            pending: pending,
            onExecute: { _ in },
            onCancel: {}
        )
        #expect(sheet.messagePreview == "（空消息）")
    }
}
