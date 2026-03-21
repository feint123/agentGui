//
//  SessionListView.swift
//  agentGui
//
//  Created by feint on 2026/2/10.
//

import SwiftUI
import SwiftData

/// 会话列表视图 — 显示分类会话目录，支持搜索、本地重命名与新建
struct SessionListView: View {

    // MARK: - Environment

    @Environment(\.modelContext) private var modelContext
    @Environment(WorkspaceState.self) private var workspaceState

    // MARK: - Query

    @Query(sort: \Session.updatedAt, order: .reverse)
    private var sessions: [Session]

    // MARK: - State

    @State private var sessionToDelete: Session?
    @State private var showingDeleteAlert = false
    @State private var errorMessage: String?
    @State private var renameDraft: SessionRenameDraft?
    @State private var viewModel = SessionCatalogViewModel()

    var onSessionSelected: (Session) -> Void

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Group {
                if sessions.isEmpty {
                    emptyStateView
                } else if viewModel.visibleSections.isEmpty {
                    searchEmptyStateView
                } else {
                    sessionsList
                }
            }
        }
        .alert("删除对话", isPresented: $showingDeleteAlert, presenting: sessionToDelete) { _ in
            Button("取消", role: .cancel) { }
            Button("删除", role: .destructive) {
                deleteConfirmedSession()
            }
        } message: { session in
            Text("确定要删除「\(session.title)」吗？此操作不可撤销。")
        }
        .alert("错误", isPresented: .constant(errorMessage != nil)) {
            Button("确定") { errorMessage = nil }
        } message: {
            if let error = errorMessage { Text(error) }
        }
        .sheet(item: $renameDraft) { draft in
            SessionRenameSheet(draft: draft) { newTitle in
                do {
                    try viewModel.rename(session: draft.session, to: newTitle)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
        .onAppear {
            viewModel.bind(modelContext: modelContext)
            viewModel.setSessions(sessions)
        }
        .onChange(of: sessions) { _, newSessions in
            viewModel.setSessions(newSessions)
        }
    }

    // MARK: - Views

    private var headerBar: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("搜索会话", text: $viewModel.searchText)
                        .textFieldStyle(.plain)
                        .accessibilityIdentifier("sessionList.searchField")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                Button {
                    createNewSession()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive().tint(Color.accentColor.opacity(0.3)), in: Circle())
                .help("新对话")
                .accessibilityIdentifier("sessionList.createButton")
            }
        }
        .padding(10)
    }

    private var emptyStateView: some View {
        ContentUnavailableView {
            Label("暂无对话", systemImage: "bubble.left.and.bubble.right")
        } description: {
            Text("点击右上角的 + 开始新对话")
        } actions: {
            Button {
                createNewSession()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive().tint(Color.accentColor.opacity(0.3)), in: Circle())
            .accessibilityIdentifier("sessionList.createButton")
        }
        .accessibilityIdentifier("sessionList.emptyState")
    }

    private var searchEmptyStateView: some View {
        ContentUnavailableView {
            Label("未找到匹配会话", systemImage: "magnifyingglass")
        } description: {
            Text("尝试修改搜索词，或新建一个本地会话。")
        }
        .accessibilityIdentifier("sessionList.searchEmptyState")
    }

    private var sessionsList: some View {
        List {
            ForEach(viewModel.visibleSections) { section in
                Section(section.title) {
                    ForEach(section.items) { item in
                        SessionRowView(
                            session: item.session,
                            isSelected: workspaceState.selectedSession?.persistentModelID == item.session.persistentModelID,
                            canRename: item.canRename,
                            onTap: {
                                onSessionSelected(item.session)
                            }
                        )
                        .accessibilityIdentifier("sessionList.item.\(item.session.sessionId)")
                        .listRowBackground(Color.clear)
                        .contextMenu {
                            Button("复制为本地会话") {
                                cloneSession(item.session)
                            }
                            .disabled(SessionInteractionPolicy(session: item.session).canCloneAsLocal == false)

                            Button("重命名") {
                                renameDraft = SessionRenameDraft(session: item.session)
                            }
                            .disabled(item.canRename == false)

                            Button(role: .destructive) {
                                sessionToDelete = item.session
                                showingDeleteAlert = true
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                            .disabled(item.canDelete == false)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("sessionList.list")
    }

    // MARK: - Actions

    private func createNewSession() {
        let newSession = Session()
        newSession.defaultExecutionProviderID = AppSettings.getOrCreate(in: modelContext).defaultExecutionProviderID
        modelContext.insert(newSession)
        do {
            try modelContext.save()
            viewModel.reload()
            onSessionSelected(newSession)
        } catch {
            errorMessage = "创建对话失败: \(error.localizedDescription)"
        }
    }

    private func deleteConfirmedSession() {
        guard let session = sessionToDelete else { return }
        do {
            try SessionDeletionCoordinator().delete(session, modelContext: modelContext)
            viewModel.reload()
        } catch {
            errorMessage = "删除对话失败: \(error.localizedDescription)"
        }
        sessionToDelete = nil
    }

    private func cloneSession(_ session: Session) {
        do {
            if let cloned = try SessionToolbarActions(modelContext: modelContext, workspaceState: workspaceState)
                .cloneSessionAsLocal(session) {
                viewModel.reload()
                onSessionSelected(cloned)
            }
        } catch {
            errorMessage = "复制本地会话失败: \(error.localizedDescription)"
        }
    }
}

// MARK: - Session Row View

private struct SessionRowView: View {
    let session: Session
    let isSelected: Bool
    let canRename: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                sessionIcon
                    .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(session.title)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        if canRename == false {
                            Image(systemName: "lock.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text(session.displaySourceTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Text(session.lastMessagePreview)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 3) {
                    Text(session.updatedAt.formatted(.relative(presentation: .named)))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    Text("\(session.messageCount) 条消息")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .clipShape(.rect(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var sessionIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(.blue.gradient)
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
        }
    }
}

private struct SessionRenameDraft: Identifiable {
    let session: Session
    let title: String

    init(session: Session) {
        self.session = session
        self.title = session.title
    }

    var id: String {
        session.sessionId
    }
}

private struct SessionRenameSheet: View {
    @Environment(\.dismiss) private var dismiss

    let draft: SessionRenameDraft
    let onSave: (String) -> Void

    @State private var titleText: String

    init(draft: SessionRenameDraft, onSave: @escaping (String) -> Void) {
        self.draft = draft
        self.onSave = onSave
        _titleText = State(initialValue: draft.title)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("会话名称", text: $titleText)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(16)
            .navigationTitle("重命名会话")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(titleText)
                        dismiss()
                    }
                }
            }
        }
        .frame(minWidth: 360, minHeight: 160)
    }
}

// MARK: - Preview

#Preview {
    SessionListView { _ in }
}
