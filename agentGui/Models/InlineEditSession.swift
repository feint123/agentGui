// agentGui/Models/InlineEditSession.swift
import Foundation

/// 单次内联编辑会话的状态快照。
///
/// 设计对标 Zed `EditState`（project_panel.rs）：
/// 一个 optional 的 `edit_state: Option<EditState>` 持有当前会话，nil = 非编辑态。
/// 本计划将会话存于 `FileTreeViewModel`（@MainActor），而非 `FileTreeStore` actor，
/// 因为它是纯 UI 状态——不影响磁盘，也无需跨 actor 共享。
struct InlineEditSession: Sendable, Equatable {

    enum Kind: Sendable, Equatable {
        /// 新建文件：提交时调 `WorkspaceFileTreeOperations.createFile`。
        case createFile
        /// 新建文件夹：提交时调 `WorkspaceFileTreeOperations.createDirectory`。
        case createFolder
        /// 重命名：`targetEntryID` 为被重命名条目；提交时调 `WorkspaceFileTreeOperations.renameItem`。
        case rename
    }

    let kind: Kind
    /// 新建时：新条目所在父目录 ID。重命名时：被重命名条目的父目录 ID。
    let parentDirectoryID: EntryID
    /// nil → 新建（create）；非 nil → 重命名目标。
    /// 对标 Zed `EditState.leaf_entry_id: Option<ProjectEntryId>`。
    let targetEntryID: EntryID?
    /// 占位行在 `visibleEntries` 中的插入索引（重命名时无意义，设 -1）。
    let placeholderIndex: Int
    /// 用户当前输入的草稿名称（实时更新）。
    var draftName: String

    /// 是否为新建操作（对标 Zed `EditState.is_new_entry()`）。
    var isNewEntry: Bool { targetEntryID == nil }

    // MARK: - 校验

    /// 对 `draftName` 进行校验，返回第一个发现的错误。
    ///
    /// 设计对标：
    /// - VSCode `editableData.validationMessage(value)` — 返回 `IFileOperationResult?`
    /// - Zed `populate_validation_error(cx)` — 检查 empty / whitespace / already_exists
    ///
    /// 调用时机：`FileTreeInlineTextField.controlTextDidChange` 实时调用（显示提示），
    /// 以及 `FileTreeViewModel.commitEdit()` 中再次调用（最终守卫）。
    ///
    /// - Parameter siblingNames: 父目录的直接子条目名称列表（用于重复名检测）。
    func validateDraftName(siblingNames: [String]) -> EditValidationError? {
        let trimmed = draftName.trimmingCharacters(in: .whitespaces)

        // 1. 空名（Zed: "Name cannot be empty"）
        if trimmed.isEmpty { return .emptyName }

        // 2. 非法字符（VSCode 拒绝 '/' '\0'；macOS 文件名同样不允许）
        for char in ["/", "\0"] where draftName.contains(char) {
            return .illegalCharacter(char)
        }

        // 3. 重复名（大小写不敏感，对标 Zed `already_exists` 检测）
        let lower = trimmed.lowercased()
        if siblingNames.contains(where: { $0.lowercased() == lower }) {
            return .duplicateName(trimmed)
        }

        return nil
    }
}

/// 内联编辑校验错误。
///
/// 对标 VSCode `MessageType.ERROR/WARNING` 分类
/// 及 Zed `ValidationState::Error(SharedString) / Warning` 枚举。
enum EditValidationError: LocalizedError, Equatable {
    case emptyName
    case duplicateName(String)
    case illegalCharacter(String)

    var errorDescription: String? {
        switch self {
        case .emptyName:
            return "名称不能为空。"
        case .duplicateName(let name):
            return "\"\(name)\" 已存在，请使用其他名称。"
        case .illegalCharacter(let char):
            return "名称不能包含字符 \"\(char)\"。"
        }
    }
}
