//
//  ChatView+Toolbar.swift
//  agentGui
//

import SwiftUI
import SwiftData

extension ChatView {

    // MARK: - Toolbar

    @ToolbarContentBuilder
    var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("清除对话") { clearMessages() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    func clearMessages() {
        for message in allMessages {
            modelContext.delete(message)
        }
        try? modelContext.save()
    }
}
