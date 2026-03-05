//
//  MainSplitView.swift
//  agentGui
//
//  Created by feint on 2026/2/10.
//

import SwiftUI

/// 主界面分割视图
/// 左侧显示对话列表，右侧显示聊天界面
struct MainSplitView: View {

    // MARK: - Properties

    @State private var selectedSession: Session?
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    // MARK: - Body

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SessionListView { session in
                selectedSession = session
            }
        } detail: {
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
            Label("选择对话", systemImage: "bubble.left.and.bubble.right")
        } description: {
            Text("从左侧选择对话，或点击 + 开始新对话")
        }
    }
}

// MARK: - Preview

#Preview {
    MainSplitView()
}
