import SwiftUI
import SwiftData

struct WorkbenchLSPPanelView: View {
    @Environment(WorkspaceState.self) private var workspaceState
    @Environment(ClaudeService.self) private var claudeService
    @Environment(PersistenceCoordinator.self) private var persistenceCoordinator
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow

    @State private var expandedServiceIDs: Set<String> = []
    @State private var busyServiceID: String?
    @State private var actionErrors: [String: String] = [:]

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
        let managementViewModel = presenter.managementViewModel(onPersistSettings: { userMessage, mutation in
            persistSettingsMutation(userMessage: userMessage, mutation: mutation)
        })

        VStack(spacing: 0) {
            WorkbenchSidebarPanelHeader {
                WorkbenchSidebarToolbarHeader {
                    HStack(spacing: 8) {
                        Label("LSP", systemImage: "server.rack")
                            .font(.subheadline.weight(.semibold))
                        if !workingDirectory.isEmpty {
                            Text(URL(fileURLWithPath: workingDirectory).lastPathComponent)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                } trailing: {
                    Button {
                        Task { await bootstrapLSP() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .disabled(workingDirectory.isEmpty)
                    .accessibilityIdentifier("lsp.panel.refresh")
                }
            }

            WorkbenchSidebarPanelScrollView {
                overviewSection(status: status, presenter: presenter)
                diagnosticsSection(status: status)
                servicesSection(viewModel: managementViewModel)
            }
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

    private func overviewSection(
        status: WorkspacePanelLSPStatusPresentation,
        presenter: WorkspacePanelLSPFooterPresenter
    ) -> some View {
        WorkbenchSidebarSectionCard(title: "状态", systemImage: "dot.radiowaves.left.and.right") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(status.serverID ?? "未绑定")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    countChip(title: "错误", count: status.errorCount, color: .red)
                    countChip(title: "警告", count: status.warningCount, color: .orange)
                }

                keyValueRow(title: "当前文件", value: status.selectedFileName ?? "未选择")
                keyValueRow(
                    title: "工作目录",
                    value: workingDirectory.isEmpty ? "未设置" : URL(fileURLWithPath: workingDirectory).lastPathComponent
                )

                if let summary = status.projectSummary {
                    keyValueRow(title: "受影响文件", value: "\(summary.filesWithDiagnostics) 个")
                }
            }
        } accessory: {
            statusBadge(text: status.stateText, tone: presenter.tone(for: status.stateText))
        }
    }

    @ViewBuilder
    private func diagnosticsSection(status: WorkspacePanelLSPStatusPresentation) -> some View {
        WorkbenchSidebarSectionCard(title: "诊断", systemImage: "exclamationmark.bubble") {
            VStack(alignment: .leading, spacing: 12) {
                if let summary = status.projectSummary {
                    HStack(spacing: 8) {
                        countChip(title: "错误", count: summary.errorCount, color: .red)
                        countChip(title: "警告", count: summary.warningCount, color: .orange)

                        if summary.informationCount > 0 {
                            countChip(title: "信息", count: summary.informationCount, color: .blue)
                        }

                        if summary.hintCount > 0 {
                            countChip(title: "提示", count: summary.hintCount, color: .secondary)
                        }
                    }

                    keyValueRow(title: "受影响文件", value: "\(summary.filesWithDiagnostics) 个")
                    keyValueRow(title: "最近更新", value: summary.updatedAt.formatted(date: .omitted, time: .shortened))

                    if summary.recentDiagnostics.isEmpty {
                        emptyStateRow(text: "当前项目没有诊断信息")
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(summary.recentDiagnostics.prefix(6).enumerated()), id: \.offset) { index, item in
                                if index > 0 {
                                    Divider()
                                }
                                diagnosticRow(item)
                            }
                        }
                        .padding(.top, 2)
                    }
                } else {
                    emptyStateRow(text: "当前项目没有诊断信息")
                }
            }
        }
    }

    private func servicesSection(viewModel: LSPManagementViewModel) -> some View {
        WorkbenchSidebarSectionCard(title: "服务管理", systemImage: "slider.horizontal.3") {
            VStack(alignment: .leading, spacing: 12) {
                Text("在当前面板里查看安装状态、运行状态和最近错误；高级配置仍在设置中完成。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if viewModel.services.isEmpty {
                    emptyStateRow(text: "当前没有可管理的 LSP 服务")
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(viewModel.services.enumerated()), id: \.element.id) { index, service in
                            if index > 0 {
                                Divider()
                            }

                            VStack(alignment: .leading, spacing: 10) {
                                serviceRow(service, viewModel: viewModel)

                                if expandedServiceIDs.contains(service.id) {
                                    serviceDetail(service)
                                }

                                if let actionError = actionErrors[service.id], !actionError.isEmpty {
                                    Text(actionError)
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                }
                            }
                            .padding(.vertical, 10)
                        }
                    }
                }
            }
        } accessory: {
            Button {
                openWindow(id: SettingsWindowScene.id)
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("打开设置")
        }
    }

    private func diagnosticRow(_ item: LSPProjectDiagnosticsSummary.DiagnosticItem) -> some View {
        let presentation = WorkbenchLSPDiagnosticRowPresentation.make(item)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle()
                    .fill(presentation.severityColor)
                    .frame(width: 7, height: 7)
                Text(presentation.pathText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(presentation.severityText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(presentation.severityColor)
            }

            Text(presentation.messageText)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .truncationMode(.tail)

            if let metadataText = presentation.metadataText {
                Text(metadataText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.vertical, 8)
    }

    private func serviceRow(_ service: LSPServicePresentation, viewModel: LSPManagementViewModel) -> some View {
        let installTone = WorkbenchLSPStatusTone.tone(for: service.installStatusText)
        let runtimeTone = WorkbenchLSPStatusTone.tone(for: service.runtimeStatusText)
        let primaryActions = WorkbenchLSPServiceActionPresentation.primaryActions(from: service.availableActions)
        let secondaryActions = WorkbenchLSPServiceActionPresentation.secondaryActions(from: service.availableActions)
        let isBusy = busyServiceID == service.id || service.isInstallInProgress

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(service.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)

                    Text(service.languagesText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 6) {
                    statusBadge(text: service.installStatusText, tone: installTone)
                    statusBadge(text: service.runtimeStatusText, tone: runtimeTone)
                }
            }

            if let installActivityText = service.installActivityText, !installActivityText.isEmpty {
                Text(installActivityText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                ForEach(primaryActions, id: \.self) { action in
                    serviceActionButton(
                        action,
                        isProminent: action == primaryActions.first,
                        service: service,
                        viewModel: viewModel,
                        isBusy: isBusy
                    )
                }

                if !secondaryActions.isEmpty {
                    Menu("更多") {
                        ForEach(secondaryActions, id: \.self) { action in
                            Button(WorkbenchLSPServiceActionPresentation.title(for: action)) {
                                perform(action, for: service, with: viewModel)
                            }
                            .disabled(isBusy)
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .controlSize(.small)
                    .disabled(isBusy)
                }

                Spacer(minLength: 8)

                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                }

                Button(expandedServiceIDs.contains(service.id) ? "收起详情" : "查看详情") {
                    toggleServiceDetail(service.id)
                }
                .buttonStyle(.plain)
                .font(.caption)
            }
        }
    }

    private func serviceDetail(_ service: LSPServicePresentation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            keyValueRow(title: "安装状态", value: service.installStatusText)
            keyValueRow(title: "运行状态", value: service.runtimeStatusText)
            keyValueRow(title: "语言", value: service.languagesText)

            if let versionText = service.versionText, !versionText.isEmpty {
                keyValueRow(title: "版本", value: versionText)
            }

            if let executablePath = service.executablePath, !executablePath.isEmpty {
                keyValueRow(title: "可执行文件", value: executablePath)
            }

            if let detailText = service.detailText, !detailText.isEmpty {
                keyValueRow(title: "最近错误", value: detailText, multiLine: true)
            }

            if !service.installLogLines.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("安装日志")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ForEach(Array(service.installLogLines.suffix(4).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineLimit(2)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func perform(_ action: LSPManagementAction, for service: LSPServicePresentation, with viewModel: LSPManagementViewModel) {
        Task {
            busyServiceID = service.id
            defer { busyServiceID = nil }

            do {
                try await viewModel.perform(action, for: service.id)
                actionErrors[service.id] = nil
            } catch {
                actionErrors[service.id] = error.localizedDescription
                expandedServiceIDs.insert(service.id)
            }
        }
    }

    private func toggleServiceDetail(_ serviceID: String) {
        if expandedServiceIDs.contains(serviceID) {
            expandedServiceIDs.remove(serviceID)
        } else {
            expandedServiceIDs.insert(serviceID)
        }
    }

    @ViewBuilder
    private func serviceActionButton(
        _ action: LSPManagementAction,
        isProminent: Bool,
        service: LSPServicePresentation,
        viewModel: LSPManagementViewModel,
        isBusy: Bool
    ) -> some View {
        if isProminent {
            Button(WorkbenchLSPServiceActionPresentation.title(for: action)) {
                perform(action, for: service, with: viewModel)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.small)
            .disabled(isBusy)
        } else {
            Button(WorkbenchLSPServiceActionPresentation.title(for: action)) {
                perform(action, for: service, with: viewModel)
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .disabled(isBusy)
        }
    }

    private func sectionHeader(title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
    }

    private func statusBadge(text: String, tone: WorkbenchLSPStatusTone) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(tone.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tone.color.opacity(0.12), in: Capsule())
    }

    private func keyValueRow(title: String, value: String, multiLine: Bool = false) -> some View {
        HStack(alignment: multiLine ? .top : .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(value)
                .font(.caption)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
                .lineLimit(multiLine ? nil : 1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private func countChip(title: String, count: Int, color: Color) -> some View {
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

    private func emptyStateRow(text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
    }
}