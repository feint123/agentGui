//
//  ClaudeService+WorkspaceContext.swift
//  agentGui
//

import Foundation

struct WorkspacePanelLSPStatusPresentation: Equatable {
    let stateText: String
    let serverID: String?
    let selectedFileName: String?
    let errorCount: Int
    let warningCount: Int
    let projectSummary: LSPProjectDiagnosticsSummary?
}

extension ClaudeService {

    func makeWorkflowWorkspaceContext(
        workingDirectory: String,
        selectedFilePath: String?,
        selectedText: String?,
        availableSkills: [WorkflowSkillInfo],
        settings: AppSettings
    ) -> WorkflowWorkspaceContext {
        let normalizedSelection = selectedText?.trimmingCharacters(in: .whitespacesAndNewlines)
        var context = WorkflowWorkspaceContext(
            workingDirectory: workingDirectory,
            selectedFilePath: selectedFilePath,
            selectedText: normalizedSelection?.isEmpty == false ? normalizedSelection : nil,
            availableSkills: availableSkills
        )

        guard settings.enableLSPTools,
              !workingDirectory.isEmpty,
              let selectedFilePath,
              let registry = try? LSPServerRegistry(settings: settings) else {
            return context
        }

        let resolver = LSPWorkspaceResolver()
        guard let binding = resolver.resolve(
            filePath: selectedFilePath,
            workingDirectory: workingDirectory,
            registry: registry,
            settings: settings
        ) else {
            return context
        }

        context.lspServerID = binding.serverID
        context.lspServerStateSummary = lspServerManager?.state(for: workingDirectory, serverID: binding.serverID)?.summaryText

        let uri = URL(fileURLWithPath: selectedFilePath).absoluteString
        if let diagnosticsSnapshot = lspServerManager?.diagnosticsStore.snapshot(for: workingDirectory, uri: uri) {
            let counts = Dictionary(grouping: diagnosticsSnapshot.diagnostics, by: \.severity)
                .map { "\($0.key.rawValue)=\($0.value.count)" }
                .sorted()
                .joined(separator: ", ")
            context.lspDiagnosticsSummary = "\(diagnosticsSnapshot.diagnostics.count) total [\(counts)]"
        }

        return context
    }

    func makeWorkflowWorkspaceContextForTests(
        workingDirectory: String,
        selectedFilePath: String?,
        selectedText: String?,
        availableSkills: [WorkflowSkillInfo],
        settings: AppSettings
    ) -> WorkflowWorkspaceContext {
        makeWorkflowWorkspaceContext(
            workingDirectory: workingDirectory,
            selectedFilePath: selectedFilePath,
            selectedText: selectedText,
            availableSkills: availableSkills,
            settings: settings
        )
    }

    func makeWorkspacePanelLSPStatus(
        workingDirectory: String,
        selectedFilePath: String?,
        settings: AppSettings
    ) -> WorkspacePanelLSPStatusPresentation {
        let fileName = selectedFilePath.map { URL(fileURLWithPath: $0).lastPathComponent }

        guard settings.enableLSPTools else {
            return WorkspacePanelLSPStatusPresentation(
                stateText: "已禁用",
                serverID: nil,
                selectedFileName: fileName,
                errorCount: 0,
                warningCount: 0,
                projectSummary: nil
            )
        }

        guard !workingDirectory.isEmpty else {
            return WorkspacePanelLSPStatusPresentation(
                stateText: "无工作目录",
                serverID: nil,
                selectedFileName: fileName,
                errorCount: 0,
                warningCount: 0,
                projectSummary: nil
            )
        }

        guard let selectedFilePath else {
            return WorkspacePanelLSPStatusPresentation(
                stateText: "选择文件以查看状态",
                serverID: nil,
                selectedFileName: nil,
                errorCount: 0,
                warningCount: 0,
                projectSummary: lspServerManager?.diagnosticsStore.workspaceSummary(for: workingDirectory)
            )
        }

        let catalog = LSPProviderCatalog.builtInCatalog()
        let serviceStateStore = LSPServiceStateStore(catalog: catalog, serverManager: lspServerManager)

        guard let registry = try? LSPServerRegistry(settings: settings) else {
            return WorkspacePanelLSPStatusPresentation(
                stateText: "Profile 配置无效",
                serverID: nil,
                selectedFileName: fileName,
                errorCount: 0,
                warningCount: 0,
                projectSummary: nil
            )
        }

        let resolver = LSPWorkspaceResolver()
        if let binding = resolver.resolve(
            filePath: selectedFilePath,
            workingDirectory: workingDirectory,
            registry: registry,
            settings: settings
        ) {
            let uri = URL(fileURLWithPath: selectedFilePath).absoluteString
            let diagnostics = lspServerManager?.diagnosticsStore.snapshot(for: workingDirectory, uri: uri)?.diagnostics ?? []
            let projectSummary = lspServerManager?.diagnosticsStore.workspaceSummary(for: workingDirectory)
            let errorCount = diagnostics.filter { $0.severity == .error }.count
            let warningCount = diagnostics.filter { $0.severity == .warning }.count
            let serviceState = serviceStateStore.state(
                providerID: binding.serverID,
                settings: settings,
                workingDirectory: workingDirectory,
                selectedFilePath: selectedFilePath
            )

            return WorkspacePanelLSPStatusPresentation(
                stateText: serviceState.runtimeStateSummary,
                serverID: binding.serverID,
                selectedFileName: fileName,
                errorCount: projectSummary?.errorCount ?? errorCount,
                warningCount: projectSummary?.warningCount ?? warningCount,
                projectSummary: projectSummary
            )
        }

        if let suggestedProvider = catalog.providerForFilePath(selectedFilePath) {
            let serviceState = serviceStateStore.state(
                providerID: suggestedProvider.id,
                settings: settings,
                workingDirectory: workingDirectory,
                selectedFilePath: selectedFilePath
            )
            return WorkspacePanelLSPStatusPresentation(
                stateText: serviceState.runtimeStateSummary,
                serverID: suggestedProvider.id,
                selectedFileName: fileName,
                errorCount: 0,
                warningCount: 0,
                projectSummary: lspServerManager?.diagnosticsStore.workspaceSummary(for: workingDirectory)
            )
        }

        return WorkspacePanelLSPStatusPresentation(
            stateText: "当前文件无匹配服务",
            serverID: nil,
            selectedFileName: fileName,
            errorCount: 0,
            warningCount: 0,
            projectSummary: lspServerManager?.diagnosticsStore.workspaceSummary(for: workingDirectory)
        )
    }

    func makeWorkspacePanelLSPStatusForTests(
        workingDirectory: String,
        selectedFilePath: String?,
        settings: AppSettings
    ) -> WorkspacePanelLSPStatusPresentation {
        makeWorkspacePanelLSPStatus(
            workingDirectory: workingDirectory,
            selectedFilePath: selectedFilePath,
            settings: settings
        )
    }
}