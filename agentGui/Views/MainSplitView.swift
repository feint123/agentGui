//
//  MainSplitView.swift
//  agentGui
//
//  Created by feint on 2026/2/10.
//

import SwiftUI
import SwiftData

/// 主界面三栏分割视图
/// 左侧：文件浏览器
/// 中间：文件编辑器
/// 右侧：聊天界面（含顶部对话 Picker）
struct MainSplitView: View {

    // MARK: - Properties

    @State private var workspaceState = WorkspaceState()
    @State private var gitPanelViewModel = GitPanelViewModel()
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @Environment(\.modelContext) private var modelContext

    // MARK: - Query

    @Query(sort: \Session.updatedAt, order: .reverse)
    private var sessions: [Session]

    // MARK: - Body

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            WorkspacePanelView()
                .accessibilityIdentifier("panel.workspace")
                .navigationTitle("文件")
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
        } content: {
            FileEditorView()
                .accessibilityIdentifier("panel.editor")
                .navigationSplitViewColumnWidth(min: 280, ideal: 400)
        } detail: {
            if let session = workspaceState.selectedSession {
                ChatView(session: session)
                    .accessibilityIdentifier("panel.chat")
            } else {
                emptyDetailState
                    .accessibilityIdentifier("panel.chat.empty")
            }
        }
        .navigationSplitViewStyle(.balanced)
        .environment(workspaceState)
        .environment(gitPanelViewModel)
        .onAppear {
            if workspaceState.selectedSession == nil {
                workspaceState.selectedSession = sessions.first
            }
        }
        .onChange(of: sessions) { _, newSessions in
            // If selected session was deleted, fall back to most recent
            if let current = workspaceState.selectedSession,
               !newSessions.contains(where: { $0.persistentModelID == current.persistentModelID }) {
                workspaceState.selectedSession = newSessions.first
            }
            // If nothing selected and sessions exist, auto-select
            if workspaceState.selectedSession == nil {
                workspaceState.selectedSession = newSessions.first
            }
        }
    }

    // MARK: - Empty Detail State

    private var emptyDetailState: some View {
        ContentUnavailableView {
            Label("无对话", systemImage: "bubble.left.and.bubble.right")
        } description: {
            Text("点击工具栏的 + 开始新对话")
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    let newSession = Session()
                    modelContext.insert(newSession)
                    try? modelContext.save()
                    workspaceState.selectedSession = newSession
                } label: {
                    Image(systemName: "plus")
                }
                .help("新建对话")
                .accessibilityIdentifier("chat.newSessionButton")
            }
        }
    }
}

// MARK: - Preview

#Preview {
    MainSplitView()
}
