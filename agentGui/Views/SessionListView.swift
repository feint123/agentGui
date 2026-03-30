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
    @State private var inlineRename = InlineRenameState<String>()
    @State private var viewModel = SessionCatalogViewModel()
    @Namespace private var selectionNamespace

    var onSessionSelected: (Session) -> Void

    private var globalWorkingDirectory: String {
        AppSettings.getOrCreate(in: modelContext).workingDirectory
    }

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

                NewSessionExecutionProviderMenu(
                    sourceSession: workspaceState.selectedSession,
                    accessibilityIdentifier: "sessionList.createButton",
                    onSelect: createNewSession(action:)
                ) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive().tint(Color.accentColor.opacity(0.3)), in: Circle())
                .help("新对话")
            }
        }
        .padding(10)
    }

    private var emptyStateView: some View {
        WorkbenchSidebarEmptyStateView(
            systemImage: "bubble.left.and.bubble.right",
            title: "暂无对话",
            message: "点击右上角的 + 开始新对话"
        ) {
            NewSessionExecutionProviderMenu(
                sourceSession: workspaceState.selectedSession,
                accessibilityIdentifier: "sessionList.createButton",
                onSelect: createNewSession(action:)
            ) {
                Text("新建对话")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .accessibilityIdentifier("sessionList.emptyState")
    }

    private var searchEmptyStateView: some View {
        WorkbenchSidebarEmptyStateView(
            systemImage: "magnifyingglass",
            title: "未找到匹配会话",
            message: viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "尝试修改搜索词，或新建一个本地会话。"
                : "“\(viewModel.searchText)” 没有结果"
        ) {
            HStack(spacing: 8) {
                Button("清空搜索") {
                    viewModel.searchText = ""
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                NewSessionExecutionProviderMenu(
                    sourceSession: workspaceState.selectedSession,
                    accessibilityIdentifier: "sessionList.createButton",
                    onSelect: createNewSession(action:)
                ) {
                    Text("新建对话")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
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
                            projection: workspaceState.executionProjection(for: item.session.sessionId),
                            canRename: item.canRename,
                            globalWorkingDirectory: globalWorkingDirectory,
                            isRenaming: inlineRename.isEditing(item.session.sessionId),
                            renameText: renameBinding(for: item.session),
                            selectionNamespace: selectionNamespace,
                            onTap: {
                                selectSession(item.session)
                            },
                            onBeginRename: {
                                beginInlineRename(for: item.session, canRename: item.canRename)
                            },
                            onCommitRename: {
                                commitInlineRename()
                            },
                            onCancelRename: {
                                inlineRename.cancel()
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
                                beginInlineRename(for: item.session, canRename: item.canRename)
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

    private func createNewSession(action: NewSessionMenuAction) {
        do {
            let createdSession: Session
            switch action {
            case .localChat(let providerReference, _):
                let newSession = Session()
                newSession.defaultExecutionProviderReference = providerReference
                modelContext.insert(newSession)
                try modelContext.save()
                createdSession = newSession
            case .agentTeam(let source):
                createdSession = try AgentTeamSessionFactory()
                    .create(fromSourceContext: source, modelContext: modelContext)
                    .session
            }

            viewModel.reload()
            withAnimation(.snappy(duration: 0.24, extraBounce: 0.03)) {
                onSessionSelected(createdSession)
            }
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
                withAnimation(.snappy(duration: 0.24, extraBounce: 0.03)) {
                    onSessionSelected(cloned)
                }
            }
        } catch {
            errorMessage = "复制本地会话失败: \(error.localizedDescription)"
        }
    }

    private func selectSession(_ session: Session) {
        if let draft = inlineRename.draft,
           draft.id != session.sessionId {
            inlineRename.cancel()
        }

        withAnimation(.snappy(duration: 0.24, extraBounce: 0.03)) {
            onSessionSelected(session)
        }
    }

    private func beginInlineRename(for session: Session, canRename: Bool) {
        guard canRename else { return }

        withAnimation(.easeInOut(duration: 0.16)) {
            inlineRename.begin(id: session.sessionId, text: session.title)
        }
    }

    private func commitInlineRename() {
        guard let candidate = inlineRename.commitCandidate else {
            errorMessage = SessionCatalogViewModel.ValidationError.emptyTitle.localizedDescription
            return
        }

        guard candidate.hasChanges else {
            inlineRename.cancel()
            return
        }

        guard let session = sessions.first(where: { $0.sessionId == candidate.id }) else {
            inlineRename.cancel()
            return
        }

        do {
            try viewModel.rename(session: session, to: candidate.trimmedText)
            withAnimation(.snappy(duration: 0.22, extraBounce: 0.02)) {
                inlineRename.cancel()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func renameBinding(for session: Session) -> Binding<String> {
        Binding(
            get: {
                if inlineRename.draft?.id == session.sessionId {
                    return inlineRename.draft?.text ?? session.title
                }
                return session.title
            },
            set: { newValue in
                inlineRename.update(text: newValue)
            }
        )
    }
}

// MARK: - Session Row View

private struct SessionRowView: View {
    let session: Session
    let isSelected: Bool
    let projection: SessionExecutionProjection
    let canRename: Bool
    let globalWorkingDirectory: String
    let isRenaming: Bool
    @Binding var renameText: String
    let selectionNamespace: Namespace.ID
    let onTap: () -> Void
    let onBeginRename: () -> Void
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void

    @State private var isHovered = false

    var body: some View {
        Group {
            if isRenaming {
                rowCard
            } else {
                Button(action: onTap) {
                    rowCard
                }
                .buttonStyle(.plain)
                .simultaneousGesture(
                    TapGesture(count: 2).onEnded {
                        onBeginRename()
                    }
                )
            }
        }
        .onHover { hovered in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovered
            }
        }
    }

    private var rowCard: some View {
        let workspacePresentation = SessionWorkspacePresentationFactory().build(
            session: session,
            globalWorkingDirectory: globalWorkingDirectory
        )

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                HStack(spacing: 6) {
                    if isRenaming {
                        InlineNameField(
                            text: $renameText,
                            placeholder: "会话名称",
                            onCommit: onCommitRename,
                            onCancel: onCancelRename
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: 18)
                    } else {
                        Text(session.title)
                            .font(.body.weight(isSelected ? .semibold : .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }

                    if canRename == false {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 8)

                Text(session.updatedAt.formatted(.relative(presentation: .named)))
                    .font(.caption2)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.primary.opacity(0.82)) : AnyShapeStyle(.tertiary))
                    .lineLimit(1)
            }

            HStack(spacing: 6) {
                SessionRowChip(systemImage: "bubble.left.and.text.bubble.right", text: session.displaySourceTitle)
                SessionRowChip(systemImage: workspacePresentation.isMissing ? "folder.badge.questionmark" : "folder", text: workspacePresentation.title)
                if let executionChip = executionChip {
                    SessionRowChip(systemImage: executionChip.systemImage, text: executionChip.text)
                }
                Spacer(minLength: 0)
                Text("\(session.messageCount) 条")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Text(sessionPreview)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { rowBackground }
        .overlay { rowBorder }
        .contentShape(.rect(cornerRadius: 14, style: .continuous))
        .animation(.snappy(duration: 0.18, extraBounce: 0.02), value: isSelected)
        .animation(.easeInOut(duration: 0.12), value: isHovered)
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(rowFillColor)
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.clear)
                        .matchedGeometryEffect(id: "session-list-selection", in: selectionNamespace)
                }
            }
            .glassEffect(rowGlassEffect, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var rowBorder: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(borderColor, lineWidth: isSelected ? 1 : 0.8)
    }

    private var rowFillColor: Color {
        if isSelected {
            return Color.accentColor.opacity(0.18)
        }
        if isRenaming {
            return Color.accentColor.opacity(0.08)
        }
        if isHovered {
            return Color.primary.opacity(0.05)
        }
        return .clear
    }

    private var borderColor: Color {
        if isSelected {
            return Color.accentColor.opacity(0.34)
        }
        if isRenaming {
            return Color.accentColor.opacity(0.22)
        }
        if isHovered {
            return Color.primary.opacity(0.10)
        }
        return .clear
    }

    private var rowGlassEffect: Glass {
        if isSelected {
            return .regular.interactive().tint(Color.accentColor.opacity(0.18))
        }
        if isRenaming {
            return .regular.interactive().tint(Color.accentColor.opacity(0.10))
        }
        if isHovered {
            return .regular.interactive().tint(Color.primary.opacity(0.04))
        }
        return .regular
    }

    private var sessionPreview: String {
        let preview = session.lastMessagePreview.trimmingCharacters(in: .whitespacesAndNewlines)
        return preview.isEmpty ? "尚无消息，点击继续当前会话。" : preview
    }

    private var executionChip: (systemImage: String, text: String)? {
        if projection.needsAttention {
            return ("exclamationmark.circle", "等待处理")
        }
        if projection.presentationState == .background, projection.activityState == .running {
            return ("arrow.triangle.2.circlepath", "后台运行")
        }
        if projection.activityState == .running {
            return ("waveform", "运行中")
        }
        if projection.activityState == .queued {
            return ("clock", "排队中")
        }
        return nil
    }
}

private struct SessionRowChip: View {
    let systemImage: String
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.caption2)
            Text(text)
                .lineLimit(1)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(.white.opacity(0.001))
        .glassEffect(.regular, in: Capsule())
    }
}

// MARK: - Preview

#Preview {
    SessionListView { _ in }
}
