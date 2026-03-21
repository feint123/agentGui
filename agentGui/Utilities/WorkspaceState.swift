//
//  WorkspaceState.swift
//  agentGui
//

import AppKit
import Foundation
import SwiftData
import Observation

@MainActor
enum WorkspaceDirectorySelectionCoordinator {
    static let requestNotification = Notification.Name("WorkspaceDirectorySelectionRequested")

    static func requestFromSystemMenu() {
        NotificationCenter.default.post(name: requestNotification, object: nil)
    }

    static func presentOpenPanel() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "选择工作目录"
        panel.prompt = "选择"

        guard panel.runModal() == .OK else { return nil }
        return panel.url?.standardizedFileURL
    }

    @discardableResult
    static func applySelection(
        _ url: URL,
        workspaceState: WorkspaceState?,
        modelContext: ModelContext,
        persistenceCoordinator: PersistenceCoordinator,
        userMessage: String
    ) -> Bool {
        let normalizedPath = url.standardizedFileURL.path

        if let session = workspaceState?.selectedSession {
            session.workingDirectory = normalizedPath
        }

        let settings = AppSettings.getOrCreate(in: modelContext, persistenceCoordinator: persistenceCoordinator)
        settings.workingDirectory = normalizedPath

        do {
            try persistenceCoordinator.save(
                modelContext,
                domain: .settings,
                userMessage: userMessage
            )
            return true
        } catch {
            return false
        }
    }
}

/// 全局工作区状态，通过 @Environment 注入到所有视图
/// 负责协调：当前会话、当前打开的文件、工作目录
@Observable
@MainActor
final class WorkspaceState {

    // MARK: - State

    /// 当前激活的对话（nil = 无选中对话）
    var selectedSession: Session?

    /// 当前在文件编辑器中打开的文件 URL（nil = 编辑器显示空状态）
    var selectedFile: URL? {
        didSet {
            if selectedFile != nil {
                clearChangeProposalSelection()
            }
        }
    }

    /// 当前编辑器中的选区快照（文字与对应文件行范围）。
    var editorSelection: EditorSelectionSnapshot?

    /// 当前编辑器中选中的文字（nil = 无选中）
    var editorSelectedText: String? {
        get { editorSelection?.text }
        set {
            let lineRange = editorSelection?.lineRange
            if newValue == nil, lineRange == nil {
                editorSelection = nil
            } else {
                editorSelection = EditorSelectionSnapshot(text: newValue, lineRange: lineRange)
            }
        }
    }

    /// 当前编辑器选区对应的文件行范围。
    var editorSelectedLineRange: FileLineRange? {
        get { editorSelection?.lineRange }
        set {
            let text = editorSelection?.text
            if text == nil, newValue == nil {
                editorSelection = nil
            } else {
                editorSelection = EditorSelectionSnapshot(text: text, lineRange: newValue)
            }
        }
    }

    /// 被外部程序修改的文件 URL；FileEditorView 观察此属性以刷新编辑器内容。
    /// 消费后应置回 nil。
    var externallyModifiedFile: URL?

    /// 当前在编辑区预览的 Git diff 对应文件。
    var selectedGitDiffPath: URL? {
        didSet {
            if selectedGitDiffPath != nil {
                clearChangeProposalSelection()
            }
        }
    }

    /// 当前在编辑区预览的 Git diff 文本。
    var selectedGitDiffText: String?

    /// 当前 Git diff 视图标题。
    var selectedGitDiffTitle: String?

    /// 当前在编辑区打开的变更提案 ID。
    var selectedChangeProposalID: UUID? {
        didSet {
            if selectedChangeProposalID != nil {
                clearGitDiffSelection()
            }
        }
    }

    /// 当前在变更提案审查器中选中的文件路径。
    var selectedChangeProposalFilePath: String?

    // MARK: - Computed

    /// 当前有效工作目录：优先使用 session 级别设置，回退到 AppSettings 全局配置
    func effectiveWorkingDirectory(globalDefault: String) -> String {
        let sessionDir = selectedSession?.workingDirectory ?? ""
        if !sessionDir.isEmpty { return sessionDir }
        return globalDefault
    }

    func effectiveWorkingDirectoryURL(globalDefault: String) -> URL? {
        let directory = effectiveWorkingDirectory(globalDefault: globalDefault)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !directory.isEmpty else { return nil }
        return URL(fileURLWithPath: directory).standardizedFileURL
    }

    func effectiveWorkingDirectoryName(globalDefault: String) -> String? {
        effectiveWorkingDirectoryURL(globalDefault: globalDefault)?.lastPathComponent
    }

    func effectiveWorkingDirectoryPath(globalDefault: String) -> String? {
        effectiveWorkingDirectoryURL(globalDefault: globalDefault)?.path
    }

    func clearGitDiffSelection() {
        selectedGitDiffPath = nil
        selectedGitDiffText = nil
        selectedGitDiffTitle = nil
    }

    func selectChangeProposal(_ proposalID: UUID, filePath: String? = nil) {
        selectedChangeProposalFilePath = filePath
        selectedChangeProposalID = proposalID
    }

    func clearChangeProposalSelection() {
        selectedChangeProposalID = nil
        selectedChangeProposalFilePath = nil
    }
}

