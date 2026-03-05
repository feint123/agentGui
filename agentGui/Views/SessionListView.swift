//
//  SessionListView.swift
//  agentGui
//
//  Created by feint on 2026/2/10.
//

import SwiftUI
import SwiftData

/// 会话列表视图
/// 显示所有历史会话，支持创建新会话
struct SessionListView: View {

    // MARK: - Environment

    @Environment(\.modelContext) private var modelContext

    // MARK: - Properties

    @State private var sessions: [Session] = []
    @State private var isLoading = false
    @State private var showingNewSessionSheet = false
    @State private var sessionToDelete: Session?
    @State private var showingDeleteAlert = false
    @State private var errorMessage: String?

    var onSessionSelected: (Session) -> Void

    // MARK: - Body

    var body: some View {
        Group {
            if isLoading {
                loadingView
            } else if sessions.isEmpty {
                emptyStateView
            } else {
                sessionsList
            }
        }
        .navigationTitle("会话")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingNewSessionSheet = true
                } label: {
                    Label("新建", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showingNewSessionSheet) {
            NewSessionSheet { workingDirectory in
                Task {
                    await createNewSession(workingDirectory: workingDirectory)
                }
            }
        }
        .alert("删除会话", isPresented: $showingDeleteAlert, presenting: sessionToDelete) { _ in
            Button("取消", role: .cancel) { }
            Button("删除", role: .destructive) {
                Task {
                    await deleteConfirmedSession()
                }
            }
        } message: { session in
            Text("确定要删除会话「\(session.title)」吗？此操作不可撤销。")
        }
        .alert("错误", isPresented: .constant(errorMessage != nil)) {
            Button("确定") {
                errorMessage = nil
            }
        } message: {
            if let error = errorMessage {
                Text(error)
            }
        }
        .task {
            await loadSessions()
        }
    }

    // MARK: - Views

    private var loadingView: some View {
        ProgressView("加载中...")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateView: some View {
        ContentUnavailableView {
            Label("暂无会话", systemImage: "bubble.left.and.bubble.right")
        } description: {
            Text("点击右上角的 + 创建新会话")
        } actions: {
            Button("创建会话") {
                showingNewSessionSheet = true
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var sessionsList: some View {
        List {
            ForEach(sessions) { session in
                SessionRowView(session: session) {
                    onSessionSelected(session)
                }
                .contextMenu {
                    contextMenu(for: session)
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
        .refreshable {
            await loadSessions()
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func contextMenu(for session: Session) -> some View {
        Button {
            onSessionSelected(session)
        } label: {
            Label("打开", systemImage: "arrow.right.circle")
        }

        Divider()

        Button(role: .destructive) {
            sessionToDelete = session
            showingDeleteAlert = true
        } label: {
            Label("删除", systemImage: "trash")
        }
    }

    // MARK: - Actions

    private func loadSessions() async {
        isLoading = true

        let repository = SessionRepository(modelContext: modelContext)
        do {
            sessions = try await repository.fetchAll()
        } catch {
            errorMessage = "加载会话失败: \(error.localizedDescription)"
        }

        isLoading = false
    }

    private func createNewSession(workingDirectory: String) async {
        // TODO: 通过 SessionService 创建会话
        // 这里暂时创建一个本地会话对象
        let newSession = Session(
            sessionId: UUID().uuidString,
            title: Session.generateTitle(from: workingDirectory),
            workingDirectory: workingDirectory
        )

        let repository = SessionRepository(modelContext: modelContext)
        do {
            try await repository.create(newSession)
            showingNewSessionSheet = false
            await loadSessions()
            onSessionSelected(newSession)
        } catch {
            errorMessage = "创建会话失败: \(error.localizedDescription)"
        }
    }

    private func deleteConfirmedSession() async {
        guard let session = sessionToDelete else { return }

        let repository = SessionRepository(modelContext: modelContext)
        let messageRepository = MessageRepository(modelContext: modelContext)

        do {
            // 删除会话的消息
            try await messageRepository.deleteBySessionId(session.sessionId)
            // 删除会话
            try await repository.delete(session)

            sessionToDelete = nil
            await loadSessions()
        } catch {
            errorMessage = "删除会话失败: \(error.localizedDescription)"
        }
    }
}

// MARK: - Session Row View

/// 会话行视图
private struct SessionRowView: View {
    let session: Session
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // 图标
                sessionIcon

                // 信息
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.title)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                // 时间
                Text(session.updatedAt.formatted(.relative(presentation: .named)))
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                // 活跃指示器
                if session.isActive {
                    Circle()
                        .fill(.green)
                        .frame(width: 6, height: 6)
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
                .frame(width: 36, height: 36)

            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white)
        }
    }

    private var subtitle: String {
        session.workingDirectory
    }
}

// MARK: - New Session Sheet

/// 新建会话表单
private struct NewSessionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var workingDirectory: String

    let onCreate: (String) -> Void

    init(onCreate: @escaping (String) -> Void) {
        self.onCreate = onCreate
        _workingDirectory = State(initialValue: FileManager.default.homeDirectoryForCurrentUser.path)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("工作目录") {
                    HStack {
                        TextField("路径", text: $workingDirectory)
                            .textFieldStyle(.roundedBorder)

                        Button("选择") {
                            // TODO: 打开目录选择器
                        }
                        .buttonStyle(.bordered)
                    }

                    Text("Agent 将在此目录下执行操作")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("新建会话")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") {
                        onCreate(workingDirectory)
                    }
                    .disabled(workingDirectory.isEmpty)
                }
            }
        }
        .frame(minWidth: 400, minHeight: 250)
    }
}

// MARK: - Preview

#Preview("Empty State") {
    NavigationStack {
        SessionListView { _ in }
    }
}

#Preview("With Sessions") {
    NavigationStack {
        SessionListView { _ in }
    }
}
