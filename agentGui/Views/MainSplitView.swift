//
//  MainSplitView.swift
//  agentGui
//
//  Created by feint on 2026/2/10.
//

import SwiftUI
import SwiftData

/// 主界面分割视图
/// 左侧显示会话列表，右侧显示聊天界面
struct MainSplitView: View {

    // MARK: - Environment

    @Environment(\.modelContext) private var modelContext

    // MARK: - Properties

    @State private var selectedSession: Session?
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    // MARK: - Body

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // 侧边栏：会话列表
            SessionListView { session in
                selectedSession = session
                if columnVisibility == .detailOnly {
                    columnVisibility = .all
                }
            }
        } detail: {
            // 详情：聊天界面
            if let session = selectedSession {
                ChatView(session: session)
            } else {
                emptyDetailState
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    // MARK: - Empty Detail State

    private var emptyDetailState: some View {
        ContentUnavailableView {
            Label("选择会话", systemImage: "bubble.left.and.bubble.right")
        } description: {
            Text("从左侧选择一个会话开始对话，或创建新会话")
        }
    }
}

// MARK: - Preview

#Preview {
    MainSplitView()
}
