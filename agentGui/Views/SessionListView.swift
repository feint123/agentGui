//
//  SessionListView.swift
//  agentGui
//
//  Created by feint on 2026/2/10.
//

import SwiftUI
import SwiftData

/// 会话列表视图 — 显示所有对话，支持新建和删除
struct SessionListView: View {

    // MARK: - Environment

    @Environment(\.modelContext) private var modelContext

    // MARK: - Query

    @Query(sort: \Session.updatedAt, order: .reverse)
    private var sessions: [Session]

    // MARK: - State

    @State private var sessionToDelete: Session?
    @State private var showingDeleteAlert = false
    @State private var errorMessage: String?

    var onSessionSelected: (Session) -> Void

    // MARK: - Body

    var body: some View {
        Group {
            if sessions.isEmpty {
                emptyStateView
            } else {
                sessionsList
            }
        }
        .navigationTitle("对话")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    createNewSession()
                } label: {
                    Label("新对话", systemImage: "plus")
                }
                .accessibilityIdentifier("sessionList.createButton")
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
    }

    // MARK: - Views

    private var emptyStateView: some View {
        ContentUnavailableView {
            Label("暂无对话", systemImage: "bubble.left.and.bubble.right")
        } description: {
            Text("点击右上角的 + 开始新对话")
        } actions: {
            Button("新对话") {
                createNewSession()
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("sessionList.createButton")
        }
        .accessibilityIdentifier("sessionList.emptyState")
    }

    private var sessionsList: some View {
        List {
            ForEach(sessions) { session in
                SessionRowView(session: session) {
                    onSessionSelected(session)
                }
                .accessibilityIdentifier("sessionList.item.\(session.sessionId)")
                .contextMenu {
                    Button(role: .destructive) {
                        sessionToDelete = session
                        showingDeleteAlert = true
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        sessionToDelete = session
                        showingDeleteAlert = true
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .accessibilityIdentifier("sessionList.list")
    }

    // MARK: - Actions

    private func createNewSession() {
        let newSession = Session()
        newSession.defaultExecutionProviderID = AppSettings.getOrCreate(in: modelContext).defaultExecutionProviderID
        modelContext.insert(newSession)
        do {
            try modelContext.save()
            onSessionSelected(newSession)
        } catch {
            errorMessage = "创建对话失败: \(error.localizedDescription)"
        }
    }

    private func deleteConfirmedSession() {
        guard let session = sessionToDelete else { return }
        do {
            try SessionDeletionCoordinator().delete(session, modelContext: modelContext)
        } catch {
            errorMessage = "删除对话失败: \(error.localizedDescription)"
        }
        sessionToDelete = nil
    }
}

// MARK: - Session Row View

private struct SessionRowView: View {
    let session: Session
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                sessionIcon
                    .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: 3) {
                    Text(session.title)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(session.lastMessagePreview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

// MARK: - Preview

#Preview {
    NavigationStack {
        SessionListView { _ in }
    }
}
