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
                Button("复制为本地会话") { cloneCurrentSessionAsLocal() }
                    .disabled(sessionInteractionPolicy.canCloneAsLocal == false)
                Button("清除对话") { clearMessages() }
                    .disabled(sessionInteractionPolicy.canClearMessages == false)
                Divider()
                Button(role: .destructive) { deleteCurrentSession() } label: {
                    Label("删除当前对话", systemImage: "trash")
                }
                .disabled(sessionInteractionPolicy.canDelete == false)
                Button(role: .destructive) { deleteAllSessions() } label: {
                    Label(isDeletingAllSessions ? "正在删除所有会话..." : "删除所有会话", systemImage: "trash.slash")
                }
                .disabled(isDeletingAllSessions || allSessions.contains(where: { SessionInteractionPolicy(session: $0).canDelete }) == false)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }

        ToolbarItem(placement: .primaryAction) {
            NewSessionExecutionProviderMenu(
                accessibilityIdentifier: "chat.newSessionButton",
                onSelect: createNewSession(providerReference:)
            ) {
                Image(systemName: "plus")
            }
            .help("新建对话")
        }

        ToolbarItem(placement: .primaryAction) {
            if rmsRuntimeEnabled {
                Button {
                    showingRMSPanel.toggle()
                } label: {
                    Image(systemName: "brain")
                }
                .help("查看当前会话的 RMS 状态")
                .accessibilityIdentifier("chat.rmsPanelButton")
                .popover(isPresented: $showingRMSPanel, arrowEdge: .bottom) {
                    RMSPanel(sessionID: session.sessionId)
                }
            }
        }
    }


    // MARK: - Actions

    func clearMessages() {
        guard sessionInteractionPolicy.canClearMessages else {
            errorMessage = sessionInteractionPolicy.readOnlyReason
            return
        }

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

    func createNewSession(providerReference: ExecutionProviderReference) {
        let newSession = Session()
        newSession.defaultExecutionProviderReference = providerReference
        modelContext.insert(newSession)
        try? modelContext.save()
        workspaceState.selectedSession = newSession
    }

    private func deleteCurrentSession() {
        do {
            let deleted = try SessionToolbarActions(modelContext: modelContext, workspaceState: workspaceState)
                .deleteCurrentSessionIfAllowed()
            if deleted == false {
                errorMessage = sessionInteractionPolicy.readOnlyReason
            }
        } catch {
            errorMessage = error.localizedDescription
        }
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

    private func cloneCurrentSessionAsLocal() {
        do {
            _ = try SessionToolbarActions(modelContext: modelContext, workspaceState: workspaceState)
                .cloneCurrentSessionAsLocal()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

@MainActor
struct SessionToolbarActions {
    let modelContext: ModelContext
    let workspaceState: WorkspaceState

    @discardableResult
    func cloneCurrentSessionAsLocal() throws -> Session? {
        guard let current = workspaceState.selectedSession else { return nil }
        return try cloneSessionAsLocal(current)
    }

    @discardableResult
    func cloneSessionAsLocal(_ session: Session) throws -> Session? {
        guard SessionInteractionPolicy(session: session).canCloneAsLocal else {
            return nil
        }

        let cloned = Session(title: session.title, kind: .local)
        cloned.workingDirectory = session.workingDirectory
        cloned.defaultExecutionProviderReference = session.defaultExecutionProviderReference
        cloned.planJson = session.planJson
        cloned.executionPreferencesJSON = session.executionPreferencesJSON
        modelContext.insert(cloned)

        for message in session.messages.sorted(by: { $0.sequence < $1.sequence }) {
            let clonedMessage = Message(
                direction: message.direction,
                contentType: message.contentType,
                text: message.textContent,
                session: cloned
            )
            clonedMessage.status = message.status
            clonedMessage.sequence = message.sequence
            clonedMessage.timestamp = message.timestamp
            clonedMessage.errorMessage = message.errorMessage
            modelContext.insert(clonedMessage)
        }

        try modelContext.save()
        workspaceState.selectedSession = cloned
        return cloned
    }

    func deleteCurrentSession() {
        _ = try? deleteCurrentSessionIfAllowed()
    }

    @discardableResult
    func deleteCurrentSessionIfAllowed() throws -> Bool {
        guard let current = workspaceState.selectedSession else { return false }
        guard SessionInteractionPolicy(session: current).canDelete else {
            return false
        }

        try SessionDeletionCoordinator().delete(current, modelContext: modelContext)
        workspaceState.selectedSession = fetchMostRecentSession()
        return true
    }

    func deleteAllSessions(batchSize: Int = 50) async {
        let descriptor = FetchDescriptor<Session>()
        let sessions = ((try? modelContext.fetch(descriptor)) ?? [])
            .filter { SessionInteractionPolicy(session: $0).canDelete }
        let effectiveBatchSize = max(1, batchSize)

        workspaceState.selectedSession = nil
        await SessionDeletionCoordinator().deleteAllSessions(
            modelContext: modelContext,
            sessions: sessions,
            batchSize: effectiveBatchSize
        )
    }

    private func fetchMostRecentSession() -> Session? {
        let descriptor = FetchDescriptor<Session>(
            sortBy: [SortDescriptor(\Session.updatedAt, order: .reverse)]
        )
        return try? modelContext.fetch(descriptor).first
    }
}
