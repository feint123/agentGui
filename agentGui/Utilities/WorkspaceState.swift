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
        userMessage: String,
        recentWorkspaceStore: RecentWorkspaceStore? = nil
    ) -> Bool {
        let recentWorkspaceStore = recentWorkspaceStore ?? .shared
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
            recentWorkspaceStore.record(url)
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

    @ObservationIgnored
    var contextWindowState: WorkbenchContextWindowState?

    @ObservationIgnored
    private var isSynchronizingDetailSelection = false

    // MARK: - State

    /// 当前激活的对话（nil = 无选中对话）
    var selectedSession: Session?

    var detailSelection: WorkbenchDetailSelection {
        if let proposalID = selectedChangeProposalID {
            return .changeProposal(
                proposalID: proposalID,
                filePath: selectedChangeProposalFilePath
            )
        }

        if let title = selectedGitDiffTitle,
           let diffText = selectedGitDiffText,
           !diffText.isEmpty {
            return .gitDiff(title: title, diffText: diffText)
        }

        if let selectedFile {
            return .file(selectedFile.standardizedFileURL)
        }

        return .none
    }

    /// 当前在文件编辑器中打开的文件 URL（nil = 编辑器显示空状态）
    var selectedFile: URL? {
        didSet {
            guard !isSynchronizingDetailSelection, selectedFile != nil else { return }

            synchronizeDetailSelection {
                selectedFile = selectedFile?.standardizedFileURL
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
            guard !isSynchronizingDetailSelection, selectedGitDiffPath != nil else { return }

            synchronizeDetailSelection {
                selectedGitDiffPath = selectedGitDiffPath?.standardizedFileURL
                clearChangeProposalSelection()
            }
        }
    }

    /// 当前在编辑区预览的 Git diff 文本。
    var selectedGitDiffText: String? {
        didSet {
            guard !isSynchronizingDetailSelection, selectedGitDiffText != nil else { return }

            synchronizeDetailSelection {
                clearChangeProposalSelection()
            }
        }
    }

    /// 当前 Git diff 视图标题。
    var selectedGitDiffTitle: String? {
        didSet {
            guard !isSynchronizingDetailSelection, selectedGitDiffTitle != nil else { return }

            synchronizeDetailSelection {
                clearChangeProposalSelection()
            }
        }
    }

    /// 当前在编辑区打开的变更提案 ID。
    var selectedChangeProposalID: UUID? {
        didSet {
            if let selectedChangeProposalID {
                contextWindowState?.updateChangeProposalFilePath(
                    proposalID: selectedChangeProposalID,
                    filePath: selectedChangeProposalFilePath
                )

                guard !isSynchronizingDetailSelection else { return }

                synchronizeDetailSelection {
                    clearGitDiffSelection()
                }
            }
        }
    }

    /// 当前在变更提案审查器中选中的文件路径。
    var selectedChangeProposalFilePath: String? {
        didSet {
            if let selectedChangeProposalID {
                contextWindowState?.updateChangeProposalFilePath(
                    proposalID: selectedChangeProposalID,
                    filePath: selectedChangeProposalFilePath
                )
            }
        }
    }

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

    func showFileDetail(_ fileURL: URL?) {
        guard let fileURL else {
            selectedFile = nil
            clearGitDiffSelection()
            clearChangeProposalSelection()
            return
        }

        selectedFile = fileURL.standardizedFileURL
        clearGitDiffSelection()
        clearChangeProposalSelection()
        contextWindowState?.open(.file(fileURL.standardizedFileURL))
    }

    func showGitDiffDetail(path: URL?, title: String, diffText: String) {
        selectedFile = nil
        selectedGitDiffPath = path?.standardizedFileURL
        selectedGitDiffTitle = title
        selectedGitDiffText = diffText
        clearChangeProposalSelection()
        contextWindowState?.open(.gitDiff(title: title, diffText: diffText))
    }

    func selectChangeProposal(_ proposalID: UUID, filePath: String? = nil) {
        selectedFile = nil
        clearGitDiffSelection()
        selectedChangeProposalFilePath = filePath
        selectedChangeProposalID = proposalID
        contextWindowState?.open(.changeProposal(proposalID: proposalID, filePath: filePath))
    }

    func clearChangeProposalSelection() {
        selectedChangeProposalID = nil
        selectedChangeProposalFilePath = nil
    }

    func openContextWindow() {
        if detailSelection != .none {
            contextWindowState?.open(detailSelection)
        } else if contextWindowState?.hasTabs == true {
            contextWindowState?.requestPresentation()
        }
    }

    private func synchronizeDetailSelection(_ updates: () -> Void) {
        guard !isSynchronizingDetailSelection else {
            updates()
            return
        }

        isSynchronizingDetailSelection = true
        updates()
        isSynchronizingDetailSelection = false
    }
}

