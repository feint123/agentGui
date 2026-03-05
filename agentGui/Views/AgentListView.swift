//
//  AgentListView.swift
//  agentGui
//
//  Created by feint on 2026/2/10.
//

import SwiftUI
import SwiftData

/// Agent 列表视图
/// 显示所有已配置的 Agent，支持连接、编辑、删除操作
struct AgentListView: View {

    // MARK: - Environment

    @Environment(\.modelContext) private var modelContext

    // MARK: - Properties

    @State private var viewModel: AgentListViewModel?
    @State private var selectedAgent: AgentConfiguration?
    @State private var showingAddSheet = false
    @State private var showingEditSheet = false
    @State private var showingDeleteAlert = false
    @State private var agentToDelete: AgentConfiguration?
    @State private var errorMessage: String?

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Group {
                if let viewModel = viewModel {
                    contentView(with: viewModel)
                } else {
                    loadingView
                }
            }
            .navigationTitle("Agent 列表")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    addButton
                }
            }
            .sheet(isPresented: $showingAddSheet) {
                AgentConfigSheet(mode: .create) { agent in
                    Task {
                        await addAgent(agent)
                    }
                }
            }
            .sheet(isPresented: $showingEditSheet) {
                if let agent = selectedAgent {
                    AgentConfigSheet(mode: .edit(agent)) { updatedAgent in
                        Task {
                            await updateAgent(updatedAgent)
                        }
                    }
                }
            }
            .alert("删除 Agent", isPresented: $showingDeleteAlert, presenting: agentToDelete) { _ in
                Button("取消", role: .cancel) { }
                Button("删除", role: .destructive) {
                    Task {
                        await deleteConfirmedAgent()
                    }
                }
            } message: { agent in
                Text("确定要删除「\(agent.name)」吗？此操作不可撤销。")
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
        }
        .task {
            await initializeViewModel()
        }
    }

    // MARK: - Content Views

    @ViewBuilder
    private func contentView(with viewModel: AgentListViewModel) -> some View {
        if viewModel.isLoading {
            loadingView
        } else if viewModel.hasAgents {
            agentList(with: viewModel)
        } else {
            emptyStateView
        }
    }

    private var loadingView: some View {
        ProgressView("加载中...")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func agentList(with viewModel: AgentListViewModel) -> some View {
        List {
            ForEach(viewModel.agents) { agent in
                AgentRowView(
                    agent: agent,
                    isConnected: viewModel.connectedAgentId == agent.id,
                    isConnecting: viewModel.isConnecting && viewModel.connectedAgentId == agent.id
                ) {
                    Task {
                        await handleAgentTap(agent)
                    }
                }
                .contextMenu {
                    contextMenu(for: agent)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        agentToDelete = agent
                        showingDeleteAlert = true
                    } label: {
                        Label("删除", systemImage: "trash")
                    }

                    Button {
                        selectedAgent = agent
                        showingEditSheet = true
                    } label: {
                        Label("编辑", systemImage: "pencil")
                    }
                    .tint(.blue)
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .refreshable {
            await viewModel.refresh()
        }
    }

    private var emptyStateView: some View {
        ContentUnavailableView {
            Label("暂无 Agent", systemImage: "app.dashed")
        } description: {
            Text("点击右上角的 + 添加一个新的 Agent 配置")
        } actions: {
            Button("添加 Agent") {
                showingAddSheet = true
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Toolbar Items

    private var addButton: some View {
        Button {
            showingAddSheet = true
        } label: {
            Label("添加", systemImage: "plus")
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func contextMenu(for agent: AgentConfiguration) -> some View {
        Group {
            Button {
                Task {
                    await handleAgentTap(agent)
                }
            } label: {
                let isConnected = viewModel?.connectedAgentId == agent.id
                Label(isConnected ? "断开连接" : "连接", systemImage: isConnected ? "plug.disconnect" : "plug")
            }

            Button {
                selectedAgent = agent
                showingEditSheet = true
            } label: {
                Label("编辑", systemImage: "pencil")
            }

            Divider()

            Button(role: .destructive) {
                agentToDelete = agent
                showingDeleteAlert = true
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    // MARK: - Actions

    private func initializeViewModel() async {
        let agentRepo = AgentRepository(modelContext: modelContext)
        let acpService = ACPClientService()
        let lifecycleService = AgentLifecycleService(
            acpClientService: acpService,
            agentRepository: agentRepo
        )

        let vm = AgentListViewModel(
            agentRepository: agentRepo,
            lifecycleService: lifecycleService
        )

        viewModel = vm
        await vm.loadAgents()
    }

    private func handleAgentTap(_ agent: AgentConfiguration) async {
        guard let viewModel = viewModel else { return }

        if viewModel.connectedAgentId == agent.id {
            // 已连接，执行断开
            await viewModel.disconnect()
        } else {
            // 未连接，执行连接
            do {
                try await viewModel.connect(to: agent)
            } catch {
                errorMessage = "连接失败: \(error.localizedDescription)"
            }
        }
    }

    private func addAgent(_ agent: AgentConfiguration) async {
        guard let viewModel = viewModel else { return }

        let validation = viewModel.validateAgent(agent)
        if !validation.isValid {
            errorMessage = validation.error
            return
        }

        do {
            try await viewModel.addAgent(agent)
            showingAddSheet = false
        } catch {
            errorMessage = "添加失败: \(error.localizedDescription)"
        }
    }

    private func updateAgent(_ agent: AgentConfiguration) async {
        guard let viewModel = viewModel else { return }

        let validation = viewModel.validateAgent(agent)
        if !validation.isValid {
            errorMessage = validation.error
            return
        }

        do {
            try await viewModel.updateAgent(agent)
            showingEditSheet = false
        } catch {
            errorMessage = "更新失败: \(error.localizedDescription)"
        }
    }

    private func deleteConfirmedAgent() async {
        guard let viewModel = viewModel,
              let agent = agentToDelete else { return }

        do {
            try await viewModel.deleteAgent(agent)
            agentToDelete = nil
        } catch {
            errorMessage = "删除失败: \(error.localizedDescription)"
        }
    }
}

// MARK: - Agent Row View

/// Agent 列表行视图
private struct AgentRowView: View {
    let agent: AgentConfiguration
    let isConnected: Bool
    let isConnecting: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Icon
                icon

                // Info
                VStack(alignment: .leading, spacing: 4) {
                    Text(agent.name)
                        .font(.body)
                        .foregroundStyle(.primary)

                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Status
                statusIndicator
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var icon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(iconColor.gradient)
                .frame(width: 36, height: 36)

            Image(systemName: iconSystemName)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.white)
        }
    }

    private var iconSystemName: String {
        switch agent.agentType {
        case .claudeCode:
            return "brain"
        case .openCode:
            return "cpu"
        case .custom:
            return "app.connected.to.app.below.fill"
        }
    }

    private var iconColor: Color {
        switch agent.agentType {
        case .claudeCode:
            return .orange
        case .openCode:
            return .blue
        case .custom:
            return .purple
        }
    }

    private var subtitle: String {
        var parts: [String] = []

        parts.append(agent.agentType.displayName)

        if agent.isLocal {
            parts.append("本地")
        } else {
            parts.append("远程")
        }

        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var statusIndicator: some View {
        HStack(spacing: 6) {
            if isConnecting {
                ProgressView()
                    .scaleEffect(0.7)
            } else if isConnected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }

            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var statusText: String {
        if isConnecting {
            return "连接中..."
        } else if isConnected {
            return "已连接"
        } else {
            return "未连接"
        }
    }
}

// MARK: - Preview

#Preview("Empty State") {
    AgentListView()
}

#Preview("With Agents") {
    AgentListView()
}
