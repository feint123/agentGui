import SwiftUI
import SwiftData

struct WorkbenchSidebarView: View {
    @Environment(WorkbenchState.self) private var workbenchState
    @Environment(WorkspaceState.self) private var workspaceState
    @Namespace private var navigationGlassNamespace

    var body: some View {
        VStack(spacing: 0) {
            navigationBar
            currentPanelContainer
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .accessibilityIdentifier("workbench.sidebar")
    }

    private var navigationBar: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 6) {
                ForEach(WorkbenchNavigationItem.allCases, id: \.self) { item in
                    WorkbenchSidebarNavigationButton(
                        item: item,
                        isSelected: workbenchState.selectedItem == item,
                        namespace: navigationGlassNamespace,
                        action: {
                            select(item)
                        }
                    )
                }
            }
            .padding(4)
            .frame(maxWidth: .infinity)
            .glassEffect(.regular, in: Capsule())
            .shadow(color: .black.opacity(0.12), radius: 16, y: 8)
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private var currentPanelContainer: some View {
        ZStack {
            ForEach(WorkbenchNavigationItem.allCases, id: \.self) { item in
                panelView(for: item)
                    .opacity(workbenchState.selectedItem == item ? 1 : 0)
                    .allowsHitTesting(workbenchState.selectedItem == item)
                    .accessibilityHidden(workbenchState.selectedItem != item)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        .animation(.snappy(duration: 0.22, extraBounce: 0.02), value: workbenchState.selectedItem)
    }

    @ViewBuilder
    private func panelView(for item: WorkbenchNavigationItem) -> some View {
        switch item {
        case .sessions:
            SessionListView { session in
                workspaceState.selectedSession = session
            }
            .accessibilityIdentifier("panel.sessions")
        case .workspace:
            WorkspacePanelView()
        case .git:
            WorkbenchGitPanelView()
                .accessibilityIdentifier("panel.git")
        case .lsp:
            WorkbenchLSPPanelView()
                .accessibilityIdentifier("panel.lsp")
        case .skills:
            SkillsView()
                .accessibilityIdentifier("panel.skills")
        case .diagnostics:
            ReliabilityCenterView()
                .accessibilityIdentifier("panel.diagnostics")
        }
    }

    private func select(_ item: WorkbenchNavigationItem) {
        guard workbenchState.selectedItem != item else { return }

        withAnimation(.snappy(duration: 0.24, extraBounce: 0.03)) {
            workbenchState.selectedItem = item
        }
    }
}

private struct WorkbenchSidebarNavigationButton: View {
    let item: WorkbenchNavigationItem
    let isSelected: Bool
    let namespace: Namespace.ID
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: item.systemImage)
                .font(.system(size: 14, weight: isSelected ? .semibold : .medium))
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .contentShape(Capsule())
                .background(buttonBackground)
                .overlay {
                    if isSelected {
                        Capsule()
                            .stroke(Color.white.opacity(0.14), lineWidth: 0.8)
                    }
                }
        }
        .buttonStyle(.plain)
        .foregroundStyle(foregroundStyle)
        .help(item.title)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(item.accessibilityIdentifier)
        .scaleEffect(isHovered && !isSelected ? 1.03 : 1)
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .onHover { isHovered = $0 }
    }

    private var foregroundStyle: some ShapeStyle {
        isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)
    }

    @ViewBuilder
    private var buttonBackground: some View {
        if isSelected {
            Capsule()
                .fill(Color.accentColor.opacity(0.20))
                .matchedGeometryEffect(id: "workbench.sidebar.selection", in: namespace)
        } else if isHovered {
            Capsule()
                .fill(Color.primary.opacity(0.06))
        }
    }
}

private struct WorkbenchLSPPanelView: View {
    @Environment(WorkspaceState.self) private var workspaceState
    @Environment(ClaudeService.self) private var claudeService
    @Environment(PersistenceCoordinator.self) private var persistenceCoordinator
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow

    @State private var showsLSPDiagnosticsPopover = false
    @State private var showsLSPManagementPopover = false

    var body: some View {
        let _ = claudeService.lspPresentationRevision
        let presenter = WorkspacePanelLSPFooterPresenter(
            claudeService: claudeService,
            persistenceCoordinator: persistenceCoordinator,
            modelContext: modelContext
        )
        let status = presenter.status(
            workingDirectory: workingDirectory,
            selectedFilePath: workspaceState.selectedFile?.standardizedFileURL.path
        )

        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label("LSP", systemImage: "server.rack")
                    .font(.headline)

                statusSection(status: status, presenter: presenter)
                diagnosticsSection(status: status)
                managementSection(status: status, presenter: presenter)
            }
            .padding(12)
        }
        .task(id: refreshKey) {
            await bootstrapLSP()
        }
    }

    private var workingDirectory: String {
        let settings = AppSettings.getOrCreate(in: modelContext, persistenceCoordinator: persistenceCoordinator)
        return workspaceState.effectiveWorkingDirectory(globalDefault: settings.workingDirectory)
    }

    private var refreshKey: String {
        "\(workspaceState.selectedSession?.sessionId ?? "")|\(workspaceState.selectedFile?.path ?? "")|\(workingDirectory)"
    }

    private func bootstrapLSP() async {
        let settings = AppSettings.getOrCreate(in: modelContext, persistenceCoordinator: persistenceCoordinator)
        _ = try? await claudeService.ensureWorkspaceLSPState(
            workingDirectory: workingDirectory,
            selectedFilePath: workspaceState.selectedFile?.standardizedFileURL.path,
            settings: settings
        )
    }

    @discardableResult
    private func persistSettingsMutation(userMessage: String, mutation: () -> Void) -> Bool {
        mutation()

        do {
            try persistenceCoordinator.save(
                modelContext,
                domain: .settings,
                userMessage: userMessage
            )
            return true
        } catch {
            return false
        }
    }

    private func statusSection(
        status: WorkspacePanelLSPStatusPresentation,
        presenter: WorkspacePanelLSPFooterPresenter
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(title: "状态", systemImage: "dot.radiowaves.left.and.right")

            HStack(alignment: .firstTextBaseline) {
                Text(status.serverID ?? "未绑定")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(status.stateText)
                    .font(.caption)
                    .foregroundStyle(presenter.tone(for: status.stateText).color)
            }

            if let fileName = status.selectedFileName {
                labeledValue(title: "当前文件", value: fileName)
            }

            labeledValue(title: "工作目录", value: workingDirectory.isEmpty ? "未设置" : URL(fileURLWithPath: workingDirectory).lastPathComponent)
        }
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private func diagnosticsSection(status: WorkspacePanelLSPStatusPresentation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(title: "诊断", systemImage: "exclamationmark.bubble")

            HStack(spacing: 8) {
                lspCountChip(title: "错误", count: status.errorCount, color: .red)
                lspCountChip(title: "警告", count: status.warningCount, color: .orange)
            }

            if let summary = status.projectSummary {
                labeledValue(title: "受影响文件", value: "\(summary.filesWithDiagnostics) 个")
                labeledValue(title: "最近更新", value: summary.updatedAt.formatted(date: .omitted, time: .shortened))

                if let item = summary.recentDiagnostics.first {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(URL(string: item.uri)?.lastPathComponent ?? item.uri)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(item.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .padding(.top, 2)
                } else {
                    Text("当前项目没有诊断信息")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("当前项目没有诊断信息")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("查看诊断详情") {
                showsLSPDiagnosticsPopover.toggle()
            }
            .buttonStyle(.glass)
            .popover(isPresented: $showsLSPDiagnosticsPopover, arrowEdge: .bottom) {
                LSPDiagnosticsPopoverView(status: status)
            }
        }
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func managementSection(
        status: WorkspacePanelLSPStatusPresentation,
        presenter: WorkspacePanelLSPFooterPresenter
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(title: "管理", systemImage: "slider.horizontal.3")

            Text(status.serverID == nil ? "当前文件尚未绑定可用服务，可在这里安装、启用或跳转到设置。" : "管理当前服务的安装状态、绑定关系和全局设置。")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button("服务管理") {
                    showsLSPManagementPopover.toggle()
                }
                .buttonStyle(.glassProminent)
                .popover(isPresented: $showsLSPManagementPopover, arrowEdge: .bottom) {
                    LSPManagementPopoverView(
                        viewModel: presenter.managementViewModel(onPersistSettings: { userMessage, mutation in
                            persistSettingsMutation(userMessage: userMessage, mutation: mutation)
                        }),
                        onOpenSettings: {
                            openWindow(id: SettingsWindowScene.id)
                            showsLSPManagementPopover = false
                        }
                    )
                }

                Button("打开设置") {
                    openWindow(id: SettingsWindowScene.id)
                }
                .buttonStyle(.glass)
            }
        }
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func sectionHeader(title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
    }

    private func labeledValue(title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(value)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func lspCountChip(title: String, count: Int, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text("\(title) \(count)")
                .font(.caption2)
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.10), in: Capsule())
    }
}