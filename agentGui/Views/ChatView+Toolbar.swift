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
        // 对话选择器（左侧/中央）
        ToolbarItem(placement: .navigation) {
            sessionPickerView
        }

        // 更多操作菜单（右侧）
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("清除对话") { clearMessages() }
                Divider()
                Button(role: .destructive) { deleteCurrentSession() } label: {
                    Label("删除当前对话", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    // MARK: - Session Picker

    @ViewBuilder
    private var sessionPickerView: some View {
        HStack(spacing: 4) {
            Picker("", selection: Binding(
                get: { workspaceState.selectedSession },
                set: { workspaceState.selectedSession = $0 }
            )) {
                ForEach(allSessions) { session in
                    Text(session.title.isEmpty ? "新对话" : session.title)
                        .tag(Optional(session))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 200)

            Button {
                createNewSession()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("新建对话")
        }
    }

    // MARK: - Actions

    func clearMessages() {
        for message in allMessages {
            modelContext.delete(message)
        }
        try? modelContext.save()
    }

    func createNewSession() {
        let newSession = Session()
        modelContext.insert(newSession)
        try? modelContext.save()
        workspaceState.selectedSession = newSession
    }

    private func deleteCurrentSession() {
        guard let current = workspaceState.selectedSession else { return }
        modelContext.delete(current)
        try? modelContext.save()
        // Select most recent remaining session
        workspaceState.selectedSession = allSessions.first
    }
}
