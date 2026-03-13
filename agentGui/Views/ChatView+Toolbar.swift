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
            Menu {
                Button("清除对话") { clearMessages() }
                Divider()
                Button(role: .destructive) { deleteCurrentSession() } label: {
                    Label("删除当前对话", systemImage: "trash")
                }
                Button(role: .destructive) { deleteAllSessions() } label: {
                    Label(isDeletingAllSessions ? "正在删除所有会话..." : "删除所有会话", systemImage: "trash.slash")
                }
                .disabled(isDeletingAllSessions)
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
        SessionToolbarActions(modelContext: modelContext, workspaceState: workspaceState).deleteCurrentSession()
    }

    private func deleteAllSessions() {
        guard !isDeletingAllSessions else { return }

        activeTask?.cancel()
        activeTask = nil
        isDeletingAllSessions = true

        Task { @MainActor in
            await SessionToolbarActions(modelContext: modelContext, workspaceState: workspaceState)
                .deleteAllSessions(batchSize: 50)
            isDeletingAllSessions = false
        }
    }
}

@MainActor
struct SessionToolbarActions {
    let modelContext: ModelContext
    let workspaceState: WorkspaceState

    func deleteCurrentSession() {
        guard let current = workspaceState.selectedSession else { return }
        modelContext.delete(current)
        try? modelContext.save()
        workspaceState.selectedSession = fetchMostRecentSession()
    }

    func deleteAllSessions(batchSize: Int = 50) async {
        let descriptor = FetchDescriptor<Session>()
        let sessions = (try? modelContext.fetch(descriptor)) ?? []
        let effectiveBatchSize = max(1, batchSize)

        workspaceState.selectedSession = nil

        var pendingDeletes = 0
        for session in sessions {
            modelContext.delete(session)
            pendingDeletes += 1

            if pendingDeletes == effectiveBatchSize {
                try? modelContext.save()
                pendingDeletes = 0
                await Task.yield()
            }
        }

        if pendingDeletes > 0 {
            try? modelContext.save()
        }
    }

    private func fetchMostRecentSession() -> Session? {
        let descriptor = FetchDescriptor<Session>(
            sortBy: [SortDescriptor(\Session.updatedAt, order: .reverse)]
        )
        return try? modelContext.fetch(descriptor).first
    }
}
