//
//  MainSplitView.swift
//  agentGui
//
//  Created by feint on 2026/2/10.
//

import SwiftUI

/// 兼容旧入口，当前主界面由统一的 WorkbenchShellView 提供。
struct MainSplitView: View {
    var body: some View {
        WorkbenchShellView()
    }
}

// MARK: - Preview

#Preview {
    MainSplitView()
}
