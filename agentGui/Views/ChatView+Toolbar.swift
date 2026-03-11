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
            sessionPickerView
        }

        ToolbarItem(placement: .primaryAction) {
            if storyMemoryEnabled {
                Button {
                    showStoryProjectBrowser = true
                } label: {
                    Label(activeStoryProject?.title ?? "创作记忆", systemImage: activeStoryProject == nil ? "books.vertical" : "book.fill")
                }
                .help(activeStoryProject == nil ? "打开创作项目浏览器" : "当前项目：\(activeStoryProject?.title ?? "")")
            }
        }

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

        ToolbarItem(placement: .primaryAction) {
            Button {
                createNewSession()
            } label: {
                Image(systemName: "plus")
            }
            .help("新建对话")
            .accessibilityIdentifier("chat.newSessionButton")
        }

        ToolbarItem(placement: .primaryAction) {
            if !allWorkflows.isEmpty {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showWorkflowPanel.toggle()
                    }
                } label: {
                    Image(systemName: showWorkflowPanel ? "sidebar.right" : "flowchart")
                }
                .help(showWorkflowPanel ? "隐藏 Workflow 面板" : "显示 Workflow 面板")
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
                        .frame(maxWidth: 150)
                        .tag(Optional(session))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 200)
            .accessibilityIdentifier("chat.sessionPicker")
        }
    }

    // MARK: - Actions

    func clearMessages() {
        activeTask?.cancel()
        activeTask = nil
        isClearingMessages = true
        Task { @MainActor in
            let snapshot = Array(allMessages)
            for message in snapshot {
                _ = message.toolCalls
                _ = message.agentRounds
                modelContext.delete(message)
            }
            try? modelContext.save()
            isClearingMessages = false
        }
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
        workspaceState.selectedSession = allSessions.first
    }
}
