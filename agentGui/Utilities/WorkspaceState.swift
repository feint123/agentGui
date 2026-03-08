//
//  WorkspaceState.swift
//  agentGui
//

import Foundation
import SwiftData
import Observation

/// 全局工作区状态，通过 @Environment 注入到所有视图
/// 负责协调：当前会话、当前打开的文件、工作目录
@Observable
@MainActor
final class WorkspaceState {

    // MARK: - State

    /// 当前激活的对话（nil = 无选中对话）
    var selectedSession: Session?

    /// 当前在文件编辑器中打开的文件 URL（nil = 编辑器显示空状态）
    var selectedFile: URL?

    /// 当前编辑器中选中的文字（nil = 无选中）
    var editorSelectedText: String?

    /// 被外部程序修改的文件 URL；FileEditorView 观察此属性以刷新编辑器内容。
    /// 消费后应置回 nil。
    var externallyModifiedFile: URL?

    // MARK: - Computed

    /// 当前有效工作目录：优先使用 session 级别设置，回退到 AppSettings 全局配置
    func effectiveWorkingDirectory(globalDefault: String) -> String {
        let sessionDir = selectedSession?.workingDirectory ?? ""
        if !sessionDir.isEmpty { return sessionDir }
        return globalDefault
    }
}
